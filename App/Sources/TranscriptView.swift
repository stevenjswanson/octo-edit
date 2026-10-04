import AppKit
import SwiftUI
import Core

extension NSAttributedString.Key {
    /// Index into `project.words` for each word's characters.
    static let octoWord = NSAttributedString.Key("octoWord")
    /// On a clip marker's characters: the clip's raw id, and whether it's the start marker.
    static let octoMarkerClip = NSAttributedString.Key("octoMarkerClip")
    static let octoMarkerIn = NSAttributedString.Key("octoMarkerIn")
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
    let reveal: (word: Int, request: Int)?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = WordTextView(usingTextLayoutManager: true)
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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.revision != revision || c.selectedClip != selectedClip {
            c.rebuild(revision: revision, selectedClip: selectedClip, scroll: scroll)
        }
        if let reveal, reveal.request != c.revealRequest {
            c.revealRequest = reveal.request
            c.reveal(reveal.word)
        }
        c.highlight(currentWord)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: DocumentModel
        weak var textView: WordTextView?
        var revision = -1
        var selectedClip: ClipID?
        var revealRequest = -1
        var wordRanges: [NSRange] = []
        var highlighted: NSRange?
        private var settingSelection = false

        init(model: DocumentModel) { self.model = model }

        /// Replaces the text, keeping the view still: the word at the top of the view
        /// stays at the same height, and the caret stays at the same word.
        func rebuild(revision: Int, selectedClip: ClipID?, scroll: NSScrollView) {
            guard let textView else { return }
            self.revision = revision
            self.selectedClip = selectedClip
            let anchor = topVisibleWord()
            let caretWord = textView.selectedRange().length == 0 && !wordRanges.isEmpty
                ? min(firstWord(endingAfter: textView.selectedRange().location), wordRanges.count - 1) : nil
            let firstSelected = textView.selectedRange().length > 0 ? words(in: textView.selectedRange())?.lowerBound : nil

            let built = TranscriptText.build(model.project, selectedClip: selectedClip)
            wordRanges = built.wordRanges
            highlighted = nil
            settingSelection = true
            textView.textStorage?.setAttributedString(built.text)
            if let s = model.selection, let r = charRange(words: s) {
                textView.setSelectedRange(r)
            } else if let w = firstSelected ?? caretWord, wordRanges.indices.contains(w) {
                textView.setSelectedRange(NSRange(location: wordRanges[w].location, length: 0))
            }
            settingSelection = false
            if let anchor { restore(anchor, in: scroll) }
        }

        /// The first word at least partly visible, and its distance below the top edge.
        private func topVisibleWord() -> (word: Int, offset: CGFloat)? {
            guard let textView, let tlm = textView.textLayoutManager, let content = tlm.textContentManager,
                  !wordRanges.isEmpty else { return nil }
            let top = textView.visibleRect.minY
            guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: top - textView.textContainerOrigin.y + 1)) else { return nil }
            let c = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var w = firstWord(endingAfter: c)
            // Step forward to the first word whose top is in view.
            while w < wordRanges.count, let r = rect(for: wordRanges[w]), r.minY < top - 0.5 { w += 1 }
            guard w < wordRanges.count, let r = rect(for: wordRanges[w]) else { return nil }
            return (w, r.minY - top)
        }

        private func restore(_ anchor: (word: Int, offset: CGFloat), in scroll: NSScrollView) {
            guard let textView, let tlm = textView.textLayoutManager, wordRanges.indices.contains(anchor.word),
                  let target = textRange(wordRanges[anchor.word]),
                  let docStart = tlm.textContentManager?.documentRange.location else { return }
            // Lay out everything above the anchor so its position is real, not estimated.
            tlm.ensureLayout(for: NSTextRange(location: docStart, end: target.endLocation) ?? target)
            guard let r = rect(for: wordRanges[anchor.word]) else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(r.minY - anchor.offset, 0)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // MARK: Selection ↔ words

        /// Cut mode: the words themselves are never changed by typing.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { false }

        /// Selections cover whole words only. The end that moved outward grows to the
        /// whole word; an end that moved inward drops the partly covered word (so ⇧←
        /// steps back word by word instead of sticking at the word's end).
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard new.length > 0, !wordRanges.isEmpty else { return new }
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
            let r = textView.selectedRange()
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
            guard let textView, let tlm = textView.textLayoutManager, let range = textRange(r) else { return nil }
            var out: NSRect?
            tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                out = out.map { $0.union(frame) } ?? frame
                return true
            }
            return out.map { $0.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y) }
        }

        private var highlightedWord: Int?
        private var savedBackground: Any?

        /// Marks the word under the playhead by changing its background in the text
        /// itself (restoring the clip band afterwards), and keeps it in view.
        func highlight(_ word: Int?) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = word.flatMap { wordRanges.indices.contains($0) ? wordRanges[$0] : nil }
            guard range != highlighted else { return }
            storage.beginEditing()
            if let old = highlighted, NSMaxRange(old) <= storage.length {
                if let bg = savedBackground { storage.addAttribute(.backgroundColor, value: bg, range: old) }
                else { storage.removeAttribute(.backgroundColor, range: old) }
            }
            highlighted = range
            if let range {
                savedBackground = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil)
                storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range)
            }
            storage.endEditing()
            // Scroll only when the playhead actually moved to another word (not when the
            // highlight is re-applied after a rebuild), so edits never move the view.
            if word != highlightedWord, let range { textView.scrollRangeToVisible(range) }
            highlightedWord = word
        }

        func markerColor(_ clip: ClipID) -> NSColor {
            ClipPalette.nsColor(model.project.clips.firstIndex { $0.id == clip } ?? 0)
        }

        func textRange(_ r: NSRange) -> NSTextRange? {
            guard let content = textView?.textLayoutManager?.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: r.location),
                  let end = content.location(start, offsetBy: r.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }
    }
}

/// Cut-mode text view: a click (no drag) on a word seeks; dragging selects; a clip
/// marker can be dragged to another word; the Clip shortcuts work without ⌘.
final class WordTextView: NSTextView {
    weak var coordinator: TranscriptView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marker = marker(at: point) {
            trackMarker(marker, from: event)
            return
        }
        super.mouseDown(with: event)   // runs the selection tracking loop until mouse-up
        guard selectedRange().length == 0, let w = word(at: point), let coordinator else { return }
        if coordinator.model.clicked(word: w), coordinator.wordRanges.indices.contains(w) {
            setSelectedRange(coordinator.wordRanges[w])
        }
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

    /// No drag-and-drop of selected text (dragging is for selecting and for markers).
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

    /// Cut-mode keys without ⌘. (The same commands are in the Clip menu.)
    override func keyDown(with event: NSEvent) {
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
        let menu = NSMenu()
        for item in MainMenu.clipItems() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        return menu
    }
}

/// Builds the attributed transcript and remembers where each word landed.
enum TranscriptText {
    static func build(_ p: Project, selectedClip: ClipID?) -> (text: NSAttributedString, wordRanges: [NSRange]) {
        let out = NSMutableAttributedString()
        var ranges = Array(repeating: NSRange(location: NSNotFound, length: 0), count: p.words.count)

        let body = NSFont.systemFont(ofSize: 15)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 14
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
        func marker(_ label: String, _ n: Int, _ clip: Clip, inPoint: Bool) -> NSAttributedString {
            let selected = selectedOrdinal == nil || n == selectedOrdinal
            return NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white,
                .backgroundColor: ClipPalette.nsColor(n).withAlphaComponent(selected ? 1 : 0.45),
                .octoMarkerClip: clip.id.raw, .octoMarkerIn: inPoint,
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
            out.append(NSAttributedString(string: header + "\n", attributes: headerAttrs))

            for k in i..<j {
                if let (n, clip) = opens[k] {
                    out.append(marker(" ▶ \(clip.name ?? slugs[clip.id] ?? "clip") ", n, clip, inPoint: true))
                    out.append(NSAttributedString(string: " ", attributes: [.font: body]))
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: body, .paragraphStyle: paragraphStyle, .octoWord: k,
                    .foregroundColor: NSColor.labelColor,
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
                    out.append(NSAttributedString(string: " ", attributes: [.font: body]))
                    out.append(marker(" ◀ ", n, clip, inPoint: false))
                }
                // Keep the band continuous between words of the same clip.
                let sep = k + 1 < j ? " " : "\n"
                var sepAttrs: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: paragraphStyle]
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
