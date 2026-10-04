import Testing
import Foundation
@testable import Core
@testable import Load
@testable import Save
@testable import MarkupGrammar

/// The plan's example, as a person would type it (not canonical).
let handWritten = """
---
octoedit: 1
source: ../faculty-meeting-2026-09-30-4k.mp4
zoom: { file: GMT20260930-180002_Recording.transcript.vtt, offset: 3.420 }
defaults: { pre: 120ms, post: 180ms, crossfade: 20ms }
suggestions:
  budget-update-for-fy27: ["FY27 campus allocation: flat means a 3% cut", "Why flat funding is a 3% cut"]
---

> (00:00:02.1) **Dean Chen:**
> Are we recording? Okay.

[00:00:01.4] **Steve Swanson:**
Welcome everyone. {clip "Welcome" -200ms} Thanks for making time on a
Wednesday. Today we have three items: the budget, the hiring plan,
and the new building. {/clip}

[00:23:46.3] **Steve Swanson:**
{clip "Budget update for FY27" -120ms}
For FY27 the campus allocation is
~~{+40ms} um, let me find the, uh, {-60ms}~~
flat in nominal terms, which means a real cut of about three
percent. We have three options.

[00:24:10.0] **Dean Chen:**
Can you say more about the second one?

[00:24:14.2] **Steve Swanson:**
Sure. The second option ~~[crosstalk]~~ defers two faculty searches
…so the committee should decide by November. {/clip +180ms}

[00:26:05.8] **Steve Swanson:**
{clip "Hiring plan"}[^hiring-plan]
Turning to hiring. We have authorization for two searches,
~~and I think, let me check, yes,~~
both in systems. {/clip}

[^hiring-plan]: Hold until searches are approved. Pairs with the budget clip.

"""

/// Timed words for every spoken (non-Zoom-only) word, 0.5 s apart.
func timedWords(for text: String) -> [TimedWord] {
    let p = TranscriptReader.parse(text, timedWords: []).project
    let zoomOnly = Set(p.paragraphs.filter(\.zoomOnly).map(\.id))
    return p.words.filter { !zoomOnly.contains($0.paragraph) }.enumerated().map { k, w in
        TimedWord(text: w.text, start: Double(k) * 0.5, end: Double(k) * 0.5 + 0.4, confidence: 0.9)
    }
}

func parse(_ text: String, _ timed: [TimedWord]? = nil) -> TranscriptReader.Result {
    TranscriptReader.parse(text, timedWords: timed ?? timedWords(for: text))
}

func word(_ p: Project, _ text: String, occurrence: Int = 0) -> Int {
    p.words.indices.filter { p.words[$0].text == text }[occurrence]
}

@Suite struct ParseTests {
    @Test func handWrittenExampleSemantics() throws {
        let r = parse(handWritten)
        #expect(!r.hasErrors, "\(r.issues)")
        let p = r.project
        #expect(p.source == "../faculty-meeting-2026-09-30-4k.mp4")
        #expect(p.zoom == ZoomInfo(file: "GMT20260930-180002_Recording.transcript.vtt", offset: 3.42))
        #expect(p.settings == ProjectSettings(prePad: 0.12, postPad: 0.18, crossfade: 0.02))
        #expect(p.paragraphs.first?.zoomOnly == true)
        #expect(p.paragraphs.first?.zoomStart == 2.1)
        #expect(p.words.first?.start == nil)   // zoom-only words are untimed

        #expect(p.clips.map(\.name) == ["Welcome", "Budget update for FY27", "Hiring plan"])
        let budget = p.clips[1]
        #expect(budget.segments.count == 3)   // two omits
        #expect(budget.segments[0].inPoint.offset == -0.12)
        #expect(budget.segments[0].outPoint.word == p.words[word(p, "is")].id)
        #expect(budget.segments[0].outPoint.offset == 0.04)
        #expect(budget.segments[1].inPoint.word == p.words[word(p, "flat")].id)
        #expect(budget.segments[1].inPoint.offset == -0.06)
        #expect(budget.segments[1].outPoint.offset == nil)   // [crosstalk] omit has no offsets
        #expect(budget.segments[2].outPoint.offset == 0.18)
        #expect(budget.suggestions.count == 2)
        #expect(p.clips[2].notes == "Hold until searches are approved. Pairs with the budget clip.")
        #expect(p.slugs()[p.clips[1].id] == "budget-update-for-fy27")
    }

    @Test func handWrittenNormalizesThenIsAFixedPoint() {
        let first = TranscriptWriter.write(parse(handWritten).project)
        let timed = timedWords(for: handWritten)
        let again = TranscriptWriter.write(TranscriptReader.parse(first, timedWords: timed).project)
        #expect(first == again)
        // and semantics survive normalization
        #expect(TranscriptReader.parse(first, timedWords: timed).project.clips == parse(handWritten).project.clips)
    }

    @Test func canonicalOutputShape() {
        let out = TranscriptWriter.write(parse(handWritten).project)
        #expect(out.hasPrefix("---\noctoedit: 1\nsource: ../faculty-meeting-2026-09-30-4k.mp4\n"))
        #expect(out.contains("> (00:00:02.1) **Dean Chen:**\n> Are we recording? Okay."))
        #expect(out.contains("{clip \"Budget update for FY27\" -120ms} For FY27"))
        #expect(out.contains("~~{+40ms} um, let me find the, uh, {-60ms}~~"))
        #expect(out.contains("November. {/clip +180ms}"))
        #expect(out.contains("{clip \"Hiring plan\"}[^hiring-plan] Turning"))
        #expect(out.hasSuffix("[^hiring-plan]: Hold until searches are approved. Pairs with the budget clip.\n"))
        let body = out.components(separatedBy: "\n---\n")[1]   // front matter lines are not wrapped
        for line in body.split(separator: "\n") where !line.hasPrefix("[^") {
            #expect(line.count <= Grammar.wrapWidth, "line too long: \(line)")
        }
    }

    @Test func longOmitIsChunkedOneFencePerLine() throws {
        var p = parse(handWritten).project
        let c = p.clips[0].id
        let a = word(p, "Thanks"), b = word(p, "new")
        try p.omit(words: (a + 1)...b, in: c)
        try p.setOffset(clip: c, segment: 0, inPoint: false, 0.05)
        try p.setOffset(clip: c, segment: 1, inPoint: true, -0.07)
        let out = TranscriptWriter.write(p)
        let lines = out.split(separator: "\n")
        let first = lines.firstIndex { $0.hasPrefix("~~{+50ms}") }!
        let last = lines.firstIndex { $0.hasSuffix("{-70ms}~~") }!
        let chunks = lines[first...last]
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.hasPrefix("~~") && $0.hasSuffix("~~") && $0.count <= Grammar.wrapWidth })
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.clips[0].segments == p.clips[0].segments)
    }
}

@Suite struct HandEditTests {
    @Test func deletedWordDropsWithoutShiftingTimes() {
        let timed = timedWords(for: handWritten)
        let edited = handWritten.replacingOccurrences(of: "allocation is\n", with: "is\n")
        let r = parse(edited, timed)
        #expect(!r.hasErrors)
        let p = r.project
        let original = parse(handWritten, timed).project
        #expect(p.words[word(p, "flat")].start == original.words[word(original, "flat")].start)
        #expect(p.words[word(p, "campus")].start == original.words[word(original, "campus")].start)
    }

    @Test func typedWordIsUntimedAndCorrectionKeepsTime() {
        let timed = timedWords(for: handWritten)
        let edited = handWritten
            .replacingOccurrences(of: "Today we have", with: "Today we really have")
            .replacingOccurrences(of: "For FY27 the", with: "For fiscal-year-2027 the")
        let p = parse(edited, timed).project
        let original = parse(handWritten, timed).project
        #expect(p.words[word(p, "really")].start == nil)
        #expect(p.words[word(p, "fiscal-year-2027")].start == original.words[word(original, "FY27")].start)
    }

    @Test func movedMarkerMovesTheBoundary() {
        let edited = handWritten.replacingOccurrences(of: "Welcome everyone. {clip \"Welcome\" -200ms} Thanks",
                                                      with: "{clip \"Welcome\" -200ms} Welcome everyone. Thanks")
        let p = parse(edited).project
        #expect(p.clips[0].segments[0].inPoint.word == p.words[word(p, "Welcome")].id)
    }

    @Test func structuralErrorsCarryLineNumbers() {
        let unclosed = handWritten.replacingOccurrences(of: "and the new building. {/clip}", with: "and the new building.")
        let r1 = parse(unclosed, [])
        #expect(r1.issues.contains { $0.severity == .error && $0.line != nil })

        let outside = handWritten.replacingOccurrences(of: "Can you say more", with: "Can ~~you~~ say more")
            .replacingOccurrences(of: "Sure. The second option ~~[crosstalk]~~", with: "{/clip} Sure. The second option")
        let r2 = parse(outside, [])
        #expect(r2.issues.contains { $0.severity == .error })

        let inZoom = handWritten.replacingOccurrences(of: "> Are we recording? Okay.", with: "> Are we {clip} recording? Okay.")
        let r3 = parse(inZoom, [])
        let e = r3.issues.first { $0.message.contains("Zoom-only") }
        #expect(e?.line == 11)

        let badMarker = handWritten.replacingOccurrences(of: "{/clip +180ms}", with: "{/clip +18Oms}")
        #expect(parse(badMarker, []).issues.contains { $0.message.contains("unrecognized marker") })
    }

    @Test func strayNoteIsKeptAndWarned() {
        let edited = handWritten + "\n[^no-such-clip]: Remember to ask Dean.\n"
        let r = parse(edited)
        #expect(!r.hasErrors)
        #expect(r.project.strayNotes == [StrayNote(key: "no-such-clip", text: "Remember to ask Dean.")])
        #expect(r.issues.contains { $0.severity == .warning && $0.message.contains("no-such-clip") })
        #expect(TranscriptWriter.write(r.project).contains("[^no-such-clip]: Remember to ask Dean."))
    }

    @Test func renamingAClipCarriesItsNoteAndSuggestions() throws {
        var p = parse(handWritten).project
        try p.setName(clip: p.clips[2].id, "Hiring update")
        try p.setSuggestions(clip: p.clips[2].id, ["Two searches"])
        let out = TranscriptWriter.write(p)
        #expect(out.contains("[^hiring-update]: Hold until"))
        #expect(out.contains("hiring-update: [\"Two searches\"]"))
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.clips[2].notes.hasPrefix("Hold until"))
        #expect(back.clips[2].suggestions == ["Two searches"])
    }

    @Test func multiLineNotesRoundTrip() throws {
        var p = parse(handWritten).project
        try p.setNotes(clip: p.clips[0].id, "First line.\n\nSecond paragraph.")
        let out = TranscriptWriter.write(p)
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.clips[0].notes == "First line.\n\nSecond paragraph.")
        #expect(TranscriptWriter.write(back) == out)
    }

    @Test func quotesInNamesAndYAMLSpecials() throws {
        var p = parse(handWritten).project
        try p.setName(clip: p.clips[0].id, "The \"welcome\" bit")
        try p.setSuggestions(clip: p.clips[0].id, ["a: b, [c]"])
        p.source = "/Volumes/Media/My Meeting: 30 Sept.mp4"
        let out = TranscriptWriter.write(p)
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten))
        #expect(!back.hasErrors, "\(back.issues)")
        #expect(back.project.clips[0].name == "The \"welcome\" bit")
        #expect(back.project.clips[0].suggestions == ["a: b, [c]"])
        #expect(back.project.source == p.source)
    }
}

@Suite struct EncodingTests {
    @Test func wordsTSVRoundTrip() throws {
        let w = [TimedWord(text: "Hello,", start: 0.12, end: 0.5, confidence: 0.93),
                 TimedWord(text: "world.", start: 0.5, end: 1.25, confidence: nil)]
        let back = try WordsTSV.decode(WordsTSV.encode(w))
        #expect(back == w)
    }

    @Test func waveformRoundTrip() {
        let e = Envelope(bucketsPerSecond: 200, rms: [0, 0.5, 1e-4, 0.25])
        #expect(WaveformFile.decode(WaveformFile.encode(e)) == e)
    }

    @Test func timesAndOffsets() {
        #expect(Grammar.timestamp(5026.37) == "01:23:46.3")
        #expect(Grammar.offset(-0.12) == "-120ms")
        #expect(Grammar.offset(0.04) == "+40ms")
        #expect(Grammar.parseMilliseconds("+40ms") == 0.04)
        #expect(Grammar.parseMilliseconds("40") == nil)
    }

    @Test func packageSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octo-\(UUID().uuidString)")
        let pkg = dir.appendingPathComponent("meeting.octoedit")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = parse(handWritten).project
        p.source = dir.appendingPathComponent("meeting.mp4").path
        let timed = timedWords(for: handWritten)
        try PackageWriter.save(p, to: pkg, options: .init(words: timed, envelope: Envelope(bucketsPerSecond: 200, rms: [0.1, 0.2])))
        let r = try PackageReader.load(pkg)
        #expect(r.project.source == "../meeting.mp4")
        #expect(r.sourceURL.path == dir.appendingPathComponent("meeting.mp4").standardizedFileURL.path)
        #expect(r.envelope?.rms == [0.1, 0.2])
        #expect(r.project.clips == p.clips)
        // An ordinary save leaves words.tsv alone.
        let before = try String(contentsOf: pkg.appendingPathComponent("words.tsv"), encoding: .utf8)
        var q = r.project
        q.words[0].text = "Changed"
        try PackageWriter.save(q, to: pkg)
        #expect(try String(contentsOf: pkg.appendingPathComponent("words.tsv"), encoding: .utf8) == before)
        #expect(FileManager.default.fileExists(atPath: pkg.appendingPathComponent(".gitignore").path))
    }
}
