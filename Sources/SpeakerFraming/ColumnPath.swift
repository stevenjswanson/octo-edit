import Foundation
import Core

/// Where a full-height 9:16 column sits over a clip, as its horizontal centre (a
/// fraction of the frame width) through source time. The column never zooms; it
/// only moves sideways:
/// - it is centred on the face of the person speaking, at that face's usual place in
///   the shot (steadier than following every head movement);
/// - it switches to a new speaker when they hold the floor (from their first word
///   until someone else's) for at least `hold`, so a quick "Yes." in a lightning round
///   gets its shot but a word talked over someone else doesn't swing the picture;
/// - a clip opens on its first such speaker, not on whoever's last word it starts in
///   (unless that word runs on for `spill`);
/// - every move is a cut, never a pan: a quick dip through black on a speaker change
///   (`Key.dips`), a hard cut with each cut in the source;
/// - when the speaker's face isn't in the shot it stays where it was in that shot,
///   or is centred when the shot just began.
public struct ColumnPath: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        /// Source time.
        public var t: Seconds
        /// Column centre from `t` on, a fraction of the frame width (already clamped).
        public var x: Double
        /// A move to a new speaker within one shot, which dips through black rather than
        /// cutting hard (a cut in the source, or the clip's start, never dips).
        public var dips = false
    }

    public let keys: [Key]
    /// A speaker change this close to a cut in the source counts as at it.
    static let cutSlack: Seconds = 0.25
    /// A cut in the source this soon before a speaker change frames the new speaker.
    static let lead: Seconds = 0.75
    /// Column width as a fraction of the frame width.
    public let width: Double

    /// `aspect` is the frame's width ÷ height. A frame already 9:16 or narrower gives a
    /// full-width column that never moves.
    public init(segments: [(start: Seconds, end: Seconds)], timeline: SpeechTimeline, labels: FaceLabels?,
                aspect: Double, hold: Seconds = 0.4, spill: Seconds = 1.5) {
        let width = min((9.0 / 16.0) / max(aspect, 0.01), 1)
        self.width = width
        func clamp(_ x: Double) -> Double { min(max(x, width / 2), 1 - width / 2) }
        var keys: [Key] = []
        for seg in segments where seg.end > seg.start {
            let turns = timeline.turns(from: seg.start, to: seg.end)
            // How long each turn has the floor: until the next speaker starts.
            func floor(_ k: Int) -> Seconds { (k + 1 < turns.count ? turns[k + 1].start : seg.end) - turns[k].start }
            // A turn already under way at the segment start: a start nudged back into the
            // previous speaker's last word shouldn't open on them for a few frames.
            // (A word starting right at the segment start, as after an omission, isn't one.)
            let spilled = turns.first.map {
                timeline.speaker(at: seg.start - 0.02) == $0.speaker && $0.end - $0.start < spill
            } ?? false
            let firstHeld = turns.indices.first { ($0 > 0 || !spilled) && floor($0) >= hold }
            let opening = firstHeld.map { turns[$0].speaker }
                ?? timeline.lastSpeaker(atOrBefore: seg.start) ?? turns.first?.speaker
            var framed = opening
            // Times where the framed speaker changes.
            var changes: [(t: Seconds, speaker: String)] = []
            for k in turns.indices where turns[k].speaker != framed && floor(k) >= hold && (k > 0 || !spilled) {
                framed = turns[k].speaker
                changes.append((turns[k].start, turns[k].speaker))
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
                    // A change at a cut in the source rides on that cut, without a dip.
                    let atCut = cuts.contains { abs($0 - changes[i].t) < Self.cutSlack }
                    events.append((changes[i].t, current, atCut))
                    i += 1
                } else {
                    // A cut just before a change goes straight to the new speaker, rather
                    // than flashing the old one for a moment.
                    let soon = i < changes.count && changes[i].t - cuts[j] < Self.lead
                    events.append((cuts[j], soon ? changes[i].speaker : current, true))
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
                // Two events at one time (a change exactly at a cut): the later decides.
                if let k = keys.last, k.t == e.t { keys.removeLast() }
                keys.append(Key(t: e.t, x: x, dips: !e.cut))
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
