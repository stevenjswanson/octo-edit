import Foundation
import Core

/// Moves recognizer word edges onto the actual speech, using the loudness envelope.
///
/// Apple's recognizer reports contiguous runs on a 60 ms grid: a word after a pause
/// "starts" right where the previous word "ended", absorbing the pause, and the
/// previous word's end is usually early. So, in two passes:
///  1. starts: if a word begins with silence, or with a short tail of the previous
///     word followed by a real pause, its start moves to the speech onset after that pause;
///  2. ends: a word ending in speech extends to the speech offset (never past the next
///     word's refined start); a word ending in silence is trimmed back to the speech.
public struct SilenceRefiner: Sendable {
    /// Extra time kept around detected speech, so soft onsets and tails are not clipped.
    public var margin: Seconds = 0.02
    /// Shortest silence treated as a pause between words (shorter gaps are stop consonants).
    public var minPause: Seconds = 0.12
    /// How far into a word the absorbed pause may begin (the previous word's spill-over).
    public var maxSpill: Seconds = 0.3
    /// How far an end may grow past the recognizer's time.
    public var maxGrow: Seconds = 0.5
    /// Shortest word duration the refiner will produce.
    public var minWord: Seconds = 0.04

    public init() {}

    /// Speech/non-speech threshold in dB: a quarter of the way from the noise floor
    /// (10th percentile) to typical speech level (90th percentile).
    public static func threshold(_ e: Envelope) -> Double {
        guard !e.rms.isEmpty else { return -60 }
        let db = (0..<e.rms.count).map(e.decibels).sorted()
        let floor = db[db.count / 10]
        let speech = db[min(db.count * 9 / 10, db.count - 1)]
        return floor + 0.25 * max(speech - floor, 6)
    }

    public func refine(_ words: [TimedWord], envelope e: Envelope) -> [TimedWord] {
        guard !words.isEmpty, !e.rms.isEmpty else { return words }
        let thr = Self.threshold(e)
        let step = 1 / e.bucketsPerSecond
        func loud(_ t: Seconds) -> Bool { e.decibels(e.bucket(at: t)) > thr }

        // Pass 1: starts.
        var starts = words.map(\.start)
        for (i, w) in words.enumerated() {
            var t = w.start
            // Skip a short spill-over of the previous word…
            while t < min(w.start + maxSpill, w.end), loud(t) { t += step }
            // …but only if a real pause follows it; otherwise the word starts where it said.
            let quietFrom = t
            while t < w.end, !loud(t) { t += step }
            let pause = t - quietFrom
            if t < w.end, quietFrom == w.start || pause >= minPause {
                starts[i] = t
            }
        }
        // Pass 2: ends.
        var out = words
        var previousEnd: Seconds = 0
        for (i, w) in words.enumerated() {
            let start = starts[i]
            let nextStart = i + 1 < words.count ? starts[i + 1] : e.duration
            var end = w.end
            if loud(max(w.end - step, start)) {
                var t = w.end
                while t + step <= min(nextStart, w.end + maxGrow), loud(t) { t += step }
                end = t
            } else {
                var t = w.end
                while t > start, !loud(t - step) { t -= step }
                if t > start { end = t }
            }
            var s = max(start - margin, previousEnd, 0)
            var en = min(end + margin, max(nextStart - margin, end))
            if en - s < minWord { en = s + minWord }
            if s > w.end { s = w.start; en = w.end }   // nothing usable found: keep the recognizer's times
            out[i].start = s
            out[i].end = en
            previousEnd = en
        }
        return out
    }
}
