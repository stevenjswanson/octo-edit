import Foundation
import Core

/// Where a full-height 9:16 column sits over a clip, as its horizontal centre (a
/// fraction of the frame width) through source time. The column never zooms; it
/// only moves sideways:
/// - it is centred on the face of the person speaking, at that face's usual place in
///   the shot (steadier than following every head movement);
/// - it switches to a new speaker only when their turn lasts at least `hold`, so a
///   one-word interjection doesn't swing the picture; for the same reason a clip opens
///   on its first speaker with such a turn, not on whoever's last word it starts in;
/// - every move is an instant cut, never a pan: on a speaker change, and with each
///   cut in the source;
/// - when the speaker's face isn't in the shot it stays where it was in that shot,
///   or is centred when the shot just began.
public struct ColumnPath: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        /// Source time.
        public var t: Seconds
        /// Column centre from `t` on, a fraction of the frame width (already clamped).
        public var x: Double
    }

    public let keys: [Key]
    /// Column width as a fraction of the frame width.
    public let width: Double

    /// `aspect` is the frame's width ÷ height. A frame already 9:16 or narrower gives a
    /// full-width column that never moves.
    public init(segments: [(start: Seconds, end: Seconds)], timeline: SpeechTimeline, labels: FaceLabels?,
                aspect: Double, hold: Seconds = 1.5) {
        let width = min((9.0 / 16.0) / max(aspect, 0.01), 1)
        self.width = width
        func clamp(_ x: Double) -> Double { min(max(x, width / 2), 1 - width / 2) }
        var keys: [Key] = []
        for seg in segments where seg.end > seg.start {
            let turns = timeline.turns(from: seg.start, to: seg.end)
            // Start on the first speaker who talks for at least `hold` in the segment, so
            // a start nudged back into the previous speaker's last word or a pause
            // doesn't open on them for a few frames.
            let opening = turns.first { $0.end - $0.start >= hold }?.speaker
                ?? timeline.lastSpeaker(atOrBefore: seg.start) ?? turns.first?.speaker
            var framed = opening
            // Times where the framed speaker changes.
            var changes: [(t: Seconds, speaker: String)] = []
            for turn in turns where turn.speaker != framed && turn.end - turn.start >= hold {
                framed = turn.speaker
                changes.append((turn.start, turn.speaker))
            }
            // Shot starts inside the segment.
            let cuts = (labels?.shotStarts ?? []).filter { $0 > seg.start && $0 < seg.end }
            var current = opening
            // `cut`: a clip start or a cut in the source, where the old position no longer applies.
            var events: [(t: Seconds, speaker: String?, cut: Bool)] = [(seg.start, current, true)]
            var i = 0, j = 0
            while i < changes.count || j < cuts.count {
                if j >= cuts.count || (i < changes.count && changes[i].t < cuts[j]) {
                    current = changes[i].speaker
                    events.append((changes[i].t, current, false))
                    i += 1
                } else {
                    events.append((cuts[j], current, true))
                    j += 1
                }
            }
            var last: Double?
            for e in events {
                let shot = labels?.shot(at: e.t)
                if e.cut, let s = shot, keys.last.map({ labels?.shot(at: $0.t) != s }) ?? true { last = nil }
                let target = e.speaker.flatMap { labels?.position(of: $0, inShotAt: e.t) }
                let x = clamp(target ?? last ?? 0.5)
                if e.t != seg.start, x == keys.last?.x { continue }
                keys.append(Key(t: e.t, x: x))
                last = x
            }
        }
        self.keys = keys
    }

    /// The column centre at source time `t`.
    public func x(at t: Seconds) -> Double {
        guard let k = keys.lastIndex(where: { $0.t <= t }) else { return keys.first?.x ?? 0.5 }
        return keys[k].x
    }
}
