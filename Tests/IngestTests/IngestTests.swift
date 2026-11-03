import Testing
import Foundation
@testable import Core
@testable import Ingest
import Waveform
import Transcribe

@Suite struct VTTTests {
    @Test func zoomStyleAndVoiceTags() {
        let vtt = """
        WEBVTT

        1
        00:00:00.800 --> 00:00:03.151
        Dean Chen: Are we recording? Okay.

        2
        00:01:03.851 --> 00:01:08.137
        <v Steve Swanson>Welcome everyone.</v>

        3
        01:02.000 --> 01:04.500 align:start
        No speaker on this one
        and it wraps.
        """
        let cues = ZoomVTT.parse(vtt)
        #expect(cues.count == 3)
        #expect(cues[0].speaker == "Dean Chen")
        #expect(cues[0].text == "Are we recording? Okay.")
        #expect(cues[1].speaker == "Steve Swanson")
        #expect(cues[1].text == "Welcome everyone.")
        #expect(abs(cues[1].start - 63.851) < 1e-9)
        #expect(cues[2].speaker == nil)
        #expect(cues[2].text == "No speaker on this one and it wraps.")
        #expect(cues[2].start == 62)
    }
}

@Suite struct RefinerTests {
    /// 200 buckets/s: silence, speech 1.00–1.50, silence, speech 2.00–2.60, silence.
    func envelope() -> Envelope {
        var rms = [Float](repeating: 0.0001, count: 800)
        for i in 200..<300 { rms[i] = 0.2 }
        for i in 400..<520 { rms[i] = 0.2 }
        return Envelope(bucketsPerSecond: 200, rms: rms)
    }

    @Test func absorbedPauseIsTrimmedAndEarlyEndExtended() {
        let words = [TimedWord(text: "one", start: 0.90, end: 1.40),    // end 0.1 s early
                     TimedWord(text: "two", start: 1.40, end: 2.58)]    // start absorbs the pause
        let r = SilenceRefiner().refine(words, envelope: envelope())
        #expect(abs(r[0].start - 0.98) < 0.011)
        #expect(abs(r[0].end - 1.52) < 0.011)
        #expect(abs(r[1].start - 1.98) < 0.011)
        #expect(abs(r[1].end - 2.62) < 0.011)
    }

    @Test func neverCrossesNeighbours() {
        let words = [TimedWord(text: "a", start: 1.0, end: 1.2), TimedWord(text: "b", start: 1.2, end: 1.5)]
        let r = SilenceRefiner().refine(words, envelope: envelope())
        #expect(r[0].end <= r[1].start)
    }
}

@Suite struct MergeTests {
    @Test func fillersKeptZoomTextPreferredZoomOnlyDetected() {
        let cues = [
            Cue(index: 1, start: 0.5, end: 2.0, speaker: "Dean", text: "Are we recording?"),
            Cue(index: 2, start: 13.0, end: 15.65, speaker: "Steve", text: "For FY27 the allocation is flat."),
        ]
        // Source starts 10 s into the Zoom recording.
        let asr = [("For", 3.0), ("whistle", 3.3), ("27,", 3.6), ("the", 3.9), ("allocation", 4.2),
                   ("is,", 4.6), ("um,", 4.9), ("flat.", 5.4)]
            .map { TimedWord(text: $0.0, start: $0.1, end: $0.1 + 0.25) }
        let out = ZoomMerge.merge(asr: asr, cues: cues)
        #expect(out.words.map(\.word.text) == ["For", "FY27", "the", "allocation", "is", "um,", "flat."])
        #expect(out.words[1].word.start == 3.3 && out.words[1].word.end == 3.85)   // span of "whistle 27,"
        #expect(out.words.allSatisfy { $0.cue == 1 })
        #expect(out.zoomOnly.map(\.index) == [1])
        #expect(abs(out.offset - 10) < 1.0)
    }
}

@Suite struct ParagraphTests {
    struct NoTranscriber: Transcriber {
        func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] { [] }
    }
    struct NoAnalyzer: EnvelopeAnalyzer {
        func envelope(of media: URL) async throws -> Envelope { Envelope(bucketsPerSecond: 200, rms: []) }
    }

    /// One speaker for everything (as in real Zoom exports): paragraphs follow real
    /// sentence ends at cue boundaries, and Zoom's mid-sentence cue periods are repaired.
    @Test func singleSpeakerCuesRepairedAndSplitAtSentenceEnds() {
        let cueTexts = ["What percent of your code do you read?",
                        "I read most of it to make sure that we're not.",     // Zoom cut mid-sentence
                        "Putting out risky code. And I review it daily.",
                        "What skill matters more today?"]
        let heard = ["What percent of your code do you read?",
                     "I read most of it to make sure that we're not, um,",
                     "putting out risky code. And I review it daily.",
                     "What skill matters more today?"]
        var cues: [Cue] = []
        var asr: [TimedWord] = []
        var t = 0.0
        for (n, (z, h)) in zip(cueTexts, heard).enumerated() {
            let start = t
            for w in h.split(separator: " ") { asr.append(TimedWord(text: String(w), start: t, end: t + 0.3)); t += 0.3 }
            cues.append(Cue(index: n + 1, start: start, end: t, speaker: "Host", text: z))
        }
        let merged = ZoomMerge.merge(asr: asr, cues: cues)
        var p = Project(source: "x.mp4")
        Ingest(transcriber: NoTranscriber(), analyzer: NoAnalyzer()).build(&p, merged: merged, cues: cues)
        let paras = p.paragraphs.map { id in p.words.filter { $0.paragraph == id.id }.map(\.text).joined(separator: " ") }
        #expect(paras == ["What percent of your code do you read?",
                          "I read most of it to make sure that we're not um, putting out risky code. And I review it daily.",
                          "What skill matters more today?"])
    }
}

// MARK: - Integration on the generated fixture

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/generated")
let haveFixture = FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("meeting-1080.mp4").path)

struct TruthLine { let start: Double, end: Double, speaker: String, text: String }

func truth() throws -> [TruthLine] {
    try String(contentsOf: fixtures.appendingPathComponent("meeting.truth.tsv"), encoding: .utf8)
        .split(separator: "\n").dropFirst().map { l in
            let f = l.split(separator: "\t").map(String.init)
            return TruthLine(start: Double(f[0])!, end: Double(f[1])!, speaker: f[2], text: f[3])
        }.filter { $0.start >= 0 }
}

/// Mean absolute error of line-edge times: first word start vs line start, last word end vs line end.
func edgeError(_ words: [(start: Double, end: Double)], _ lines: [TruthLine]) -> (start: Double, end: Double) {
    var es = 0.0, ee = 0.0
    for l in lines {
        let inLine = words.filter { ($0.start + $0.end) / 2 >= l.start - 0.3 && ($0.start + $0.end) / 2 <= l.end + 0.3 }
        es += abs((inLine.first?.start ?? l.start) - l.start)
        ee += abs((inLine.last?.end ?? l.end) - l.end)
    }
    return (es / Double(lines.count), ee / Double(lines.count))
}

@Suite(.serialized, .enabled(if: haveFixture)) struct IngestIntegrationTests {
    @Test func realRecognizerOnFixture() async throws {
        let video = fixtures.appendingPathComponent("meeting-1080.mp4")
        let zoom = fixtures.appendingPathComponent("meeting.zoom.vtt")
        let lines = try truth()

        let envelope = try await AssetEnvelopeAnalyzer().envelope(of: video)
        let raw = try await AppleSpeechTranscriber().transcribe(audio: video) { _ in }
        let refined = SilenceRefiner().refine(raw, envelope: envelope)
        let before = edgeError(raw.map { ($0.start, $0.end) }, lines)
        let after = edgeError(refined.map { ($0.start, $0.end) }, lines)
        print(String(format: "edge error, raw:     start %.3f s  end %.3f s", before.start, before.end))
        print(String(format: "edge error, refined: start %.3f s  end %.3f s", after.start, after.end))
        #expect(after.start < 0.08)
        #expect(after.end < 0.08)
        #expect(after.start < before.start)

        let result = try await Ingest(transcriber: AppleSpeechTranscriber(), analyzer: AssetEnvelopeAnalyzer())
            .run(video: video, zoom: zoom, settings: ProjectSettings())
        let p = result.project
        #expect(abs(p.zoom!.offset - 3.42) < 0.2, "offset \(p.zoom!.offset)")
        #expect(p.paragraphs.first?.zoomOnly == true)
        #expect(p.paragraphs.first?.speaker == "Dean Chen")
        // Speaker accuracy: each timed word's speaker vs the truth line it falls in.
        var right = 0, total = 0
        for w in p.words where w.isTimed {
            let mid = (w.start! + w.end!) / 2
            guard let line = lines.first(where: { mid >= $0.start - 0.2 && mid <= $0.end + 0.2 }) else { continue }
            total += 1
            if p.paragraph(w.paragraph)?.speaker == line.speaker { right += 1 }
        }
        print("speaker accuracy \(right)/\(total); paragraphs \(p.paragraphs.count); words \(p.words.count)")
        #expect(Double(right) / Double(total) > 0.95)
        // Zoom's text wins where the recognizer misheard; fillers survive.
        let text = p.words.map(\.text).joined(separator: " ")
        #expect(text.contains("Turning to hiring."))
        #expect(text.contains("um,"))
    }
}

@Suite(.serialized, .enabled(if: haveFixture)) struct IngestCancellationTests {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var cancelledAt: Date?
    }

    /// Cancelling mid-transcription stops the run promptly with CancellationError.
    @Test func cancelDuringTranscription() async throws {
        let video = fixtures.appendingPathComponent("meeting-1080.mp4")
        let clock = Clock()
        let task = Task {
            try await Ingest(transcriber: AppleSpeechTranscriber(), analyzer: AssetEnvelopeAnalyzer())
                .run(video: video, zoom: nil, settings: ProjectSettings()) { stage, fraction in
                    guard stage == .transcribing, fraction > 0 else { return }
                    clock.lock.lock(); defer { clock.lock.unlock() }
                    if clock.cancelledAt == nil { clock.cancelledAt = Date() }
                }
        }
        // Cancel as soon as transcription reports progress.
        while clock.lock.withLock({ clock.cancelledAt }) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        let result = await task.result
        let stopped = Date()
        guard case .failure(let error) = result else { Issue.record("ingest finished despite cancellation"); return }
        #expect(error is CancellationError)
        let lag = stopped.timeIntervalSince(clock.lock.withLock { clock.cancelledAt! })
        #expect(lag < 2, "took \(lag) s to stop")
    }
}

@Suite struct SpeakerIDTests {
    struct FixedNamer: SpeakerNamer {
        var label: String { "fixed" }
        var result: [String: String]
        func names(for voices: [VoiceSample], roster: [String]) async -> [String: String] { result }
    }

    /// Ten words, one a second, all in one paragraph credited to the room account.
    func project() -> Project {
        let p = ParagraphID(1)
        let words = (0..<10).map { Word(id: WordID($0 + 1), text: "w\($0)", start: Double($0), end: Double($0) + 0.8, paragraph: p) }
        return Project(source: "v.mp4", paragraphs: [Paragraph(id: p, speaker: "Room")], words: words, speakers: ["Kathy", "Ori"])
    }

    let turns = [VoiceTurn(start: 0, end: 3.9, voice: "S1"), VoiceTurn(start: 4, end: 4.9, voice: "S2"),
                 VoiceTurn(start: 5, end: 9.9, voice: "S1"), VoiceTurn(start: 30, end: 31, voice: "S3")]

    @Test func namesUnmatchedVoicesSpeakerNAndReportsShortTurns() async {
        var p = project()
        let r = await SpeakerID.identify(&p, turns: turns, namer: FixedNamer(result: ["S1": "Kathy", "S2": "Mallory"]))
        // Mallory isn't on the roster, so S2 becomes Speaker 1; S3 has no words.
        #expect(p.paragraphs.map(\.speaker) == ["Kathy", "Speaker 1", "Kathy"])
        #expect(r.matched == ["S1"])
        #expect(r.shortTurns.map(\.text) == ["w4"])
        #expect(r.changedWords == 10)
        #expect(p.speakers.prefix(2) == ["Kathy", "Speaker 1"])
    }

    @Test func rerunKeepsMarkersOnTheirWords() async throws {
        var p = project()
        let c = try p.makeClip(words: 3...8, name: "A clip")
        try p.omit(words: 5...6, in: c)
        let clips = p.clips, omissions = p.omissions
        _ = await SpeakerID.identify(&p, turns: turns, namer: FixedNamer(result: ["S1": "Kathy", "S2": "Ori"]))
        let again = turns.map { VoiceTurn(start: $0.start, end: $0.end, voice: $0.voice == "S1" ? "S2" : "S1") }
        _ = await SpeakerID.identify(&p, turns: again, namer: FixedNamer(result: ["S1": "Ori", "S2": "Kathy"]))
        #expect(p.clips == clips)
        #expect(p.omissions == omissions)
        #expect(p.validate().isEmpty)
    }

    @Test func aLongUnvoicedStretchBetweenTurnsIsFine() async {
        // Twenty words; only the first two and the last two fall in a voice turn.
        let pid = ParagraphID(1)
        let words = (0..<20).map { Word(id: WordID($0 + 1), text: "w\($0)", start: Double($0), end: Double($0) + 0.8, paragraph: pid) }
        var p = Project(source: "v.mp4", paragraphs: [Paragraph(id: pid, speaker: "Room")], words: words)
        let turns = [VoiceTurn(start: 0, end: 1.9, voice: "S1"), VoiceTurn(start: 18, end: 19.9, voice: "S2")]
        let r = await SpeakerID.identify(&p, turns: turns, namer: FixedNamer(result: [:]))
        #expect(r.names == ["S1": "Speaker 1", "S2": "Speaker 2"])
        #expect(SpeakerID.samples(p, p.voices(from: turns))[0].turns[0].after == "w3 w4 w5 w6 w7 w8 w9 w10")
    }

    @Test func zoomNamesWinWhenZoomCreditsSeveralPeople() async {
        var p = project()
        p.zoom = ZoomInfo(file: "z.vtt", offset: 10)
        let cues = [Cue(index: 1, start: 10, end: 14, speaker: "Kathy Lee", text: ""),
                    Cue(index: 2, start: 14, end: 15, speaker: "Ori Z", text: ""),
                    Cue(index: 3, start: 15, end: 20, speaker: "Kathy Lee", text: "")]
        _ = await SpeakerID.identify(&p, turns: turns, cues: cues, namer: FixedNamer(result: [:]))
        #expect(p.paragraphs.map(\.speaker) == ["Kathy Lee", "Ori Z", "Kathy Lee"])
    }
}
