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
        // One line per paragraph: header, then the whole paragraph.
        #expect(out.contains("[00:00:00.0] **Steve Swanson:**\nWelcome everyone. {clip \"Welcome\" -200ms} Thanks for making time on a Wednesday. Today we have three items: the budget, the hiring plan, and the new building. {/clip}\n\n"))
    }

    @Test func longOmitStaysOnOneLineWithItsOffsets() throws {
        var p = parse(handWritten).project
        let c = p.clips[0].id
        let a = word(p, "Thanks"), b = word(p, "new")
        try p.omit(words: (a + 1)...b, in: c)
        try p.setOffset(clip: c, segment: 0, inPoint: false, 0.05)
        try p.setOffset(clip: c, segment: 1, inPoint: true, -0.07)
        let out = TranscriptWriter.write(p)
        #expect(out.contains("Thanks ~~{+50ms} for making time on a Wednesday. Today we have three items: the budget, the hiring plan, and the new {-70ms}~~ building. {/clip}"))
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.clips[0].segments == p.clips[0].segments)
    }

    @Test func omitAcrossParagraphsIsFencedInEach() throws {
        var p = parse(handWritten).project
        let c = p.clips[1].id
        let a = word(p, "options."), b = word(p, "one?")
        try p.omit(words: a...b, in: c)
        try p.setOffset(clip: c, segment: 1, inPoint: false, 0.03)
        let out = TranscriptWriter.write(p)
        #expect(out.contains("We have three ~~{+30ms} options.~~\n"))
        #expect(out.contains("\n~~Can you say more about the second one?~~\n"))
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.clips[1].segments == p.clips[1].segments)
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

    @Test func speakerFadeIsWrittenOnlyWhenChanged() {
        var p = parse(handWritten).project
        #expect(p.settings.speakerFade == ProjectSettings.defaultSpeakerFade)
        #expect(!TranscriptWriter.write(p).contains("speakerFade"))
        p.settings.speakerFade = 0.35
        let out = TranscriptWriter.write(p)
        #expect(out.contains("speakerFade: 350ms"))
        #expect(parse(out).project.settings.speakerFade == 0.35)
    }

    @Test func autoLevelsRoundTripOnTheClipMarker() throws {
        let text = handWritten.replacingOccurrences(of: "{clip \"Hiring plan\"}", with: "{clip \"Hiring plan\" levels}")
            .replacingOccurrences(of: "{clip \"Welcome\" -200ms}", with: "{clip \"Welcome\" -200ms levels}")
        let r = parse(text)
        #expect(r.issues.isEmpty)
        #expect(r.project.clips.map(\.autoLevels) == [true, false, true])
        let out = TranscriptWriter.write(r.project)
        #expect(out.contains("{clip \"Welcome\" -200ms levels}") && out.contains("{clip \"Hiring plan\" levels}[^hiring-plan]"))
        #expect(!out.contains("FY27\" -120ms levels"))
        let bad = parse("[00:00:01.0]\nHi {clip \"X\" sideways} there {/clip}\n")
        #expect(bad.issues.contains { $0.severity == .error })
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

    /// One typo must produce one error, not a cascade through the rest of the file.
    @Test func typosDoNotCascade() {
        let broken = handWritten
            .replacingOccurrences(of: "~~{+40ms} um, let me find the, uh, {-60ms}~~", with: "~~{+40ms um, let me find the, uh, {-60ms}~~ ~~in~~")
            .replacingOccurrences(of: "The second option ~~[crosstalk]~~ defers", with: "The second option ~~[crosstalk] defers")
        let errors = parse(broken, []).issues.filter { $0.severity == .error }
        #expect(errors.count == 2, "\(errors)")
        #expect(errors[0].message == "{+40ms is missing its closing }")
        #expect(errors[1].message == "~~ opened here is not closed before {/clip}")
        // Each later paragraph still parses normally.
        #expect(parse(broken, []).project.clips.map(\.name).contains("Hiring plan"))
    }

    @Test func omissionOutsideAClipLoadsAndRoundTrips() throws {
        let text = handWritten.replacingOccurrences(of: "Welcome everyone.", with: "~~{+30ms} Welcome everyone. {-20ms}~~")
        let r = parse(text)
        #expect(!r.hasErrors, "\(r.issues)")
        let p = r.project
        #expect(p.omissions.count == 1)
        #expect(p.indexRange(of: p.omissions[0]) == word(p, "Welcome")...word(p, "everyone."))
        #expect(p.omissions[0].cutOffset == 0.03 && p.omissions[0].resumeOffset == -0.02)
        let written = TranscriptWriter.write(p)
        #expect(written.contains("~~{+30ms} Welcome everyone. {-20ms}~~ {clip \"Welcome\" -200ms} Thanks"))
        #expect(parse(written).project == p)
    }

    @Test func omissionAtAClipEdgeEndsUpOutsideIt() throws {
        // A fence right after {clip} just shortens the clip; the words stay omitted.
        let text = handWritten.replacingOccurrences(of: "{clip \"Welcome\" -200ms} Thanks for", with: "{clip \"Welcome\" -200ms} ~~Thanks for~~")
        let p = parse(text).project
        let welcome = p.clips[0]
        #expect(p.indexRange(of: welcome)!.lowerBound == word(p, "making"))
        #expect(welcome.segments[0].inPoint.offset == nil)
        #expect(p.omissions.map { p.indexRange(of: $0)! } == [word(p, "Thanks")...word(p, "for")])
        #expect(TranscriptWriter.write(p).contains("~~Thanks for~~ {clip \"Welcome\"} making"))
    }

    @Test func clipMadeOverAnOmissionKeepsItAfterSaving() throws {
        var p = parse(handWritten).project
        try p.deleteClip(p.clips[0].id)
        let t = word(p, "time")
        try p.omit(words: t...t)
        #expect(p.omissions.count == 1)
        let reloaded = parse(TranscriptWriter.write(p)).project
        #expect(reloaded.omissions.map { reloaded.indexRange(of: $0)! } == [t...t])

        var q = reloaded
        try q.makeClip(words: word(q, "Thanks")...word(q, "Wednesday."), name: "Again")
        let q2 = parse(TranscriptWriter.write(q)).project
        #expect(q2.omissions.isEmpty)
        #expect(q2.omittedRanges(of: q2.clips[0]) == [t...t])
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

    @Test func splitParagraphRoundTrips() throws {
        var p = parse(handWritten).project
        let before = p.paragraphs.count
        try p.splitParagraph(atWord: word(p, "Today"))
        let out = TranscriptWriter.write(p)
        #expect(out.contains("Wednesday.\n\n[00:00:04.5] **Steve Swanson:**\nToday we have"))
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.paragraphs.count == before + 1)
        #expect(back.clips == p.clips)   // the Welcome clip now spans two paragraphs
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

@Suite struct SpeakerFormatTests {
    @Test func rosterRoundTripsInOrderOfFirstAppearance() throws {
        let text = handWritten.replacingOccurrences(of: "defaults: { pre: 120ms, post: 180ms, crossfade: 20ms }",
            with: "defaults: { pre: 120ms, post: 180ms, crossfade: 20ms }\nspeakers: [Steve Swanson, \"Guest #1\", Dean Chen]")
        let r = parse(text)
        #expect(!r.hasErrors, "\(r.issues)")
        #expect(r.project.speakers == ["Dean Chen", "Steve Swanson", "Guest #1"])
        let out = TranscriptWriter.write(r.project)
        #expect(out.contains("\nspeakers: [Dean Chen, Steve Swanson, \"Guest #1\"]\n"))
        #expect(TranscriptWriter.write(TranscriptReader.parse(out, timedWords: timedWords(for: text)).project) == out)
    }

    @Test func rosterIsDerivedFromHeadersWhenMissing() {
        let p = parse(handWritten).project
        #expect(p.speakers == ["Dean Chen", "Steve Swanson"])
        #expect(TranscriptWriter.write(p).contains("\nspeakers: [Dean Chen, Steve Swanson]\n"))
    }

    @Test func assignedSpeakerRoundTrips() throws {
        var p = parse(handWritten).project
        try p.assignSpeaker(words: word(p, "Today")...word(p, "Today"), "Mia Minnes")
        let out = TranscriptWriter.write(p)
        #expect(out.contains("Wednesday.\n\n[00:00:04.5] **Mia Minnes:**\nToday\n\n[00:00:05.0] **Steve Swanson:**\nwe have"))
        let back = TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project
        #expect(back.speakers == ["Dean Chen", "Steve Swanson", "Mia Minnes"])
        #expect(back.clips == p.clips)
    }

    @Test func framingRoundTripsQuotedAndAcceptsBare() throws {
        var p = parse(handWritten).project
        #expect(p.settings.framing == .source)
        #expect(!TranscriptWriter.write(p).contains("framing"))
        p.settings.framing = .portrait
        let out = TranscriptWriter.write(p)
        #expect(out.contains("crossfade: 20ms, framing: \"9:16\" }"))
        #expect(TranscriptReader.parse(out, timedWords: timedWords(for: handWritten)).project.settings.framing == .portrait)
        for value in ["9:16", "source", "\"source\""] {
            let text = handWritten.replacingOccurrences(of: "crossfade: 20ms }", with: "crossfade: 20ms, framing: \(value) }")
            let r = parse(text)
            #expect(!r.hasErrors, "\(value): \(r.issues)")
            #expect(r.project.settings.framing == (value == "9:16" ? .portrait : .source))
        }
        let bad = parse(handWritten.replacingOccurrences(of: "crossfade: 20ms }", with: "crossfade: 20ms, framing: 4:3 }"))
        #expect(bad.issues.contains { $0.severity == .error && $0.message.contains("framing") })
    }
}

@Suite struct EncodingTests {
    /// A start time straight from ingest and the same time read back from words.tsv
    /// (millisecond precision) must give the same paragraph header.
    @Test func headerTimestampIsStableAcrossWordsTSV() {
        #expect(Grammar.timestamp(439.79996) == "00:07:19.8")
        #expect(Grammar.timestamp(439.800) == "00:07:19.8")
        #expect(Grammar.timestamp(439.7994) == "00:07:19.7")
        #expect(Grammar.timestamp(3600.05) == "01:00:00.0")
    }

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

@Suite struct MergedClipRoundTripTests {
    /// A merged clip (gaps become omissions) saves and reloads to the same cuts.
    @Test func mergedClipSurvivesSaveAndLoad() throws {
        let p1 = ParagraphID(1), p2 = ParagraphID(2)
        let words = (0..<12).map { i in
            Word(id: WordID(i + 1), text: "w\(i)", start: Double(i), end: Double(i) + 0.8, paragraph: i < 6 ? p1 : p2)
        }
        var p = Project(source: "x.mp4", paragraphs: [Paragraph(id: p1), Paragraph(id: p2)], words: words)
        let a = try p.makeClip(words: 1...2, name: "First")
        let b = try p.makeClip(words: 4...8, name: "Second")
        try p.omit(words: 6...6, in: b)
        try p.setOffset(clip: a, segment: 0, inPoint: false, 0.3)   // First's adjusted end
        let m = try p.mergeClips([a, b])
        let ranges = p.clip(m)!.segments.map { p.indexRange(of: $0)! }

        let timed = words.map { TimedWord(text: $0.text, start: $0.start!, end: $0.end!) }
        let text = TranscriptWriter.write(p)
        let back = TranscriptReader.parse(text, timedWords: timed)
        #expect(back.issues.filter { $0.severity == .error }.isEmpty, "\(back.issues)")
        let q = back.project
        #expect(q.clips.count == 1)
        #expect(q.clips[0].segments.map { q.indexRange(of: $0)! } == ranges)
        #expect(text.contains("{clip \"First\"} w1 w2 ~~{+300ms} w3~~ w4 w5"))
        #expect(q.clips[0].segments[0].outPoint.offset == 0.3)
    }
}

@Suite struct AnnotationGuideTests {
    /// `octoedit guide` must print exactly the doc in the repo.
    @Test func embeddedGuideMatchesTheDoc() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/clip-annotation-for-ai.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        #expect(AnnotationGuide.text + "\n" == text, "run Tools/sync_guide.py after editing the doc")
    }
}
