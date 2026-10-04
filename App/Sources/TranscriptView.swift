import AppKit
import SwiftUI
import Core

extension NSAttributedString.Key {
    /// Index into `project.words` for each word's characters.
    static let octoWord = NSAttributedString.Key("octoWord")
}

/// The transcript, read-only for now (B1): paragraphs with time + speaker headers,
/// clip bands, struck-through omissions. Click a word to seek the source; the word
/// under the playhead is highlighted and kept in view while playing.
struct TranscriptView: NSViewRepresentable {
    let project: Project
    let revision: Int
    let currentWord: Int?
    let followPlayhead: Bool
    let onClickWord: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = WordTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 24, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let textView = c.textView else { return }
        textView.onClickWord = onClickWord
        if c.revision != revision {
            c.revision = revision
            let built = TranscriptText.build(project)
            c.wordRanges = built.wordRanges
            c.highlighted = nil
            textView.textStorage?.setAttributedString(built.text)
        }
        c.highlight(currentWord, scroll: followPlayhead)
    }

    final class Coordinator {
        var textView: WordTextView?
        var revision = -1
        var wordRanges: [NSRange] = []
        var highlighted: NSRange?

        func highlight(_ word: Int?, scroll: Bool) {
            guard let textView, let tlm = textView.textLayoutManager, let content = tlm.textContentManager else { return }
            let range = word.flatMap { wordRanges.indices.contains($0) ? wordRanges[$0] : nil }
            guard range != highlighted else { return }
            if let old = highlighted, let r = textRange(old, content) {
                tlm.removeRenderingAttribute(.backgroundColor, for: r)
            }
            highlighted = range
            guard let range, let r = textRange(range, content) else { return }
            tlm.addRenderingAttribute(.backgroundColor, value: NSColor.findHighlightColor, for: r)
            if scroll { textView.scrollRangeToVisible(range) }
        }

        private func textRange(_ r: NSRange, _ content: NSTextContentManager) -> NSTextRange? {
            guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                  let end = content.location(start, offsetBy: r.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }
    }
}

/// A click (no drag) on a word reports it; dragging still selects text for copying.
final class WordTextView: NSTextView {
    var onClickWord: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)   // runs the selection tracking loop until mouse-up
        guard selectedRange().length == 0, let storage = textStorage, storage.length > 0 else { return }
        let i = characterIndexForInsertion(at: point)
        for k in [i, i - 1] where k >= 0 && k < storage.length {
            if let w = storage.attribute(.octoWord, at: k, effectiveRange: nil) as? Int {
                onClickWord?(w)
                return
            }
        }
    }
}

/// Builds the attributed transcript and remembers where each word landed.
enum TranscriptText {
    static func build(_ p: Project) -> (text: NSAttributedString, wordRanges: [NSRange]) {
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
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white,
        ]

        // Clip membership and omissions, by word index.
        var clipOf = [Int: Int]()          // word index → clip ordinal
        var omitted = Set<Int>()
        var opens = [Int: (Int, Clip)](), closes = [Int: Int]()
        for (n, clip) in p.clips.enumerated() {
            guard let r = p.indexRange(of: clip) else { continue }
            for i in r { clipOf[i] = n }
            opens[r.lowerBound] = (n, clip)
            closes[r.upperBound] = n
            for o in p.omittedRanges(of: clip) { omitted.formUnion(o) }
        }
        let slugs = p.slugs()

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
                    let label = " ▶ \(clip.name ?? slugs[clip.id] ?? "clip") "
                    var a = markerAttrs
                    a[.backgroundColor] = ClipPalette.nsColor(n)
                    out.append(NSAttributedString(string: label, attributes: a))
                    out.append(NSAttributedString(string: " "))
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: body, .paragraphStyle: paragraphStyle, .octoWord: k,
                    .foregroundColor: NSColor.labelColor,
                ]
                let w = p.words[k]
                if para.zoomOnly || !w.isTimed {
                    attrs[.foregroundColor] = NSColor.tertiaryLabelColor
                }
                if let n = clipOf[k] {
                    attrs[.backgroundColor] = ClipPalette.nsColor(n).withAlphaComponent(0.16)
                }
                if omitted.contains(k) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.foregroundColor] = NSColor.secondaryLabelColor
                }
                ranges[k] = NSRange(location: out.length, length: (w.text as NSString).length)
                out.append(NSAttributedString(string: w.text, attributes: attrs))
                if let n = closes[k] {
                    var a = markerAttrs
                    a[.backgroundColor] = ClipPalette.nsColor(n)
                    out.append(NSAttributedString(string: " "))
                    out.append(NSAttributedString(string: " ◀ ", attributes: a))
                }
                // Keep the band continuous between words of the same clip.
                let sep = k + 1 < j ? " " : "\n"
                var sepAttrs: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: paragraphStyle]
                if sep == " ", let n = clipOf[k], clipOf[k + 1] == n, closes[k] == nil {
                    sepAttrs[.backgroundColor] = ClipPalette.nsColor(n).withAlphaComponent(0.16)
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
