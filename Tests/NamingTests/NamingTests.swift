import Testing
import Foundation
@testable import Core
@testable import Naming

struct MockNamer: ClipNamer {
    var label: String { "mock" }
    func suggest(for clip: ClipContext) async throws -> [String] {
        ["Title for " + clip.text.prefix(5), "  \"Second\"  ", "second"]
    }
}

func project() throws -> Project {
    let p = ParagraphID(1)
    let text = "Um, so the budget is flat this year. We have three options. Can you say more about the second?"
        .split(separator: " ").map(String.init)
    let words = text.enumerated().map { Word(id: WordID($0 + 1), text: $1, start: Double($0), end: Double($0) + 0.5, paragraph: p) }
    var proj = Project(source: "x.mp4", paragraphs: [Paragraph(id: p, speaker: "Steve")], words: words)
    try proj.makeClip(words: 0...7, name: "Budget")
    try proj.makeClip(words: 8...11)
    return proj
}

@Suite struct NamingTests {
    @Test func heuristicSkipsFillersAndTrims() async throws {
        let s = try await HeuristicNamer().suggest(for: ClipContext(text: "Um, so the budget is flat this year in nominal terms okay. We have three options."))
        #expect(s.first == "The budget is flat this year in nominal")
        #expect(s.count == 2)
    }

    @Test func applyUnnamedOnlyRenamesUnnamedClips() async throws {
        var p = try project()
        let out = try await Suggest.run(&p, namer: MockNamer(), apply: .unnamed)
        #expect(out.map(\.renamed) == [false, true])
        #expect(p.clips[0].name == "Budget")
        #expect(p.clips[1].name == "Title for We ha")
        #expect(p.clips[1].suggestions == ["Title for We ha", "Second"])   // trimmed, de-duplicated
    }

    @Test func applyAllAndNone() async throws {
        var p = try project()
        _ = try await Suggest.run(&p, namer: MockNamer(), apply: .all)
        #expect(p.clips[0].name == "Title for Um, s")
        var q = try project()
        _ = try await Suggest.run(&q, clips: [q.clips[1].id], namer: MockNamer(), apply: .none)
        #expect(q.clips[1].name == nil && !q.clips[1].suggestions.isEmpty && q.clips[0].suggestions.isEmpty)
    }

    @Test func contextHasKeptTextSpeakersAndOtherNames() throws {
        var p = try project()
        try p.omit(words: 1...1, in: p.clips[0].id)
        let ctx = ClipContext(clip: p.clips[0], in: p)
        #expect(ctx.text.hasPrefix("Um, the budget"))
        #expect(ctx.speakers == ["Steve"])
        #expect(ctx.otherNames.isEmpty)
    }

    @Test(.enabled(if: (try? FoundationModelsNamer.availability.get()) != nil))
    func onDeviceModelSmokeTest() async throws {
        let s = try await FoundationModelsNamer().suggest(for: ClipContext(
            text: "For FY27 the campus allocation is flat in nominal terms, which means a real cut of about three percent. We have three options."))
        print("on-device suggestions:", s)
        #expect(!s.isEmpty && s.allSatisfy { !$0.isEmpty && $0.count < 80 })
    }
}

@Suite struct CueSpeakerNamerTests {
    func sample(_ voice: String, _ turns: [VoiceSample.Turn]) -> VoiceSample {
        VoiceSample(voice: voice, seconds: 60, turns: turns)
    }

    @Test func introductionsHandoffsAndThanks() async {
        let voices = [
            sample("S1", [.init(start: 0, text: "Welcome. Kathy, do you want to start?", after: "Yeah, hello")]),
            sample("S2", [.init(start: 5, text: "Yeah, hello, my name's Kathy, I'm a third-year student",
                                before: "Kathy, do you want to start?", after: "Thanks, Kathy. Ori?")]),
            sample("S3", [.init(start: 9, text: "Hi everyone. I'm Ori and I interned at Viasat", before: "Thanks, Kathy. Ori?")]),
            sample("S4", [.init(start: 20, text: "I agree with what Kathy said")]),
        ]
        let names = await CueSpeakerNamer().names(for: voices, roster: ["Mia Minnes", "Kathy", "Ori"])
        #expect(names == ["S2": "Kathy", "S3": "Ori"])
    }

    @Test func eachNameUsedOnce() {
        let scores = ["S1": ["Kathy": 5.0], "S2": ["Kathy": 3.0, "Ori": 2.0]]
        #expect(CueSpeakerNamer.assign(scores, threshold: 2) == ["S1": "Kathy", "S2": "Ori"])
    }
}
