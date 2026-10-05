import AppKit
import SwiftUI
import Core

extension NSAttributedString.Key {
    /// Index into `project.words` for each word's characters.
    static let octoWord = NSAttributedString.Key("octoWord")
    /// On a clip marker's characters: the clip's raw id, and whether it's the start marker.
    static let octoMarkerClip = NSAttributedString.Key("octoMarkerClip")
    static let octoMarkerIn = NSAttributedString.Key("octoMarkerIn")
    /// The paragraph (raw id) a header line or body character belongs to.
    static let octoParagraph = NSAttributedString.Key("octoParagraph")
    /// On a paragraph header line (time and speaker), including its newline.
    static let octoHeader = NSAttributedString.Key("octoHeader")
}

/// A clip start (▶) or end (◀) marker in the transcript.
struct MarkerRef: Equatable {
    var clip: ClipID
    var inPoint: Bool
}

/// The transcript in Cut mode: text can't be typed into; selecting words drives the
/// Clip commands, clip markers can be dragged to another word, a click seeks.
struct TranscriptView: NSViewRepresentable {
    let model: DocumentModel
    // Read here (not inside the coordinator) so SwiftUI tracks them.
    let revision: Int
    let selectedClip: ClipID?
    let currentWord: Int?
    let followPlayhead: Bool
    let reveal: (word: Int, request: Int)?
    let inspected: BoundaryRef?
    let inspectRequest: Int
    let textEditing: Bool
    let searchText: String
    let searchStep: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: exact (not estimated) layout, so restyling never moves the text, and
        // temporary attributes for the playhead highlight that don't touch the text.
        let textView = WordTextView(usingTextLayoutManager: false)
        textView.layoutManager?.allowsNonContiguousLayout = false
        // Editable only so there is a caret (arrow keys, ⇧/⌘-arrow selection); every
        // text change is refused in shouldChangeTextIn, so the words never change here.
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.insertionPointColor = .controlAccentColor
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 24, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        textView.coordinator = context.coordinator
        let coordinator = context.coordinator
        model.textProvider = { [weak coordinator] in coordinator?.editedParagraphs() ?? [] }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.editing != textEditing { c.setEditing(textEditing) }
        if c.revision != revision || c.selectedClip != selectedClip {
            c.rebuild(revision: revision, selectedClip: selectedClip, scroll: scroll)
        }
        if let reveal, reveal.request != c.revealRequest {
            c.revealRequest = reveal.request
            c.reveal(reveal.word)
        }
        if !textEditing {
            c.highlight(currentWord, follow: followPlayhead)
            c.updateInspector(inspected, request: inspectRequest)
        }
        c.updateSearch(searchText, step: model.searchStep)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        let model: DocumentModel
        weak var textView: WordTextView?
        var revision = -1
        var selectedClip: ClipID?
        var revealRequest = -1
        var wordRanges: [NSRange] = []
        var highlighted: NSRange?
        private var settingSelection = false
        /// Text-edit mode (see `setEditing`).
        private(set) var editing = false
        private var sessionUndo: UndoManager?
        private var popover: NSPopover?
        private var popoverRequest = -1
        /// A bold bar at the inspected cut, so it's clear in the text which one is open.
        private var cutMark: NSView?

        init(model: DocumentModel) { self.model = model }

        /// Brings the text up to date by patching it: only the characters that changed
        /// are replaced and only differing attributes are set, so TextKit keeps the
        /// layout (and the scroll position) of everything else. The caret stays at
        /// the same word.
        func rebuild(revision: Int, selectedClip: ClipID?, scroll: NSScrollView) {
            guard let textView, let storage = textView.textStorage else { return }
            self.revision = revision
            self.selectedClip = selectedClip
            let caretWord = textView.selectedRange().length == 0 && !wordRanges.isEmpty
                ? min(firstWord(endingAfter: textView.selectedRange().location), wordRanges.count - 1) : nil
            let firstSelected = textView.selectedRange().length > 0 ? words(in: textView.selectedRange())?.lowerBound : nil
            let origin = scroll.contentView.bounds.origin

            let built = TranscriptText.build(model.project, selectedClip: selectedClip)
            wordRanges = built.wordRanges
            settingSelection = true
            Self.patch(storage, to: built.text)
            // The playhead highlight is re-applied by the next update.
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor,
                                                             forCharacterRange: NSRange(location: 0, length: storage.length))
            highlighted = nil
            if let s = model.selection, let r = charRange(words: s) {
                textView.setSelectedRange(r)
            } else if let w = firstSelected ?? caretWord, wordRanges.indices.contains(w) {
                textView.setSelectedRange(NSRange(location: wordRanges[w].location, length: 0))
            }
            settingSelection = false
            searchDirty = true
            // Belt and braces: if anything still nudged the view, put it back.
            if scroll.contentView.bounds.origin != origin {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// The attributes the transcript sets. NSTextStorage adds others of its own, which
        /// must not make every run look changed (that would relayout everything).
        static let styledKeys: [NSAttributedString.Key] = [
            .font, .foregroundColor, .backgroundColor, .paragraphStyle, .strikethroughStyle,
            .octoWord, .octoMarkerClip, .octoMarkerIn, .octoParagraph, .octoHeader,
        ]

        static func sameStyling(_ a: [NSAttributedString.Key: Any], _ b: [NSAttributedString.Key: Any]) -> Bool {
            styledKeys.allSatisfy { k in
                switch (a[k] as AnyObject?, b[k] as AnyObject?) {
                case (nil, nil): true
                case let (x?, y?): x.isEqual(y)
                default: false
                }
            }
        }

        /// Makes `storage` equal `target` with the smallest edit: the common prefix and
        /// suffix of the characters are kept, the middle replaced; in the kept parts,
        /// attributes are written only where they differ.
        static func patch(_ storage: NSTextStorage, to target: NSAttributedString) {
            let old = storage.string as NSString, new = target.string as NSString
            let oldLen = old.length, newLen = new.length
            var prefix = 0
            let maxPrefix = min(oldLen, newLen)
            while prefix < maxPrefix, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < min(oldLen, newLen) - prefix,
                  old.character(at: oldLen - 1 - suffix) == new.character(at: newLen - 1 - suffix) { suffix += 1 }

            storage.beginEditing()
            // Attributes in the kept prefix and suffix (positions in `target`).
            func syncAttributes(_ range: NSRange, oldOffset: Int) {
                guard range.length > 0 else { return }
                target.enumerateAttributes(in: range) { attrs, r, _ in
                    var eff = NSRange()
                    let current = storage.attributes(at: r.location + oldOffset, longestEffectiveRange: &eff,
                                                     in: NSRange(location: r.location + oldOffset, length: r.length))
                    if eff.length < r.length || !sameStyling(current, attrs) {
                        storage.setAttributes(attrs, range: NSRange(location: r.location + oldOffset, length: r.length))
                    }
                }
            }
            syncAttributes(NSRange(location: 0, length: prefix), oldOffset: 0)
            syncAttributes(NSRange(location: newLen - suffix, length: suffix), oldOffset: oldLen - newLen)
            let middleOld = NSRange(location: prefix, length: oldLen - prefix - suffix)
            let middleNew = NSRange(location: prefix, length: newLen - prefix - suffix)
            if middleOld.length > 0 || middleNew.length > 0 {
                storage.replaceCharacters(in: middleOld, with: target.attributedSubstring(from: middleNew))
            }
            storage.endEditing()
        }

        // MARK: Selection ↔ words

        // MARK: Text-edit mode

        /// Cut mode: typing never changes the words. Text-edit mode: typing is allowed
        /// inside a paragraph's words only — never in a header line, on a clip marker,
        /// or across a paragraph break (Return doesn't split paragraphs).
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard editing, let storage = textView.textStorage else { return false }
            if let r = replacementString, r.contains(where: \.isNewline) { return false }
            let text = storage.string as NSString
            if range.length > 0 {
                var ok = true
                storage.enumerateAttributes(in: range) { attrs, _, stop in
                    if attrs[.octoHeader] != nil || attrs[.octoMarkerClip] != nil { ok = false; stop.pointee = true }
                }
                if !ok || text.substring(with: range).contains(where: \.isNewline) { return false }
                return true
            }
            // An insertion point must sit in a body line (possibly at its very end).
            guard range.location < storage.length else { return false }
            if storage.attribute(.octoHeader, at: range.location, effectiveRange: nil) != nil { return false }
            return storage.attribute(.octoParagraph, at: range.location, effectiveRange: nil) != nil
        }

        func setEditing(_ on: Bool) {
            guard let textView else { return }
            editing = on
            sessionUndo = on ? UndoManager() : nil
            textView.allowsUndo = on
            textView.backgroundColor = on
                ? NSColor.textBackgroundColor.blended(withFraction: 0.07, of: .systemYellow) ?? .textBackgroundColor
                : .textBackgroundColor
            if on {
                textView.layoutManager?.removeTemporaryAttribute(.backgroundColor,
                    forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
                highlighted = nil
                searchDirty = true
                textView.window?.makeFirstResponder(textView)
            }
        }

        /// The session's own undo stack, so text-editing undo stays inside the session.
        func undoManager(for view: NSTextView) -> UndoManager? { editing ? sessionUndo : nil }

        /// Typed text gets the paragraph's plain body style (never a marker's or a word's).
        private func updateTypingAttributes(_ textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            let loc = min(textView.selectedRange().location, storage.length - 1)
            let probe = [loc, max(loc - 1, 0)].first { storage.attribute(.octoParagraph, at: $0, effectiveRange: nil) != nil }
            guard let k = probe, let pid = storage.attribute(.octoParagraph, at: k, effectiveRange: nil) else { return }
            textView.typingAttributes = TranscriptText.bodyAttributes(paragraph: pid as? Int ?? 0)
        }

        /// Each paragraph's words as edited: its body line, minus clip markers, split on spaces.
        func editedParagraphs() -> [(ParagraphID, [String])] {
            guard let storage = textView?.textStorage else { return [] }
            let text = storage.string as NSString
            var out: [(ParagraphID, [String])] = []
            var lineStart = 0
            while lineStart < text.length {
                let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
                defer { lineStart = NSMaxRange(line) }
                // The newline carries the paragraph id even when the line was emptied.
                let probe = NSMaxRange(line) - 1
                guard storage.attribute(.octoHeader, at: line.location, effectiveRange: nil) == nil,
                      let raw = storage.attribute(.octoParagraph, at: probe, effectiveRange: nil) as? Int else { continue }
                var body = ""
                storage.enumerateAttributes(in: line) { attrs, r, _ in
                    if attrs[.octoMarkerClip] == nil { body += text.substring(with: r) }
                }
                out.append((ParagraphID(raw), body.split(whereSeparator: { $0.isWhitespace }).map(String.init)))
            }
            return out
        }

        /// Selections cover whole words only. The end that moved outward grows to the
        /// whole word; an end that moved inward drops the partly covered word (so ⇧←
        /// steps back word by word instead of sticking at the word's end).
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard !editing, new.length > 0, !wordRanges.isEmpty else { return new }
            let newEnd = NSMaxRange(new)
            var start: Int
            if new.location > old.location && old.length > 0 {
                // Start moved right: first word starting at or after it.
                let i = firstWord(endingAfter: new.location)
                guard i < wordRanges.count else { return NSRange(location: new.location, length: 0) }
                start = wordRanges[i].location < new.location && i + 1 < wordRanges.count
                    ? wordRanges[i + 1].location : max(wordRanges[i].location, new.location)
            } else {
                // Start of the word containing it, or the next word.
                let i = firstWord(endingAfter: new.location)
                guard i < wordRanges.count else { return NSRange(location: new.location, length: 0) }
                start = min(wordRanges[i].location, new.location)
                if wordRanges[i].location > new.location { start = wordRanges[i].location }
            }
            // Last word that intersects the proposed range.
            var last = firstWord(endingAfter: newEnd - 1)
            if last >= wordRanges.count || wordRanges[last].location >= newEnd { last -= 1 }
            guard last >= 0 else { return NSRange(location: new.location, length: 0) }
            var end = NSMaxRange(wordRanges[last])
            if newEnd < NSMaxRange(old) && old.length > 0 && wordRanges[last].location < newEnd && newEnd < end {
                // End moved left into a word: drop that word.
                end = last > 0 ? NSMaxRange(wordRanges[last - 1]) : start
            }
            guard end > start else { return NSRange(location: new.location, length: 0) }
            return NSRange(location: start, length: end - start)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !settingSelection, let textView else { return }
            if editing { updateTypingAttributes(textView); return }
            let r = textView.selectedRange()
            if !wordRanges.isEmpty { model.caretWord = min(firstWord(endingAfter: r.location), wordRanges.count - 1) }
            model.selection = r.length == 0 ? nil : words(in: r)
        }

        /// Words whose characters intersect `r`.
        func words(in r: NSRange) -> ClosedRange<Int>? {
            let first = firstWord(endingAfter: r.location)
            guard first < wordRanges.count, wordRanges[first].location < NSMaxRange(r) else { return nil }
            var last = first
            while last + 1 < wordRanges.count, wordRanges[last + 1].location < NSMaxRange(r) { last += 1 }
            return first...last
        }

        /// First word whose end is after character `c`.
        func firstWord(endingAfter c: Int) -> Int {
            var lo = 0, hi = wordRanges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(wordRanges[mid]) <= c { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func charRange(words s: ClosedRange<Int>) -> NSRange? {
            guard s.upperBound < wordRanges.count else { return nil }
            let a = wordRanges[s.lowerBound], b = wordRanges[s.upperBound]
            return NSRange(location: a.location, length: NSMaxRange(b) - a.location)
        }

        /// The word a dragged marker would attach to when dropped at character `c`:
        /// a start marker goes before the word at/after the drop, an end marker after
        /// the word at/before it.
        func dropWord(at c: Int, inPoint: Bool) -> Int? {
            guard !wordRanges.isEmpty else { return nil }
            let i = firstWord(endingAfter: c)
            if i < wordRanges.count, wordRanges[i].location <= c { return i }   // inside a word
            return inPoint ? min(i, wordRanges.count - 1) : max(i - 1, 0)
        }

        // MARK: Playhead and reveal

        func reveal(_ word: Int) {
            guard let textView, wordRanges.indices.contains(word) else { return }
            textView.scrollRangeToVisible(wordRanges[word])
            // Bring it toward the top third rather than the very edge.
            if let scroll = textView.enclosingScrollView, let rect = rect(for: wordRanges[word]) {
                let y = max(rect.minY - scroll.contentView.bounds.height / 3, 0)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        func rect(for r: NSRange) -> NSRect? {
            guard let textView, let lm = textView.layoutManager, let tc = textView.textContainer,
                  NSMaxRange(r) <= (textView.textStorage?.length ?? 0) else { return nil }
            let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        }

        private var highlightedWord: Int?

        /// Marks the word under the playhead with a temporary (display-only) attribute,
        /// so the text itself — and its layout — never changes during playback. Scrolls
        /// only when the playhead moves to another word while a video is playing.
        func highlight(_ word: Int?, follow: Bool) {
            guard let textView, let lm = textView.layoutManager else { return }
            let range = word.flatMap { wordRanges.indices.contains($0) ? wordRanges[$0] : nil }
            guard range != highlighted else { return }
            let length = textView.textStorage?.length ?? 0
            if let old = highlighted, NSMaxRange(old) <= length {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
                restoreSearchHighlights(in: old)
            }
            highlighted = range
            if let range, NSMaxRange(range) <= length {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: range)
            }
            if follow, word != highlightedWord, let range { textView.scrollRangeToVisible(range) }
            highlightedWord = word
        }

        // MARK: Search

        private var searchQuery = ""
        private var searchDirty = false
        private var searchMatches: [NSRange] = []
        private var searchIndex = -1
        private var lastSearchStep = 0
        private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.45)

        /// Highlights every match of `query` and steps through them on Find Next/Previous.
        func updateSearch(_ query: String, step: (delta: Int, id: Int)) {
            guard let textView, let storage = textView.textStorage, let lm = textView.layoutManager else { return }
            if query != searchQuery || searchDirty {
                let queryChanged = query != searchQuery
                searchQuery = query
                searchDirty = false
                for r in searchMatches where NSMaxRange(r) <= storage.length {
                    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
                }
                searchMatches = []
                if query.count >= 1 {
                    let text = storage.string as NSString
                    var from = 0
                    while from < text.length {
                        let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: NSRange(location: from, length: text.length - from))
                        if r.location == NSNotFound { break }
                        searchMatches.append(r)
                        from = NSMaxRange(r)
                    }
                    for r in searchMatches { lm.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: r) }
                }
                if let h = highlighted, NSMaxRange(h) <= storage.length {
                    lm.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: h)
                }
                if queryChanged {
                    // Typing a query jumps to the first match at or after the caret.
                    let caret = textView.selectedRange().location
                    searchIndex = (searchMatches.firstIndex { $0.location >= caret } ?? 0) - 1
                    if !searchMatches.isEmpty { move(1) }
                } else {
                    searchIndex = min(searchIndex, searchMatches.count - 1)
                }
                publishStatus()
            }
            if step.id != lastSearchStep {
                lastSearchStep = step.id
                if !searchMatches.isEmpty { move(step.delta) }
                publishStatus()
            }
        }

        private func move(_ delta: Int) {
            guard let textView, !searchMatches.isEmpty else { return }
            searchIndex = ((searchIndex + delta) % searchMatches.count + searchMatches.count) % searchMatches.count
            let r = searchMatches[searchIndex]
            textView.scrollRangeToVisible(r)
            textView.showFindIndicator(for: r)
        }

        private func publishStatus() {
            let status = searchQuery.isEmpty ? "" : searchMatches.isEmpty ? "No matches"
                : "\(max(searchIndex, 0) + 1) of \(searchMatches.count)"
            let model = model
            DispatchQueue.main.async { if model.searchStatus != status { model.searchStatus = status } }
        }

        /// Puts search highlights back where a playhead highlight was removed.
        private func restoreSearchHighlights(in range: NSRange) {
            guard let lm = textView?.layoutManager else { return }
            for r in searchMatches where NSIntersectionRange(r, range).length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: r)
            }
        }

        // MARK: Boundary inspector popover

        /// Shows, moves or closes the inspector popover to match the model.
        func updateInspector(_ b: BoundaryRef?, request: Int) {
            guard let textView else { return }
            guard let b else {
                if let popover, popover.isShown { popover.close() }
                cutMark?.removeFromSuperview()
                cutMark = nil
                return
            }
            guard let rect = anchorRect(b) else { return }
            placeCutMark(b, at: rect, in: textView)
            if let popover, popover.isShown {
                popover.positioningRect = rect
                return
            }
            guard request != popoverRequest else { return }
            popoverRequest = request
            let p = NSPopover()
            p.behavior = .semitransient
            p.animates = false
            p.delegate = self
            let host = NSHostingController(rootView: BoundaryInspector(model: model, dismiss: { [weak p] in p?.performClose(nil) }))
            host.sizingOptions = [.preferredContentSize]   // the popover takes the SwiftUI view's size
            p.contentViewController = host
            p.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            popover = p
        }

        private func placeCutMark(_ b: BoundaryRef, at rect: NSRect, in textView: NSTextView) {
            let mark = cutMark ?? {
                let v = NSView()
                v.wantsLayer = true
                v.layer?.cornerRadius = 2
                textView.addSubview(v)
                cutMark = v
                return v
            }()
            mark.layer?.backgroundColor = markerColor(b.clip).cgColor
            mark.layer?.borderColor = NSColor.labelColor.cgColor
            mark.layer?.borderWidth = 0.5
            mark.frame = NSRect(x: rect.midX - 2.5, y: rect.minY - 5, width: 5, height: rect.height + 10)
        }

        /// A thin rect at the cut: before the anchor word for an in-point, after it for an out-point.
        private func anchorRect(_ b: BoundaryRef) -> NSRect? {
            guard let w = model.project.anchorWord(of: b), wordRanges.indices.contains(w),
                  let r = rect(for: wordRanges[w]) else { return nil }
            return NSRect(x: b.inPoint ? r.minX - 1 : r.maxX, y: r.minY, width: 2, height: r.height)
        }

        func popoverDidClose(_ notification: Notification) {
            // However it closed (Done, Esc, a click elsewhere, or the cut going away),
            // stop whatever the inspector was playing.
            model.closeInspector()
            popover = nil
        }

        func markerColor(_ clip: ClipID) -> NSColor {
            ClipPalette.nsColor(model.project.clips.firstIndex { $0.id == clip } ?? 0)
        }

    }
}

/// Cut-mode text view: a click (no drag) on a word seeks; dragging selects; a clip
/// marker can be dragged to another word; the Clip shortcuts work without ⌘.
final class WordTextView: NSTextView {
    weak var coordinator: TranscriptView.Coordinator?

    private var editing: Bool { coordinator?.editing ?? false }

    override func mouseDown(with event: NSEvent) {
        if editing { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if let marker = marker(at: point) {
            if event.clickCount == 2, let coordinator, let b = coordinator.model.boundary(for: marker) {
                coordinator.model.inspect(b)
                return
            }
            trackMarker(marker, from: event)
            return
        }
        let plain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        if event.clickCount == 1 && plain {
            trackSelection(from: event)    // our own loop, so two-finger scrolling works while dragging
        } else {
            super.mouseDown(with: event)   // double/triple-click and shift-click: AppKit's own
        }
        // Double-clicking a cut-out word opens the inspector at the nearest cut.
        if event.clickCount == 2, let w = word(at: point), let coordinator,
           let storage = textStorage, coordinator.wordRanges.indices.contains(w),
           storage.attribute(.strikethroughStyle, at: coordinator.wordRanges[w].location, effectiveRange: nil) != nil {
            coordinator.model.inspectNearest(word: w)
            return
        }
        guard selectedRange().length == 0, let w = word(at: point), let coordinator else { return }
        if coordinator.model.clicked(word: w), coordinator.wordRanges.indices.contains(w) {
            setSelectedRange(coordinator.wordRanges[w])
        }
    }

    /// Drag-to-select that also lets scroll events through (AppKit's own loop swallows
    /// them): the selection keeps following the pointer as the text scrolls under it.
    private func trackSelection(from down: NSEvent) {
        guard let window else { return }
        let anchor = characterIndexForInsertion(at: convert(down.locationInWindow, from: nil))
        window.makeFirstResponder(self)
        setSelectedRange(NSRange(location: anchor, length: 0))
        var pointer = down.locationInWindow
        var dragged = false
        func follow() {
            let c = characterIndexForInsertion(at: convert(pointer, from: nil))
            setSelectedRange(NSRange(location: min(anchor, c), length: abs(c - anchor)),
                             affinity: .downstream, stillSelecting: true)
        }
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .scrollWheel]) {
            if e.type == .leftMouseUp { break }
            if e.type == .scrollWheel {
                enclosingScrollView?.scrollWheel(with: e)
                if dragged { follow() }
                continue
            }
            pointer = e.locationInWindow
            if !dragged, hypot(pointer.x - down.locationInWindow.x, pointer.y - down.locationInWindow.y) < 3 { continue }
            dragged = true
            autoscroll(with: e)
            follow()
        }
        setSelectedRange(selectedRange(), affinity: .downstream, stillSelecting: false)
    }

    // MARK: Cursor over markers

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["octo"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["octo": true]))
    }

    /// The ↔ cursor over a clip marker (they can be dragged); the text cursor elsewhere.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if !editing, marker(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !editing, marker(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Plain text only when pasting in text-edit mode (no stray styles or markers).
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        editing ? [.string] : super.readablePasteboardTypes
    }

    private func word(at point: NSPoint) -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let i = characterIndexForInsertion(at: point)
        for k in [i, i - 1] where k >= 0 && k < storage.length {
            if let w = storage.attribute(.octoWord, at: k, effectiveRange: nil) as? Int { return w }
        }
        return nil
    }

    private func marker(at point: NSPoint) -> MarkerRef? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let i = characterIndexForInsertion(at: point)
        for k in [i, i - 1] where k >= 0 && k < storage.length {
            if let raw = storage.attribute(.octoMarkerClip, at: k, effectiveRange: nil) as? Int,
               let isIn = storage.attribute(.octoMarkerIn, at: k, effectiveRange: nil) as? Bool {
                return MarkerRef(clip: ClipID(raw), inPoint: isIn)
            }
        }
        return nil
    }

    /// Drag loop for a marker: a caret in the clip's colour shows where the boundary
    /// will land (before the word for a start, after it for an end); on release the
    /// boundary moves there. A click without a drag just selects the clip.
    private func trackMarker(_ marker: MarkerRef, from down: NSEvent) {
        guard let window, let coordinator else { return }
        let start = down.locationInWindow
        var dragged = false
        var target: Int?
        let caret = NSView()
        caret.wantsLayer = true
        caret.layer?.backgroundColor = coordinator.markerColor(marker.clip).cgColor
        caret.layer?.cornerRadius = 1.5
        caret.isHidden = true
        addSubview(caret)
        NSCursor.resizeLeftRight.push()
        defer {
            NSCursor.pop()
            caret.removeFromSuperview()
        }
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            if !dragged, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 3 { continue }
            dragged = true
            autoscroll(with: e)
            let p = convert(e.locationInWindow, from: nil)
            let t = coordinator.dropWord(at: characterIndexForInsertion(at: p), inPoint: marker.inPoint)
            guard t != target else { continue }
            target = t
            guard let t, let r = coordinator.rect(for: coordinator.wordRanges[t]) else { caret.isHidden = true; continue }
            // Before the word's first letter for a start marker, after its last for an end.
            let x = marker.inPoint ? r.minX - 3 : r.maxX + 1
            caret.frame = NSRect(x: x, y: r.minY - 2, width: 3, height: r.height + 4)
            caret.isHidden = false
        }
        if dragged, let target {
            coordinator.model.moveBoundary(clip: marker.clip, inPoint: marker.inPoint, to: target)
        } else {
            coordinator.model.select(clip: marker.clip, seekSource: true)
        }
    }

    @objc private func setSpeakerFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let model = coordinator?.model, let window else { return }
        let pid = ParagraphID(raw)
        let current = model.project.paragraph(pid)?.speaker ?? ""
        let alert = NSAlert()
        alert.messageText = "Speaker"
        alert.informativeText = "Leave empty for no speaker."
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let everywhere = NSButton(checkboxWithTitle: current.isEmpty ? "Every paragraph without a speaker"
                                                                      : "Every paragraph by “\(current)”",
                                  target: nil, action: nil)
        let stack = NSStackView(views: [field, everywhere])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            model.setSpeaker(of: pid, to: field.stringValue, everywhere: everywhere.state == .on)
        }
    }

    /// No drag-and-drop of selected text (dragging is for selecting and for markers).
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

    /// Cut-mode keys without ⌘. (The same commands are in the Clip menu.)
    override func keyDown(with event: NSEvent) {
        if editing { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let action: Selector? = switch (event.keyCode, mods, key) {
        case (51, [], _), (117, [], _): #selector(ProjectDocument.omitSelection(_:))
        case (51, .shift, _), (117, .shift, _): #selector(ProjectDocument.restoreSelection(_:))
        case (_, [], "i"): #selector(ProjectDocument.setClipStart(_:))
        case (_, [], "o"): #selector(ProjectDocument.setClipEnd(_:))
        case (49, [], _): #selector(ProjectDocument.togglePlayPause(_:))
        default: nil
        }
        if let action {
            NSApp.sendAction(action, to: nil, from: self)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // On a paragraph header: set its speaker.
        let point = convert(event.locationInWindow, from: nil)
        if let storage = textStorage, storage.length > 0, let coordinator {
            let i = min(characterIndexForInsertion(at: point), storage.length - 1)
            if storage.attribute(.octoHeader, at: i, effectiveRange: nil) != nil,
               let raw = storage.attribute(.octoParagraph, at: i, effectiveRange: nil) as? Int {
                let menu = NSMenu()
                let item = NSMenuItem(title: "Set Speaker…", action: #selector(setSpeakerFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = raw
                item.isEnabled = !coordinator.model.loadErrors
                menu.addItem(item)
                return menu
            }
        }
        if editing { return super.menu(for: event) }
        let menu = NSMenu()
        for item in MainMenu.clipItems() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        return menu
    }
}

/// Builds the attributed transcript and remembers where each word landed.
enum TranscriptText {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let bodyStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 14
        return p
    }()

    /// Plain text in a paragraph (what typing in text-edit mode produces).
    static func bodyAttributes(paragraph: Int) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont, .paragraphStyle: bodyStyle, .foregroundColor: NSColor.labelColor, .octoParagraph: paragraph]
    }

    static func build(_ p: Project, selectedClip: ClipID?) -> (text: NSAttributedString, wordRanges: [NSRange]) {
        let out = NSMutableAttributedString()
        var ranges = Array(repeating: NSRange(location: NSNotFound, length: 0), count: p.words.count)

        let body = bodyFont
        let paragraphStyle = bodyStyle
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacing = 2
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: headerStyle,
        ]

        // Clip membership and omissions, by word index.
        var clipOf = [Int: Int]()          // word index → clip ordinal
        var omitted = Set<Int>()
        var opens = [Int: (Int, Clip)](), closes = [Int: (Int, Clip)]()
        for (n, clip) in p.clips.enumerated() {
            guard let r = p.indexRange(of: clip) else { continue }
            for i in r { clipOf[i] = n }
            opens[r.lowerBound] = (n, clip)
            closes[r.upperBound] = (n, clip)
            for o in p.omittedRanges(of: clip) { omitted.formUnion(o) }
        }
        let slugs = p.slugs()
        let selectedOrdinal = selectedClip.flatMap { id in p.clips.firstIndex { $0.id == id } }
        func band(_ n: Int) -> NSColor {
            let emphasis: CGFloat = selectedOrdinal == nil ? 0.16 : (n == selectedOrdinal ? 0.26 : 0.08)
            return ClipPalette.nsColor(n).withAlphaComponent(emphasis)
        }
        func marker(_ label: String, _ n: Int, _ clip: Clip, inPoint: Bool, paragraph: Int) -> NSAttributedString {
            let selected = selectedOrdinal == nil || n == selectedOrdinal
            return NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white,
                .backgroundColor: ClipPalette.nsColor(n).withAlphaComponent(selected ? 1 : 0.45),
                .octoMarkerClip: clip.id.raw, .octoMarkerIn: inPoint, .octoParagraph: paragraph,
            ])
        }

        var i = 0
        var lastTime = 0.0
        while i < p.words.count {
            let pid = p.words[i].paragraph
            var j = i
            while j < p.words.count, p.words[j].paragraph == pid { j += 1 }
            let para = p.paragraph(pid) ?? Paragraph(id: pid)

            if let t = p.words[i..<j].first(where: { $0.isTimed })?.start { lastTime = t }
            let time = para.zoomOnly ? (para.zoomStart ?? 0) : lastTime
            var header = timestamp(time)
            if let s = para.speaker { header += "   " + s.uppercased() }
            if para.zoomOnly { header += "   (Zoom only — not in the video)" }
            var hAttrs = headerAttrs
            hAttrs[.octoHeader] = true
            hAttrs[.octoParagraph] = pid.raw
            out.append(NSAttributedString(string: header + "\n", attributes: hAttrs))

            for k in i..<j {
                if let (n, clip) = opens[k] {
                    out.append(marker(" ▶ \(clip.name ?? slugs[clip.id] ?? "clip") ", n, clip, inPoint: true, paragraph: pid.raw))
                    out.append(NSAttributedString(string: " ", attributes: [.font: body, .octoParagraph: pid.raw]))
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: body, .paragraphStyle: paragraphStyle, .octoWord: k,
                    .foregroundColor: NSColor.labelColor, .octoParagraph: pid.raw,
                ]
                let w = p.words[k]
                if para.zoomOnly || !w.isTimed {
                    attrs[.foregroundColor] = NSColor.tertiaryLabelColor
                }
                if let n = clipOf[k] { attrs[.backgroundColor] = band(n) }
                if omitted.contains(k) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                }
                ranges[k] = NSRange(location: out.length, length: (w.text as NSString).length)
                out.append(NSAttributedString(string: w.text, attributes: attrs))
                if let (n, clip) = closes[k] {
                    out.append(NSAttributedString(string: " ", attributes: [.font: body, .octoParagraph: pid.raw]))
                    out.append(marker(" ◀ ", n, clip, inPoint: false, paragraph: pid.raw))
                }
                // Keep the band continuous between words of the same clip.
                let sep = k + 1 < j ? " " : "\n"
                var sepAttrs: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: paragraphStyle, .octoParagraph: pid.raw]
                if sep == " ", let n = clipOf[k], clipOf[k + 1] == n, closes[k] == nil {
                    sepAttrs[.backgroundColor] = band(n)
                    if omitted.contains(k) && omitted.contains(k + 1) {
                        sepAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                }
                out.append(NSAttributedString(string: sep, attributes: sepAttrs))
            }
            i = j
        }
        return (out, ranges)
    }

    static func timestamp(_ t: Double) -> String {
        let tenths = Int((max(t, 0) * 10).rounded(.down))
        return String(format: "%02d:%02d:%02d.%d", tenths / 36000, (tenths / 600) % 60, (tenths / 10) % 60, tenths % 10)
    }
}
