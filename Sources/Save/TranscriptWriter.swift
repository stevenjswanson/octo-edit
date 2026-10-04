import Foundation
import Core
import MarkupGrammar

/// Renders a Project as canonical transcript.md text.
public enum TranscriptWriter {
    public static func write(_ project: Project) -> String {
        var lines: [String] = []
        lines += frontMatter(project)
        lines += body(project)
        let notes = noteBlock(project)
        if !notes.isEmpty {
            lines.append("")
            lines += notes
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Front matter

    static func frontMatter(_ p: Project) -> [String] {
        var out = [Grammar.frontMatterFence, "octoedit: \(PackageLayout.formatVersion)", "source: \(yaml(p.source))"]
        if let z = p.zoom {
            out.append("zoom: { file: \(yaml(z.file)), offset: \(String(format: "%.3f", z.offset)) }")
        }
        var defaults = "defaults: { pre: \(Grammar.duration(p.settings.prePad)), post: \(Grammar.duration(p.settings.postPad)), crossfade: \(Grammar.duration(p.settings.crossfade))"
        if let c = p.settings.codec { defaults += ", codec: \(c.rawValue)" }
        out.append(defaults + " }")
        let slugs = p.slugs()
        let suggested = p.clips.filter { !$0.suggestions.isEmpty }
        if !suggested.isEmpty {
            out.append("suggestions:")
            for c in suggested {
                out.append("  \(yaml(slugs[c.id]!)): [" + c.suggestions.map(quoted).joined(separator: ", ") + "]")
            }
        }
        out.append(Grammar.frontMatterFence)
        return out
    }

    /// Plain YAML scalar when unambiguous, otherwise a double-quoted string.
    static func yaml(_ s: String) -> String {
        let safe = s.range(of: #"^[A-Za-z0-9_./~][A-Za-z0-9_./~ ()-]*$"#, options: .regularExpression) != nil
            && !s.hasSuffix(" ")
            && !["true", "false", "yes", "no", "null", "on", "off", "~"].contains(s.lowercased())
            && Double(s) == nil
        return safe ? s : quoted(s)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    // MARK: Body

    /// Where clip markers, omit fences and offsets attach, by word index.
    struct Marks {
        var open: [Int: Clip] = [:]
        var close: [Int: Clip] = [:]
        var omitted = Set<Int>()
        var omitOpenOffset: [Int: Seconds] = [:]   // first word of an omitted run
        var omitCloseOffset: [Int: Seconds] = [:]  // last word of an omitted run

        init(_ p: Project) {
            for clip in p.clips {
                guard let range = p.indexRange(of: clip) else { continue }
                open[range.lowerBound] = clip
                close[range.upperBound] = clip
                let segRanges = clip.segments.map { p.indexRange(of: $0) }
                for k in 0..<max(clip.segments.count - 1, 0) {
                    guard let a = segRanges[k], let b = segRanges[k + 1], a.upperBound + 1 < b.lowerBound else { continue }
                    for i in (a.upperBound + 1)..<b.lowerBound { omitted.insert(i) }
                    if let o = clip.segments[k].outPoint.offset { omitOpenOffset[a.upperBound + 1] = o }
                    if let o = clip.segments[k + 1].inPoint.offset { omitCloseOffset[b.lowerBound - 1] = o }
                }
            }
        }
    }

    /// Each paragraph is written as a single line: no wrapping, so an edit never
    /// re-flows its neighbours and every `~~…~~` stays on one line.
    static func body(_ p: Project) -> [String] {
        let marks = Marks(p)
        let slugs = p.slugs()
        var out: [String] = []
        var lastTime: Seconds = 0
        var i = 0
        while i < p.words.count {
            let pid = p.words[i].paragraph
            var j = i
            while j < p.words.count, p.words[j].paragraph == pid { j += 1 }
            let para = p.paragraph(pid) ?? Paragraph(id: pid)
            out.append("")
            if para.zoomOnly {
                out.append(Grammar.zoomHeaderLine(time: para.zoomStart ?? 0, speaker: para.speaker))
                out.append(Grammar.zoomPrefix + p.words[i..<j].map(\.text).joined(separator: " "))
            } else {
                if let t = p.words[i..<j].first(where: { $0.isTimed })?.start { lastTime = t }
                out.append(Grammar.paragraphHeaderLine(time: lastTime, speaker: para.speaker))
                out.append(units(p, i..<j, marks, slugs).joined(separator: " "))
            }
            i = j
        }
        return out
    }

    /// Words with their markers attached, and omitted runs as single `~~…~~` units.
    static func units(_ p: Project, _ range: Range<Int>, _ m: Marks, _ slugs: [ClipID: String]) -> [String] {
        var units: [String] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if m.omitted.contains(i) {
                var j = i
                while j < range.upperBound, m.omitted.contains(j) { j += 1 }
                units.append(omitted(p, i..<j, m))
                i = j
                continue
            }
            var text = p.words[i].text
            if let clip = m.open[i] {
                var marker = Grammar.clipOpen(name: clip.name, offset: clip.segments.first?.inPoint.offset)
                if !clip.notes.isEmpty, let slug = slugs[clip.id] { marker += Grammar.noteReference(slug) }
                text = marker + " " + text
            }
            if let clip = m.close[i] {
                text += " " + Grammar.clipClose(offset: clip.segments.last?.outPoint.offset)
            }
            units.append(text)
            i += 1
        }
        return units
    }

    /// `~~{+40ms} words {-60ms}~~`; offsets only where set explicitly. An omission that
    /// crosses a paragraph break is fenced separately in each paragraph (the reader merges them).
    static func omitted(_ p: Project, _ range: Range<Int>, _ m: Marks) -> String {
        var parts: [String] = []
        if let o = m.omitOpenOffset[range.lowerBound] { parts.append(Grammar.offsetMarker(o)) }
        parts += p.words[range].map(\.text)
        if let o = m.omitCloseOffset[range.upperBound - 1] { parts.append(Grammar.offsetMarker(o)) }
        return Grammar.fence + parts.joined(separator: " ") + Grammar.fence
    }

    // MARK: Notes

    static func noteBlock(_ p: Project) -> [String] {
        let slugs = p.slugs()
        var entries: [(String, String)] = p.clips.filter { !$0.notes.isEmpty }.map { (slugs[$0.id]!, $0.notes) }
        entries += p.strayNotes.map { ($0.key, $0.text) }
        var out: [String] = []
        for (n, (key, text)) in entries.enumerated() {
            if n > 0 { out.append("") }
            let noteLines = text.components(separatedBy: "\n")
            out.append(Grammar.noteReference(key) + ": " + noteLines[0])
            for l in noteLines.dropFirst() { out.append(l.isEmpty ? "" : Grammar.noteIndent + l) }
        }
        return out
    }
}
