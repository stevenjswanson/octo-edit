import Foundation
import Core

/// Caption sidecars for an exported clip: only the kept words, re-timed to the clip.
public enum Captions {
    public static let maxCueSeconds: Seconds = 6
    public static let maxCueCharacters = 84

    public static func webVTT(for clip: Clip, in p: Project, sourceRanges: [ResolvedSegment], clipStarts: [Seconds]) -> String {
        struct Timed { var text: String; var start: Seconds; var end: Seconds; var speaker: String? }
        var words: [Timed] = []
        for w in p.keptWords(of: clip) {
            guard let s = w.start, let e = w.end,
                  let k = sourceRanges.firstIndex(where: { e > $0.start && s < $0.end }) else { continue }
            let r = sourceRanges[k]
            let a = clipStarts[k] + max(s, r.start) - r.start
            let b = clipStarts[k] + min(e, r.end) - r.start
            words.append(Timed(text: w.text, start: a, end: b, speaker: p.paragraph(w.paragraph)?.speaker))
        }
        var cues: [(Seconds, Seconds, String?, [String])] = []
        for w in words {
            if var last = cues.last {
                let chars = last.3.reduce(0) { $0 + $1.count + 1 } + w.text.count
                let sentenceEnded = [".", "?", "!"].contains(last.3.last?.last ?? " ")
                if w.speaker == last.2, w.end - last.0 <= maxCueSeconds, chars <= maxCueCharacters,
                   !(sentenceEnded && w.end - last.0 > maxCueSeconds / 2) {
                    last.1 = w.end
                    last.3.append(w.text)
                    cues[cues.count - 1] = last
                    continue
                }
            }
            cues.append((w.start, w.end, w.speaker, [w.text]))
        }
        var out = "WEBVTT\n"
        for (n, c) in cues.enumerated() {
            out += "\n\(n + 1)\n\(stamp(c.0)) --> \(stamp(c.1))\n"
            out += (c.2.map { "<v \($0)>" } ?? "") + c.3.joined(separator: " ") + "\n"
        }
        return out
    }

    static func stamp(_ t: Seconds) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// `1:48.0`
    public static func clock(_ t: Seconds) -> String {
        let tenths = Int((t * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
