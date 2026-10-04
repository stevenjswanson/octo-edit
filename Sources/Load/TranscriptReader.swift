import Foundation
import Core
import Align
import MarkupGrammar
import Yams

/// Parses transcript.md and re-attaches timings from words.tsv.
public enum TranscriptReader {
    public struct Result: Sendable {
        public var project: Project
        public var issues: [Issue]
        public var hasErrors: Bool { issues.contains { $0.severity == .error } }
    }

    public static func parse(_ text: String, timedWords: [TimedWord]) -> Result {
        var r = Reader(text: text)
        r.run()
        var project = r.project
        attachTimes(&project, timedWords)
        r.attachNotesAndSuggestions(&project)
        var issues = r.issues
        if !r.issues.contains(where: { $0.severity == .error }) {
            issues += project.validate().filter { $0.severity == .warning || !r.issues.contains($0) }
        }
        return Result(project: project, issues: issues)
    }

    static func attachTimes(_ p: inout Project, _ timed: [TimedWord]) {
        let zoomOnly = Set(p.paragraphs.filter(\.zoomOnly).map(\.id))
        let spoken = p.words.indices.filter { !zoomOnly.contains(p.words[$0].paragraph) }
        let times = Aligner.transferTimes(texts: spoken.map { p.words[$0].text }, timed: timed)
        var words = p.words
        for (k, i) in spoken.enumerated() {
            words[i].start = times[k]?.start
            words[i].end = times[k]?.end
            words[i].confidence = times[k]?.confidence
        }
        p.words = words
    }
}

/// Single-pass parser state.
struct Reader {
    let lines: [Substring]
    var issues: [Issue] = []
    var project = Project(source: "")
    /// Words collected while parsing, handed to `project` once at the end: assigning
    /// `Project.words` rebuilds its id index, so appending to it word by word is quadratic.
    var words: [Word] = []

    // Paragraph state
    var paragraphOpen = false
    var inZoomParagraph = false
    var nextParagraph = 1

    // Clip state
    struct PendingClip {
        var name: String?
        var openOffset: Seconds?
        var closeOffset: Seconds?
        var first: Int
        var last: Int = -1
        var line: Int
    }
    var openClip: PendingClip?
    var finishedClips: [PendingClip] = []

    // Omit state
    struct Fence {
        var first: Int          // first word index inside
        var last: Int = -1
        var openOffset: Seconds?
        var closeOffset: Seconds?
        var line: Int
    }
    var openFence: Fence?
    var fences: [Fence] = []
    var omitted = Set<Int>()

    // Notes, suggestions
    var notes: [(key: String, text: String, line: Int)] = []
    var suggestions: [String: [String]] = [:]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    mutating func error(_ msg: String, _ line: Int) { add(Issue(.error, msg, line: line)) }
    mutating func warn(_ msg: String, _ line: Int) { add(Issue(.warning, msg, line: line)) }
    mutating func add(_ issue: Issue) { if !issues.contains(issue) { issues.append(issue) } }

    mutating func run() {
        var n = 0
        if lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == Grammar.frontMatterFence {
            guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Grammar.frontMatterFence }) else {
                error("front matter is not closed with ---", 1)
                return
            }
            frontMatter(lines[1..<close].joined(separator: "\n"))
            n = close + 1
        } else {
            error("missing front matter (the file must start with ---)", 1)
        }

        var noteKey: String?
        var noteLines: [String] = []
        var noteLine = 0
        func flushNote(_ r: inout Reader) {
            if let k = noteKey {
                while noteLines.last?.isEmpty == true { noteLines.removeLast() }
                r.notes.append((k, noteLines.joined(separator: "\n"), noteLine))
            }
            noteKey = nil
            noteLines = []
        }

        while n < lines.count {
            let line = lines[n]
            let lineNo = n + 1
            n += 1
            if noteKey != nil {
                if line.hasPrefix(Grammar.noteIndent) { noteLines.append(String(line.dropFirst(Grammar.noteIndent.count))); continue }
                if line.trimmingCharacters(in: .whitespaces).isEmpty { noteLines.append(""); continue }
                flushNote(&self)
            }
            if let m = line.wholeMatch(of: Grammar.noteDefinition) {
                endParagraph()
                noteKey = String(m.1)
                noteLines = [String(m.2)]
                noteLine = lineNo
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                endParagraph()
                continue
            }
            if let m = line.wholeMatch(of: Grammar.paragraphHeader) {
                startParagraph(speaker: m.2.map(String.init), zoomStart: nil)
                continue
            }
            if let m = line.wholeMatch(of: Grammar.zoomHeader) {
                startParagraph(speaker: m.2.map(String.init), zoomStart: Grammar.parseTimestamp(m.1))
                continue
            }
            var body = line
            if inZoomParagraph {
                if body.hasPrefix(">") { body = body.dropFirst().drop { $0 == " " } }
            } else if !paragraphOpen {
                startParagraph(speaker: nil, zoomStart: nil)
            }
            tokens(Lexer.tokens(body), line: lineNo)
        }
        flushNote(&self)
        endParagraph()
        if let c = openClip { error("clip opened here is never closed with {/clip}", c.line) }
        if let f = openFence { error("omit opened here is never closed with ~~", f.line) }
        project.words = words
        buildClips()
    }

    mutating func startParagraph(speaker: String?, zoomStart: Seconds?) {
        endParagraph()
        let id = ParagraphID(nextParagraph)
        nextParagraph += 1
        project.paragraphs.append(Paragraph(id: id, speaker: speaker, zoomOnly: zoomStart != nil, zoomStart: zoomStart))
        paragraphOpen = true
        inZoomParagraph = zoomStart != nil
    }

    mutating func endParagraph() {
        // An omission never continues past its paragraph (the writer fences each
        // paragraph separately). Closing it here keeps one unbalanced ~~ from
        // flipping every later fence in the file.
        if let f = openFence {
            error("~~ opened here is not closed before the end of the paragraph", f.line)
            fences.append(f)
            openFence = nil
        }
        paragraphOpen = false
        inZoomParagraph = false
    }

    mutating func tokens(_ toks: [Token], line: Int) {
        var previous: Token?
        for (k, t) in toks.enumerated() {
            if inZoomParagraph, case .word = t {} else if inZoomParagraph {
                error("markers are not allowed in a Zoom-only (>) paragraph", line)
                previous = t
                continue
            }
            switch t {
            case .word(let w):
                let i = words.count
                words.append(Word(id: WordID(i + 1), text: w, paragraph: project.paragraphs.last!.id))
                if openFence != nil {
                    omitted.insert(i)
                    if openFence!.first < 0 { openFence!.first = i }
                    openFence!.last = i
                }
                if openClip != nil { openClip!.last = i }
            case .clipOpen(let name, let offset):
                if let c = openClip {
                    error("clip opened inside another clip (opened on line \(c.line))", line)
                } else if openFence != nil {
                    error("clip opened inside omitted text", line)
                } else {
                    openClip = PendingClip(name: name.flatMap { $0.isEmpty ? nil : $0 }, openOffset: offset,
                                           first: words.count, line: line)
                }
            case .clipClose(let offset):
                if let f = openFence {
                    error("~~ opened here is not closed before {/clip}", f.line)
                    fences.append(f)
                    openFence = nil
                }
                if var c = openClip {
                    c.closeOffset = offset
                    if c.last < c.first { error("clip has no words", c.line) } else { finishedClips.append(c) }
                    openClip = nil
                } else {
                    error("{/clip} without a matching {clip}", line)
                }
            case .fence:
                if let f = openFence {
                    fences.append(f)
                    openFence = nil
                } else {
                    openFence = Fence(first: -1, line: line)
                    if openClip == nil { error("omitted text (~~) must be inside a clip", line) }
                }
            case .offset(let o):
                if case .fence = previous, let f = openFence, f.first < 0 {
                    openFence!.openOffset = o
                } else if k + 1 < toks.count, case .fence = toks[k + 1], openFence != nil {
                    openFence!.closeOffset = o
                } else {
                    error("offset \(Grammar.offset(o)) must sit just inside a ~~ fence", line)
                }
            case .noteReference(let key):
                if case .clipOpen = previous {} else {
                    warn("note reference [^\(key)] should follow a {clip} marker", line)
                }
            case .invalid(let s):
                error("unrecognized marker \(s)", line)
            case .unclosedMarker(let s):
                error("\(s) is missing its closing }", line)
            }
            previous = t
        }
    }

    /// Turns clip spans and omitted runs into segments.
    mutating func buildClips() {
        // Merge fences into maximal omitted runs (adjacent fences with nothing kept between).
        var runOpen: [Int: Seconds] = [:]
        var runClose: [Int: Seconds] = [:]
        for f in fences where f.first >= 0 {
            if let o = f.openOffset { runOpen[f.first] = o }
            if let o = f.closeOffset { runClose[f.last] = o }
        }
        for (n, c) in finishedClips.enumerated() {
            let range = c.first...c.last
            var segments: [Segment] = []
            var runStart: Int?
            var pendingIn: Seconds? = c.openOffset
            var omitStart: Int?
            for i in range {
                if omitted.contains(i) {
                    if let a = runStart {
                        segments.append(Segment(inPoint: Boundary(word: words[a].id, offset: pendingIn),
                                                outPoint: Boundary(word: words[i - 1].id, offset: runOpen[i])))
                        runStart = nil
                    }
                    if omitStart == nil { omitStart = i }
                    if i == c.first { warn("omitted text at the very start of a clip just shortens the clip", c.line) }
                } else {
                    if runStart == nil {
                        runStart = i
                        if omitStart != nil { pendingIn = runClose[i - 1] }
                        omitStart = nil
                    }
                }
            }
            if let a = runStart {
                segments.append(Segment(inPoint: Boundary(word: words[a].id, offset: pendingIn),
                                        outPoint: Boundary(word: words[c.last].id, offset: c.closeOffset)))
            } else {
                warn("omitted text at the very end of a clip just shortens the clip", c.line)
                if !segments.isEmpty { segments[segments.count - 1].outPoint.offset = c.closeOffset }
            }
            if segments.isEmpty {
                error("clip has no kept words", c.line)
                continue
            }
            project.clips.append(Clip(id: ClipID(n + 1), name: c.name, segments: segments))
        }
    }

    mutating func frontMatter(_ yamlText: String) {
        let node: Any?
        do { node = try Yams.load(yaml: yamlText) } catch {
            self.error("front matter is not valid YAML: \(error)", 2)
            return
        }
        guard let map = node as? [String: Any] else { error("front matter must be a YAML mapping", 2); return }
        if let v = map["octoedit"] as? Int, v != PackageLayout.formatVersion {
            warn("format version \(v) is newer than this tool understands (\(PackageLayout.formatVersion))", 2)
        }
        if let s = map["source"] as? String { project.source = s } else { error("front matter needs `source:`", 2) }
        if let z = map["zoom"] as? [String: Any] {
            if let file = z["file"] as? String {
                let offset = (z["offset"] as? Double) ?? (z["offset"] as? Int).map(Double.init) ?? 0
                project.zoom = ZoomInfo(file: file, offset: offset)
            } else { error("`zoom:` needs a `file:`", 2) }
        }
        if let d = map["defaults"] as? [String: Any] {
            func ms(_ key: String) -> Seconds? {
                guard let v = d[key] else { return nil }
                if let s = v as? String, let o = Grammar.parseMilliseconds(s) { return o }
                error("defaults.\(key) must look like 120ms", 2)
                return nil
            }
            if let v = ms("pre") { project.settings.prePad = v }
            if let v = ms("post") { project.settings.postPad = v }
            if let v = ms("crossfade") { project.settings.crossfade = v }
            if let c = d["codec"] as? String {
                if let codec = Codec(rawValue: c) { project.settings.codec = codec } else { error("defaults.codec must be hevc or h264", 2) }
            }
        }
        if let s = map["suggestions"] as? [String: Any] {
            for (k, v) in s {
                if let list = v as? [String] { suggestions[k] = list } else if let one = v as? String { suggestions[k] = [one] }
            }
        }
    }

    mutating func attachNotesAndSuggestions(_ p: inout Project) {
        let slugs = p.slugs()
        var bySlug: [String: Int] = [:]
        for (i, c) in p.clips.enumerated() { bySlug[slugs[c.id]!] = i }
        for note in notes {
            if let i = bySlug[note.key] { p.clips[i].notes = note.text } else {
                p.strayNotes.append(StrayNote(key: note.key, text: note.text))
                warn("note [^\(note.key)] matches no clip; it is kept as is", note.line)
            }
        }
        for (key, list) in suggestions {
            if let i = bySlug[key] { p.clips[i].suggestions = list }
        }
    }
}
