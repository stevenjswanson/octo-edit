import Foundation
import Core

/// Where a full-height 9:16 column sits over a clip, as its horizontal centre (a
/// fraction of the frame width) through source time. The column never zooms; it
/// only moves sideways:
/// - it is centred on the face of the person speaking, at that face's usual place in
///   the shot (steadier than following every head movement);
/// - it switches to a new speaker only when their turn lasts at least `hold`, so a
///   one-word interjection doesn't swing the picture;
/// - a switch within a shot is an eased pan of `pan` seconds; at a cut in the source
///   it jumps with the cut;
/// - when the speaker's face isn't in the shot it stays where it was in that shot,
///   or is centred when the shot just began.
public struct ColumnPath: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        /// Source time.
        public var t: Seconds
        /// Column centre, a fraction of the frame width (already clamped).
        public var x: Double
        /// Jump straight to `x` (a clip start or a cut in the source) rather than pan.
        public var jump: Bool
    }

    public let keys: [Key]
    /// Column width as a fraction of the frame width.
    public let width: Double
    public let pan: Seconds

    /// `aspect` is the frame's width ÷ height. A frame already 9:16 or narrower gives a
    /// full-width column that never moves.
    public init(segments: [(start: Seconds, end: Seconds)], timeline: SpeechTimeline, labels: FaceLabels?,
                aspect: Double, hold: Seconds = 1.5, pan: Seconds = 0.6) {
        let width = min((9.0 / 16.0) / max(aspect, 0.01), 1)
        self.width = width
        self.pan = pan
        func clamp(_ x: Double) -> Double { min(max(x, width / 2), 1 - width / 2) }
        var keys: [Key] = []
        for seg in segments where seg.end > seg.start {
            var framed = timeline.lastSpeaker(atOrBefore: seg.start)
            let turns = timeline.turns(from: seg.start, to: seg.end)
            if framed == nil { framed = turns.first?.speaker }
            // Times where the framed speaker changes.
            var changes: [(t: Seconds, speaker: String)] = []
            for turn in turns where turn.speaker != framed && turn.end - turn.start >= hold {
                framed = turn.speaker
                changes.append((turn.start, turn.speaker))
            }
            // Shot starts inside the segment.
            let cuts = (labels?.shotStarts ?? []).filter { $0 > seg.start && $0 < seg.end }
            var current = timeline.lastSpeaker(atOrBefore: seg.start) ?? turns.first?.speaker
            var events: [(t: Seconds, speaker: String?, jump: Bool)] = [(seg.start, current, true)]
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
                if e.jump, let s = shot, keys.last.map({ labels?.shot(at: $0.t) != s }) ?? true { last = nil }
                let target = e.speaker.flatMap { labels?.position(of: $0, inShotAt: e.t) }
                let x = clamp(target ?? last ?? 0.5)
                if !e.jump, x == keys.last?.x { continue }
                keys.append(Key(t: e.t, x: x, jump: e.jump))
                last = x
            }
        }
        self.keys = keys
    }

    /// The column centre at source time `t`.
    public func x(at t: Seconds) -> Double {
        guard let k = keys.lastIndex(where: { $0.t <= t }) else { return keys.first?.x ?? 0.5 }
        let key = keys[k]
        if key.jump || k == 0 { return key.x }
        let from = x(at: key.t - 1e-6)
        let f = min(max((t - key.t) / pan, 0), 1)
        let eased = f * f * (3 - 2 * f)
        return from + (key.x - from) * eased
    }
}
