import Foundation

/// Token-sequence alignment shared by Ingest (Zoom cues ↔ recognizer words)
/// and Load (transcript text ↔ words.tsv).
///
/// Strategy: match common prefix/suffix, anchor on tokens that occur exactly once in
/// both regions (patience diff), recurse between anchors, and fall back to
/// Needleman–Wunsch in regions small enough to afford it.
public enum Aligner {
    /// Largest region (cells) solved with Needleman–Wunsch; bigger unanchored regions stay unmatched.
    public static let maxDPCells = 4_000_000

    /// Normalizes a word for comparison: case- and punctuation-insensitive,
    /// small number words folded to digits.
    public static func normalize(_ word: String) -> String {
        let lowered = word.lowercased()
        let kept = String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return numberWords[kept] ?? kept
    }

    /// Strictly increasing (aIndex, bIndex) pairs of equal tokens.
    public static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        out.reserveCapacity(min(a.count, b.count))
        region(a, b, 0, a.count, 0, b.count, &out)
        return out
    }

    /// For each `a` token, the `b` tokens whose timing it should take:
    /// matched tokens map 1:1; tokens in an unmatched gap share the gap's `b` tokens
    /// proportionally; `a` tokens in a gap with no `b` tokens map to nil.
    public static func correspondence(aCount: Int, bCount: Int, matches: [(Int, Int)]) -> [Range<Int>?] {
        var result = [Range<Int>?](repeating: nil, count: aCount)
        var pa = 0, pb = 0
        func fill(_ aGap: Range<Int>, _ bGap: Range<Int>) {
            let na = aGap.count, nb = bGap.count
            guard na > 0, nb > 0 else { return }
            for k in 0..<na {
                let lo = k * nb / na
                let hi = max((k + 1) * nb / na, lo + 1)
                result[aGap.lowerBound + k] = (bGap.lowerBound + lo)..<(bGap.lowerBound + min(hi, nb))
            }
        }
        for (i, j) in matches {
            fill(pa..<i, pb..<j)
            result[i] = j..<(j + 1)
            pa = i + 1
            pb = j + 1
        }
        fill(pa..<aCount, pb..<bCount)
        return result
    }

    // MARK: - Implementation

    private static func region(_ a: [String], _ b: [String],
                               _ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int,
                               _ out: inout [(Int, Int)]) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
            out.append((aLo, bLo)); aLo += 1; bLo += 1
        }
        var suffix: [(Int, Int)] = []
        while aHi > aLo, bHi > bLo, a[aHi - 1] == b[bHi - 1] {
            suffix.append((aHi - 1, bHi - 1)); aHi -= 1; bHi -= 1
        }
        if aLo < aHi, bLo < bHi {
            let anchors = uniqueAnchors(a, b, aLo, aHi, bLo, bHi)
            if anchors.isEmpty {
                if (aHi - aLo) * (bHi - bLo) <= maxDPCells {
                    needlemanWunsch(a, b, aLo, aHi, bLo, bHi, &out)
                }
            } else {
                var pa = aLo, pb = bLo
                for (i, j) in anchors {
                    region(a, b, pa, i, pb, j, &out)
                    out.append((i, j))
                    pa = i + 1
                    pb = j + 1
                }
                region(a, b, pa, aHi, pb, bHi, &out)
            }
        }
        out.append(contentsOf: suffix.reversed())
    }

    /// Tokens unique in both ranges, reduced to a longest increasing chain.
    private static func uniqueAnchors(_ a: [String], _ b: [String],
                                      _ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> [(Int, Int)] {
        var countA: [String: (Int, Int)] = [:]
        for i in aLo..<aHi { countA[a[i], default: (0, i)].0 += 1 }
        var countB: [String: (Int, Int)] = [:]
        for j in bLo..<bHi { countB[b[j], default: (0, j)].0 += 1 }
        var pairs: [(Int, Int)] = []
        for (tok, ca) in countA where ca.0 == 1 {
            if let cb = countB[tok], cb.0 == 1 { pairs.append((ca.1, cb.1)) }
        }
        pairs.sort { $0.0 < $1.0 }
        return longestIncreasing(pairs)
    }

    /// Longest subsequence with increasing second component (patience sorting).
    private static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        guard !pairs.isEmpty else { return [] }
        var tails: [Int] = []          // index into pairs of the tail of each pile
        var prev = [Int](repeating: -1, count: pairs.count)
        for (k, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].1 < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[k] = tails[lo - 1] }
            if lo == tails.count { tails.append(k) } else { tails[lo] = k }
        }
        var chain: [(Int, Int)] = []
        var k = tails.last!
        while k >= 0 { chain.append(pairs[k]); k = prev[k] }
        return chain.reversed()
    }

    /// Global alignment with substitutions; only exact matches are reported.
    /// Substitutions keep the alignment locally coherent so common words in a
    /// mismatched stretch don't get paired up across it.
    private static func needlemanWunsch(_ a: [String], _ b: [String],
                                        _ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int,
                                        _ out: inout [(Int, Int)]) {
        let n = aHi - aLo, m = bHi - bLo
        let match: Int32 = 3, mismatch: Int32 = -1, gap: Int32 = -1
        let w = m + 1
        var score = [Int32](repeating: 0, count: (n + 1) * w)
        var move = [UInt8](repeating: 0, count: (n + 1) * w)   // 0 diag, 1 up (a gap), 2 left (b gap)
        for i in 1...n { score[i * w] = Int32(i) * gap; move[i * w] = 1 }
        for j in 1...m { score[j] = Int32(j) * gap; move[j] = 2 }
        for i in 1...n {
            let ai = a[aLo + i - 1]
            for j in 1...m {
                let diag = score[(i - 1) * w + j - 1] + (ai == b[bLo + j - 1] ? match : mismatch)
                let up = score[(i - 1) * w + j] + gap
                let left = score[i * w + j - 1] + gap
                if diag >= up, diag >= left { score[i * w + j] = diag; move[i * w + j] = 0 }
                else if up >= left { score[i * w + j] = up; move[i * w + j] = 1 }
                else { score[i * w + j] = left; move[i * w + j] = 2 }
            }
        }
        var i = n, j = m
        var found: [(Int, Int)] = []
        while i > 0, j > 0 {
            switch move[i * w + j] {
            case 0:
                if a[aLo + i - 1] == b[bLo + j - 1] { found.append((aLo + i - 1, bLo + j - 1)) }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        out.append(contentsOf: found.reversed())
    }

    private static let numberWords: [String: String] = {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        var map: [String: String] = [:]
        for (n, w) in ones.enumerated() { map[w] = String(n) }
        for (n, w) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
            map[w] = String((n + 2) * 10)
        }
        let ordinals = ["first": "1st", "second": "2nd", "third": "3rd", "fourth": "4th", "fifth": "5th"]
        map.merge(ordinals) { $1 }
        return map
    }()
}
