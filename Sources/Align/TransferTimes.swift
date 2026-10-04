import Foundation
import Core

extension Aligner {
    /// Gives each text word the timing of the timed words it aligns with.
    ///
    /// - Matched words copy their partner's times.
    /// - In an unmatched stretch with the same number of words on both sides, words pair 1:1.
    /// - Otherwise the stretch's time span is shared out by character length
    ///   (e.g. "FY27" written for spoken "fiscal twenty seven").
    /// - Text words with no timed counterpart (typed, never spoken) get nil.
    public static func transferTimes(texts: [String], timed: [TimedWord]) -> [TimedWord?] {
        let a = texts.map(normalize)
        let b = timed.map { normalize($0.text) }
        let m = matches(a, b)
        var out = [TimedWord?](repeating: nil, count: texts.count)
        func fill(_ ag: Range<Int>, _ bg: Range<Int>) {
            guard !ag.isEmpty, !bg.isEmpty else { return }
            if ag.count == bg.count {
                for (i, j) in zip(ag, bg) { out[i] = retimed(texts[i], timed[j]) }
                return
            }
            let start = timed[bg.lowerBound].start, end = timed[bg.upperBound - 1].end
            let weights = ag.map { max(texts[$0].count, 1) }
            let total = Double(weights.reduce(0, +))
            var t = start
            for (k, i) in ag.enumerated() {
                let d = (end - start) * Double(weights[k]) / total
                let conf = bg.compactMap { timed[$0].confidence }.min()
                out[i] = TimedWord(text: texts[i], start: t, end: t + d, confidence: conf)
                t += d
            }
        }
        var pa = 0, pb = 0
        for (i, j) in m {
            fill(pa..<i, pb..<j)
            out[i] = retimed(texts[i], timed[j])
            pa = i + 1
            pb = j + 1
        }
        fill(pa..<texts.count, pb..<timed.count)
        return out
    }

    private static func retimed(_ text: String, _ w: TimedWord) -> TimedWord {
        TimedWord(text: text, start: w.start, end: w.end, confidence: w.confidence)
    }
}
