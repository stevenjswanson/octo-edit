import Testing
@testable import Align
import Core

func toks(_ s: String) -> [String] { s.split(separator: " ").map { Aligner.normalize(String($0)) } }

@Suite struct AlignTests {
    @Test func normalization() {
        #expect(Aligner.normalize("Budget,") == "budget")
        #expect(Aligner.normalize("Three") == "3")
        #expect(Aligner.normalize("second") == "2nd")
        #expect(Aligner.normalize("Let's") == "lets")
    }

    @Test func identicalSequencesMatchCompletely() {
        let a = toks("the quick brown fox jumps over the lazy dog")
        let m = Aligner.matches(a, a)
        #expect(m.count == a.count)
        #expect(m.allSatisfy { $0.0 == $0.1 })
    }

    @Test func insertionsDeletionsSubstitutions() {
        let a = toks("for FY27 the campus allocation is let me find the flat in nominal terms")
        let b = toks("for whistle 27 the campus allocation is um let me find the uh flat nominal terms")
        let m = Aligner.matches(a, b)
        let pairs = m.map { "\(a[$0.0])=\(b[$0.1])" }
        #expect(pairs.contains("campus=campus"))
        #expect(pairs.contains("flat=flat"))
        #expect(m.allSatisfy { a[$0.0] == b[$0.1] })
        // strictly increasing
        #expect(zip(m, m.dropFirst()).allSatisfy { $0.0 < $1.0 && $0.1 < $1.1 })
        #expect(m.count == 12)   // for the campus allocation is let me find the flat nominal terms
    }

    @Test func correspondenceDistributesGaps() {
        // a: x [FY27] y      b: x [fiscal twenty seven] y
        let c = Aligner.correspondence(aCount: 3, bCount: 5, matches: [(0, 0), (2, 4)])
        #expect(c[0] == 0..<1)
        #expect(c[1] == 1..<4)
        #expect(c[2] == 4..<5)
        // a-only gap → untimed
        let d = Aligner.correspondence(aCount: 3, bCount: 2, matches: [(0, 0), (2, 1)])
        #expect(d[1] == nil)
        // more a than b in a gap: every a token still gets at least one b token
        let e = Aligner.correspondence(aCount: 4, bCount: 3, matches: [(0, 0), (3, 2)])
        #expect(e[1] == 1..<2 && e[2] == 1..<2)
    }

    @Test func longSequencesAreFast() {
        // 20k tokens with sparse edits must align quickly via anchors.
        var vocab: [String] = []
        for i in 0..<4000 { vocab.append("tok\(i)") }
        var gen = SystemRandomNumberGenerator()
        let a = (0..<20_000).map { _ in vocab.randomElement(using: &gen)! }
        var b = a
        for k in stride(from: 100, to: 19_900, by: 97) { b[k] = "zzz" }
        b.remove(at: 5000); b.insert("extra", at: 12_000)
        let clock = ContinuousClock()
        var m: [(Int, Int)] = []
        let t = clock.measure { m = Aligner.matches(a, b) }
        #expect(m.count > 19_500)
        #expect(t < .seconds(5))
    }
}

@Suite struct RetextTests {
    /// "for fy 27 the campus is um flat" with times 0,1,2,…; clip over all of it with "um" omitted.
    func project() throws -> (Project, ClipID) {
        let texts = ["for", "fy", "27", "the", "campus", "is", "um", "flat"]
        let words = texts.enumerated().map { i, t in
            Word(id: WordID(i + 1), text: t, start: Double(i), end: Double(i) + 0.8, paragraph: ParagraphID(1))
        }
        var p = Project(source: "x", paragraphs: [Paragraph(id: ParagraphID(1))], words: words)
        let id = try p.makeClip(words: 0...7)
        try p.omit(words: 6...6, in: id)
        try p.setOffset(clip: id, segment: 0, inPoint: true, -0.2)
        return (p, id)
    }

    @Test func correctionsKeepIdsTimesAndClips() throws {
        var (p, id) = try project()
        try p.replaceText(ofParagraph: ParagraphID(1), with: ["For", "FY27", "the", "campus", "is", "um", "flat."])
        #expect(p.words.map(\.text) == ["For", "FY27", "the", "campus", "is", "um", "flat."])
        #expect(p.words[0].id == WordID(1) && p.words[0].start == 0)          // matched: same word
        #expect(p.words[1].start == 1 && p.words[1].end == 2.8)               // FY27 spans "fy 27"
        #expect(p.words.last!.id == WordID(8))                                 // "flat." still "flat"
        let c = p.clip(id)!
        #expect(c.segments.map { p.indexRange(of: $0)! } == [0...4, 6...6])   // omission of "um" kept
        #expect(c.segments[0].inPoint.offset == -0.2)                          // anchor survived
    }

    @Test func deletingAnEdgeWordMovesTheEdge() throws {
        var (p, id) = try project()
        try p.replaceText(ofParagraph: ParagraphID(1), with: ["fy", "27", "the", "campus", "is", "um"])
        let c = p.clip(id)!
        #expect(p.indexRange(of: c) == 0...4)        // start moved to "fy"; end before the gone "flat"
        #expect(c.segments.count == 1)                // the "um" omission no longer sits inside
        #expect(c.segments[0].inPoint.offset == nil)  // its anchor word was removed
    }

    @Test func deletingAnOmittedRunRemovesTheOmission() throws {
        var (p, id) = try project()
        try p.replaceText(ofParagraph: ParagraphID(1), with: ["for", "fy", "27", "the", "campus", "is", "flat"])
        #expect(p.clip(id)!.segments.count == 1)
        #expect(p.indexRange(of: p.clip(id)!) == 0...6)
    }

    @Test func emptyParagraphIsRefused() throws {
        var (p, _) = try project()
        #expect(throws: EditError.emptyParagraph) { try p.replaceText(ofParagraph: ParagraphID(1), with: []) }
    }
}
