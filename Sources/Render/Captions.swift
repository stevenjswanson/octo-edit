import Foundation
import Core

/// Caption sidecars for an exported clip: only the kept words, re-timed to the clip.
public enum Captions {
    public static let maxCueSeconds: Seconds = 6
    public static let maxCueCharacters = 84

    public static func webVTT(for clip: Clip, in p: Project, sourceRanges: [ResolvedSegment], clipStarts: [Seconds]) -> String {
        render(timedWords(clip, in: p, sourceRanges: sourceRanges, clipStarts: clipStarts, group: 0))
    }

    /// Captions for a supercut: each clip's kept words, re-timed to where the clip's
    /// segments landed. `segmentCounts[i]` is how many of the composition's segments
    /// belong to clip i; cues never straddle two clips.
    public static func webVTT(supercut clips: [Clip], in p: Project, segmentCounts: [Int],
                              sourceRanges: [ResolvedSegment], clipStarts: [Seconds]) -> String {
        var words: [Timed] = []
        if segmentCounts.reduce(0, +) == sourceRanges.count {
            var k = 0
            for (i, (clip, n)) in zip(clips, segmentCounts).enumerated() {
                words += timedWords(clip, in: p, sourceRanges: Array(sourceRanges[k..<k + n]),
                                    clipStarts: Array(clipStarts[k..<k + n]), group: i)
                k += n
            }
        } else {
            // A segment vanished when snapped to frames: fall back to searching all of them.
            for (i, clip) in clips.enumerated() {
                words += timedWords(clip, in: p, sourceRanges: sourceRanges, clipStarts: clipStarts, group: i)
            }
        }
        return render(words)
    }

    struct Timed { var text: String; var start: Seconds; var end: Seconds; var speaker: String?; var group: Int }

    static func timedWords(_ clip: Clip, in p: Project, sourceRanges: [ResolvedSegment], clipStarts: [Seconds],
                           group: Int) -> [Timed] {
        var words: [Timed] = []
        for w in p.keptWords(of: clip) {
            guard let s = w.start, let e = w.end,
                  let k = sourceRanges.firstIndex(where: { e > $0.start && s < $0.end }) else { continue }
            let r = sourceRanges[k]
            let a = clipStarts[k] + max(s, r.start) - r.start
            let b = clipStarts[k] + min(e, r.end) - r.start
            words.append(Timed(text: w.text, start: a, end: b, speaker: p.paragraph(w.paragraph)?.speaker, group: group))
        }
        return words
    }

    static func render(_ words: [Timed]) -> String {
        var cues: [(start: Seconds, end: Seconds, speaker: String?, group: Int, words: [String])] = []
        for w in words {
            if var last = cues.last {
                let chars = last.words.reduce(0) { $0 + $1.count + 1 } + w.text.count
                let sentenceEnded = [".", "?", "!"].contains(last.words.last?.last ?? " ")
                if w.group == last.group, w.speaker == last.speaker, w.end - last.start <= maxCueSeconds,
                   chars <= maxCueCharacters, !(sentenceEnded && w.end - last.start > maxCueSeconds / 2) {
                    last.end = w.end
                    last.words.append(w.text)
                    cues[cues.count - 1] = last
                    continue
                }
            }
            cues.append((w.start, w.end, w.speaker, w.group, [w.text]))
        }
        var out = "WEBVTT\n"
        for (n, c) in cues.enumerated() {
            out += "\n\(n + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n"
            out += (c.speaker.map { "<v \($0)>" } ?? "") + c.words.joined(separator: " ") + "\n"
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
