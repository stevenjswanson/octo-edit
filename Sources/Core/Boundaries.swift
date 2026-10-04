import Foundation

/// One cut point of a clip: a segment's in- or out-point. Segment 0's in-point is the
/// clip start, the last segment's out-point the clip end; the others are the edges
/// of omitted runs.
public struct BoundaryRef: Hashable, Sendable {
    public var clip: ClipID
    public var segment: Int
    public var inPoint: Bool

    public init(clip: ClipID, segment: Int, inPoint: Bool) {
        self.clip = clip
        self.segment = segment
        self.inPoint = inPoint
    }
}

public enum BoundaryRole: Sendable {
    case clipStart, clipEnd
    /// Out-point before an omission: where the cut-out material begins.
    case omissionStart
    /// In-point after an omission: where kept material resumes.
    case omissionEnd
}

extension Project {
    /// A clip's boundaries in time order: start, then each omission's start and end, then end.
    public func boundaries(of clip: Clip) -> [BoundaryRef] {
        clip.segments.indices.flatMap { k in
            [BoundaryRef(clip: clip.id, segment: k, inPoint: true), BoundaryRef(clip: clip.id, segment: k, inPoint: false)]
        }
    }

    public func role(of b: BoundaryRef) -> BoundaryRole? {
        guard let clip = clip(b.clip), clip.segments.indices.contains(b.segment) else { return nil }
        if b.inPoint { return b.segment == 0 ? .clipStart : .omissionEnd }
        return b.segment == clip.segments.count - 1 ? .clipEnd : .omissionStart
    }

    /// The word a boundary's offset is measured from: the first timed word of its
    /// segment for an in-point, the last for an out-point (as `resolvedSegments` does).
    public func anchorWord(of b: BoundaryRef) -> Int? {
        guard let clip = clip(b.clip), clip.segments.indices.contains(b.segment),
              let range = indexRange(of: clip.segments[b.segment]) else { return nil }
        return b.inPoint ? range.first { words[$0].isTimed } : range.reversed().first { words[$0].isTimed }
    }

    /// The anchor word's edge: its start for an in-point, its end for an out-point.
    public func anchorTime(of b: BoundaryRef) -> Seconds? {
        anchorWord(of: b).flatMap { b.inPoint ? words[$0].start : words[$0].end }
    }

    /// Where the cut falls in source time (before frame snapping and clamping).
    public func boundaryTime(of b: BoundaryRef) -> Seconds? {
        guard let clip = clip(b.clip), let t = anchorTime(of: b) else { return nil }
        return t + effectiveOffset(of: clip, segment: b.segment, inPoint: b.inPoint)
    }

    /// The source span a boundary may sensibly move within: from the end of the timed
    /// word before the anchor to the anchor's far edge for an in-point, mirrored for an
    /// out-point; capped at `reach` seconds into the gap.
    public func gap(around b: BoundaryRef, reach: Seconds = 0.5) -> ClosedRange<Seconds>? {
        guard let w = anchorWord(of: b), let s = words[w].start, let e = words[w].end else { return nil }
        if b.inPoint {
            let prevEnd = words[..<w].last(where: { $0.isTimed })?.end ?? 0
            let lo = max(prevEnd, s - reach)
            return min(lo, s)...s
        }
        let nextStart = words[(w + 1)...].first(where: { $0.isTimed })?.start ?? e + reach
        let hi = min(nextStart, e + reach)
        return e...max(hi, e)
    }

    /// Offset that puts the cut in the middle of the quietest stretch of the gap next
    /// to the anchor word (whole milliseconds). Nil without a usable envelope or gap.
    public func silenceOffset(of b: BoundaryRef, envelope: Envelope, reach: Seconds = 0.5) -> Seconds? {
        guard let anchor = anchorTime(of: b), let span = gap(around: b, reach: reach),
              !envelope.rms.isEmpty else { return nil }
        let lo = max(envelope.bucket(at: span.lowerBound), 0)
        let hi = min(envelope.bucket(at: span.upperBound), envelope.rms.count - 1)
        guard hi > lo else { return 0 }
        // Smooth over ~30 ms so a single quiet bucket inside a word doesn't win.
        let half = max(Int((0.015 * envelope.bucketsPerSecond).rounded()), 1)
        let smooth: [Double] = (lo...hi).map { i in
            let a = max(i - half, 0), z = min(i + half, envelope.rms.count - 1)
            return Double(envelope.rms[a...z].reduce(0, +)) / Double(z - a + 1)
        }
        let minIndex = smooth.indices.min { smooth[$0] < smooth[$1] }!
        let floor = smooth[minIndex]
        // The run of near-quietest buckets (within 3 dB) around the minimum; cut at its middle.
        let limit = max(floor * 1.41, 1e-6)
        var a = minIndex, z = minIndex
        while a > 0, smooth[a - 1] <= limit { a -= 1 }
        while z < smooth.count - 1, smooth[z + 1] <= limit { z += 1 }
        let t = envelope.time(ofBucket: lo + (a + z) / 2) + 0.5 / envelope.bucketsPerSecond
        return ((t - anchor) * 1000).rounded() / 1000
    }

    /// Offset that moves the cut to the nearest frame boundary (whole milliseconds).
    public func frameSnappedOffset(of b: BoundaryRef, fps: Double) -> Seconds? {
        guard fps > 0, let anchor = anchorTime(of: b), let t = boundaryTime(of: b) else { return nil }
        let snapped = (t * fps).rounded() / fps
        return ((snapped - anchor) * 1000).rounded() / 1000
    }
}
