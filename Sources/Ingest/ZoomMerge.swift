import Foundation
import Core
import Align

/// Combines the recognizer's timed words with the Zoom transcript.
///
/// Zoom supplies speakers and (usually cleaner) text; the recognizer supplies timing
/// and the disfluencies Zoom leaves out ("um", "uh"), which are exactly what an editor
/// wants to see and cut.
///  - matched words: Zoom's text, recognizer's time
///  - stretches both sides disagree on: Zoom's text over the recognizer's time span
///  - words only the recognizer heard: kept as heard
///  - words only Zoom has, inside a matched stretch: interpolated into the gap
///  - Zoom cues with no counterpart at all: Zoom-only paragraphs
///
/// Zoom also ends every cue with a period and starts the next with a capital, even
/// mid-sentence. At cue boundaries the recognizer's punctuation is the tie-breaker.
public enum ZoomMerge {
    public struct Output: Sendable {
        public var words: [MergedWord]
        /// Cues that matched nothing in the source audio.
        public var zoomOnly: [Cue]
        /// Zoom clock = source clock + offset.
        public var offset: Seconds
    }

    public struct MergedWord: Equatable, Sendable {
        public var word: TimedWord
        public var cue: Int?
        /// What the recognizer heard at this position, when it maps to exactly one word.
        public var heard: String?
        /// Whether the recognizer heard a sentence end after this word (nil = unknown).
        public var heardSentenceEnd: Bool?
        /// False for words only the recognizer heard (fillers Zoom left out).
        public var fromZoom: Bool

        public init(word: TimedWord, cue: Int?, heard: String? = nil, heardSentenceEnd: Bool? = nil, fromZoom: Bool = true) {
            self.word = word
            self.cue = cue
            self.heard = heard
            self.heardSentenceEnd = heardSentenceEnd
            self.fromZoom = fromZoom
        }
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’")).last else { return false }
        return ".?!".contains(c)
    }

    public static func merge(asr: [TimedWord], cues: [Cue]) -> Output {
        // Zoom tokens with their cue and an estimated Zoom-clock time.
        var zText: [String] = []
        var zCue: [Int] = []
        var zTime: [Seconds] = []
        for (ci, cue) in cues.enumerated() {
            let toks = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let total = Double(max(toks.reduce(0) { $0 + $1.count + 1 }, 1))
            var chars = 0.0
            for t in toks {
                let mid = (chars + Double(t.count) / 2) / total
                zText.append(t); zCue.append(ci); zTime.append(cue.start + (cue.end - cue.start) * mid)
                chars += Double(t.count + 1)
            }
        }
        let a = zText.map(Aligner.normalize)
        let b = asr.map { Aligner.normalize($0.text) }
        let m = Aligner.matches(a, b)

        let offsets = m.map { zTime[$0.0] - (asr[$0.1].start + asr[$0.1].end) / 2 }.sorted()
        let offset = offsets.isEmpty ? 0 : offsets[offsets.count / 2]

        var out: [MergedWord] = []
        var pz = 0, pa = 0
        func gap(_ zg: Range<Int>, _ ag: Range<Int>) {
            if zg.isEmpty {
                for j in ag {
                    out.append(MergedWord(word: asr[j], cue: nil, heard: asr[j].text,
                                          heardSentenceEnd: endsSentence(asr[j].text), fromZoom: false))
                }
            } else if ag.isEmpty {
                // Zoom words the recognizer missed: placed in the gap after the previous word.
                // Only kept when the stretch sits between matched words of the same cue.
                guard let prev = out.last, pa < asr.count, let c = zCue[safe: zg.lowerBound],
                      zCue[zg.upperBound - 1] == c, prev.cue == c else { return }
                let lo = prev.word.end, hi = max(asr[pa].start, lo)
                let d = (hi - lo) / Double(zg.count)
                for (k, z) in zg.enumerated() {
                    out.append(MergedWord(word: TimedWord(text: zText[z], start: lo + d * Double(k), end: lo + d * Double(k + 1)),
                                          cue: zCue[z]))
                }
            } else {
                let texts = zg.map { zText[$0] }
                let times = Aligner.transferTimes(texts: texts, timed: Array(asr[ag]))
                for (k, z) in zg.enumerated() {
                    let last = k == zg.count - 1
                    if let t = times[k] {
                        out.append(MergedWord(word: t, cue: zCue[z],
                                              heardSentenceEnd: last ? endsSentence(asr[ag.upperBound - 1].text) : nil))
                    }
                }
            }
        }
        for (i, j) in m {
            gap(pz..<i, pa..<j)
            var w = asr[j]
            w.text = zText[i]
            out.append(MergedWord(word: w, cue: zCue[i], heard: asr[j].text, heardSentenceEnd: endsSentence(asr[j].text)))
            pz = i + 1
            pa = j + 1
        }
        gap(pz..<zText.count, pa..<asr.count)

        // Words only the recognizer heard take the cue their time falls in, else their neighbour's.
        for k in out.indices where out[k].cue == nil {
            let zt = out[k].word.start + offset
            if let ci = cues.firstIndex(where: { zt >= $0.start && zt <= $0.end }) {
                out[k].cue = ci
            } else {
                out[k].cue = out[..<k].last(where: { $0.cue != nil })?.cue ?? out[(k + 1)...].first(where: { $0.cue != nil })?.cue
            }
        }
        repairCueBoundaries(&out)
        let used = Set(out.compactMap(\.cue))
        let zoomOnly = cues.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        return Output(words: out, zoomOnly: zoomOnly, offset: offset)
    }
}

extension ZoomMerge {
    /// Where Zoom split a sentence across cues ("we're not." / "Putting out…") and the
    /// recognizer heard no sentence end, drop Zoom's period and take the recognizer's
    /// casing for the next word (so proper nouns and "I" keep their capitals).
    /// Recognizer-only words (fillers) between the two Zoom words are skipped over.
    static func repairCueBoundaries(_ words: inout [MergedWord]) {
        var lastZoom: Int?
        for k in words.indices where words[k].fromZoom {
            defer { lastZoom = k }
            guard let p = lastZoom else { continue }
            let prev = words[p]
            guard prev.cue != words[k].cue, prev.heardSentenceEnd == false, prev.word.text.hasSuffix("."),
                  !prev.word.text.hasSuffix(".."),
                  words[(p + 1)..<k].allSatisfy({ !endsSentence($0.word.text) }) else { continue }
            words[p].word.text.removeLast()
            if let heard = words[k].heard, let h = heard.first, h.isLowercase,
               let z = words[k].word.text.first, z.isUppercase {
                words[k].word.text = String(z).lowercased() + words[k].word.text.dropFirst()
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
