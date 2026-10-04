import Testing
@testable import Align

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
