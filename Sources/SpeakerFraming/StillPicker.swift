import Foundation
import Core

/// The title card's picture for a clip: a frame of its main speaker looking their best.
///
/// Two passes, so a whole talk is never decoded again:
/// 1. **Coarse**, from cache/faces.tsv alone: frames where the clip's main speaker's face
///    is on screen, the mouth is closed, the head and camera are still, and no cut is
///    near. The best few, spread out, are the candidates.
/// 2. **Fine**, on just those exact frames: a `StillScorer` (Vision) rates face quality,
///    eye openness and mouth. Scores are cached (cache/stills.tsv), keyed by time.
///
/// The automatic pick is the best candidate in the clip's first `opening` seconds of
/// kept video if it is good enough (`goodEnough`); else the best in the rest of the
/// clip; else, of the talk's best frames of that speaker, the one nearest the clip (so
/// clips without a good frame don't all get the same picture).
public enum StillPicker {
    /// How much of the clip's start (kept video, in seconds) the automatic pick looks at first.
    public static let opening: Seconds = 10
    /// A fine score (`StillScore.total`) this high is a good card: eyes open, mouth
    /// mostly closed, a sharp face.
    public static let goodEnough = 0.3

    public struct Candidate: Equatable, Sendable {
        public enum Origin: String, Sendable, CaseIterable {
            /// The clip's first `opening` seconds; the rest of the clip; the whole talk.
            case opening, clip, talk
        }
        public var t: Seconds
        /// The speaker's face in faces.tsv's frame nearest `t`.
        public var face: FaceBox
        /// The coarse score, 0…1.
        public var coarse: Double
        public var origin: Origin
    }

    /// The speaker who says the most in the clip (by kept, timed words).
    public static func mainSpeaker(of clip: Clip, in p: Project) -> String? {
        let segments = p.resolvedSegments(of: clip)
        guard let range = p.indexRange(of: clip) else { return nil }
        var speakerOf: [ParagraphID: String] = [:]
        for para in p.paragraphs { if let s = para.speaker { speakerOf[para.id] = s } }
        var said: [String: Seconds] = [:]
        for i in range {
            let w = p.words[i]
            guard let a = w.start, let b = w.end, let s = speakerOf[w.paragraph],
                  segments.contains(where: { $0.start <= a && b <= $0.end }) else { continue }
            said[s, default: 0] += b - a
        }
        return said.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// Source-time spans covering the first `seconds` of the clip's kept video.
    public static func openingSpans(_ segments: [ResolvedSegment], seconds: Seconds = opening) -> [ClosedRange<Seconds>] {
        var left = seconds, out: [ClosedRange<Seconds>] = []
        for s in segments where left > 0 && s.end > s.start {
            let end = min(s.end, s.start + left)
            out.append(s.start...end)
            left -= end - s.start
        }
        return out
    }

    /// The clip's candidates from one place, best (coarse) first: up to 16 from its
    /// opening (0.4 s apart), 12 from the rest of it (1 s apart), or 8 from the whole
    /// talk (20 s apart).
    public static func candidates(_ origin: Candidate.Origin, for clip: Clip, in p: Project, faces: FaceTracks,
                                  labels: FaceLabels?) -> [Candidate] {
        let speaker = labels == nil ? nil : mainSpeaker(of: clip, in: p)
        let segments = p.resolvedSegments(of: clip)
        switch origin {
        case .opening:
            return best(faces, labels, speaker, within: openingSpans(segments), spacing: 0.4, limit: 16, origin: .opening)
        case .clip:
            let skip = openingSpans(segments).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let spans = trim(openingSpans(segments, seconds: .infinity), skipping: skip)
            return best(faces, labels, speaker, within: spans, spacing: 1, limit: 12, origin: .clip)
        case .talk:
            return best(faces, labels, speaker, within: nil, spacing: 20, limit: 8, origin: .talk)
        }
    }

    /// `spans` without their first `seconds`.
    static func trim(_ spans: [ClosedRange<Seconds>], skipping seconds: Seconds) -> [ClosedRange<Seconds>] {
        var left = seconds, out: [ClosedRange<Seconds>] = []
        for s in spans {
            let len = s.upperBound - s.lowerBound
            if left >= len { left -= len; continue }
            out.append((s.lowerBound + left)...s.upperBound)
            left = 0
        }
        return out
    }

    /// The best of scored candidates from one place, if it is good enough; for the talk,
    /// the good one nearest `near` (the clip's start) among those within 70% of the best.
    public static func pick(_ candidates: [Candidate], score: (Seconds) -> StillScore?, near: Seconds? = nil,
                            threshold: Double = goodEnough) -> Candidate? {
        func value(_ c: Candidate) -> Double {
            // Fine scores decide; the coarse score breaks near-ties.
            guard let s = score(c.t) else { return 0 }
            return s.total * (0.9 + 0.1 * c.coarse)
        }
        guard let top = candidates.max(by: { value($0) < value($1) }), value(top) >= threshold else { return nil }
        guard let near else { return top }
        return candidates.filter { value($0) >= 0.7 * value(top) }.min { abs($0.t - near) < abs($1.t - near) }
    }

    /// The face to judge at `t` (any time, such as a hand-picked still): the main
    /// speaker's face in the nearest sampled frame, else that frame's largest face.
    public static func face(at t: Seconds, faces: FaceTracks, labels: FaceLabels?, speaker: String?) -> FaceBox? {
        guard let i = nearestFrame(faces.frames, t) else { return nil }
        let boxes = faces.frames[i].faces
        if let speaker, let labels, let theirs = labels.face(of: speaker, at: faces.frames[i].t) {
            return boxes.min { dist($0, theirs) < dist($1, theirs) } ?? theirs
        }
        return boxes.max { $0.w * $0.h < $1.w * $1.h }
    }

    // MARK: Coarse scoring

    static func best(_ faces: FaceTracks, _ labels: FaceLabels?, _ speaker: String?, within spans: [ClosedRange<Seconds>]?,
                     spacing: Seconds, limit: Int, origin: Candidate.Origin) -> [Candidate] {
        let frames = faces.frames
        var scored: [(i: Int, box: FaceBox, s: Double)] = []
        func consider(_ i: Int) {
            guard let box = speakerFace(frames, i, labels, speaker) else { return }
            scored.append((i, box, steadiness(frames, i, box)))
        }
        if let spans {
            for span in spans {
                var i = firstFrame(frames, atOrAfter: span.lowerBound)
                while i < frames.count, frames[i].t <= span.upperBound { consider(i); i += 1 }
            }
        } else {
            frames.indices.forEach(consider)
        }
        guard !scored.isEmpty else { return [] }
        // Bigger faces make better cards: scale by face size against the largest here.
        let widest = scored.map(\.box.w).max() ?? 1
        let ranked = scored.map { ($0.i, $0.box, $0.s * (min($0.box.w / max(widest, 1e-6), 1)).squareRoot()) }
            .sorted { $0.2 > $1.2 }
        var out: [Candidate] = []
        for (i, box, s) in ranked where s > 0 {
            let t = frames[i].t
            if out.contains(where: { abs($0.t - t) < spacing }) { continue }
            out.append(Candidate(t: t, face: box, coarse: s, origin: origin))
            if out.count == limit { break }
        }
        return out
    }

    /// The speaker's face in frame `i`: with labels, the box nearest their labelled face
    /// (no face if they aren't on screen); without, the largest face.
    static func speakerFace(_ frames: [FaceFrame], _ i: Int, _ labels: FaceLabels?, _ speaker: String?) -> FaceBox? {
        let boxes = frames[i].faces
        guard !boxes.isEmpty else { return nil }
        guard let labels, let speaker else { return boxes.max { $0.w * $0.h < $1.w * $1.h } }
        guard let theirs = labels.face(of: speaker, at: frames[i].t) else { return nil }
        let near = boxes.min { dist($0, theirs) < dist($1, theirs) }!
        return dist(near, theirs) < near.w ? near : nil
    }

    /// 0…1: mouth closed, head still, camera steady and no cut within 0.3 s.
    static func steadiness(_ frames: [FaceFrame], _ i: Int, _ box: FaceBox) -> Double {
        let t = frames[i].t
        var k = i
        while k > 0, t - frames[k - 1].t <= 0.3 { k -= 1 }
        while k < frames.count, frames[k].t <= t + 0.3 {
            if k > 0, frames[k].change >= FaceLabels.cutThreshold { return 0 }
            k += 1
        }
        let mouth = exp(-(box.mouthOpen ?? 0.06) / 0.025)
        // Movement of the face to the neighbouring samples, in face widths.
        var moved = 0.0, n = 0
        for j in [i - 1, i + 1] where frames.indices.contains(j) {
            if let near = frames[j].faces.min(by: { dist($0, box) < dist($1, box) }) {
                moved += dist(near, box) / max(box.w, 1e-6); n += 1
            }
        }
        let head = exp(-(n > 0 ? moved / Double(n) : 0.1) / 0.04)
        let next = i + 1 < frames.count ? frames[i + 1].change : frames[i].change
        let camera = exp(-((i > 0 ? frames[i].change : next) + next) / 2 / 6)
        return mouth * head * camera
    }

    static func dist(_ a: FaceBox, _ b: FaceBox) -> Double { hypot(a.centerX - b.centerX, a.centerY - b.centerY) }

    static func firstFrame(_ frames: [FaceFrame], atOrAfter t: Seconds) -> Int {
        var lo = 0, hi = frames.count
        while lo < hi { let m = (lo + hi) / 2; if frames[m].t < t { lo = m + 1 } else { hi = m } }
        return lo
    }

    static func nearestFrame(_ frames: [FaceFrame], _ t: Seconds) -> Int? {
        guard !frames.isEmpty else { return nil }
        let k = firstFrame(frames, atOrAfter: t)
        if k == 0 { return 0 }
        if k == frames.count { return k - 1 }
        return frames[k].t - t < t - frames[k - 1].t ? k : k - 1
    }
}

/// Picks and remembers title-card stills for a project's clips, scoring candidate
/// frames with a `StillScorer` once each (`scores` is what cache/stills.tsv holds).
public actor TitleStills {
    /// A clip's still, as the title card will use it.
    public struct Choice: Equatable, Sendable {
        /// Source time.
        public var t: Seconds
        /// Picked automatically (no `still=` on the clip).
        public var automatic: Bool
        /// The face to centre a 9:16 crop on, if one was found.
        public var face: FaceBox?
        public var score: StillScore?
    }

    public let video: URL
    let faces: FaceTracks
    let labels: FaceLabels?
    let scorer: any StillScorer
    /// Fine scores by source time in whole milliseconds.
    public private(set) var scores: [Int: StillScore]
    /// Whether `scores` gained entries since `markSaved()`.
    public private(set) var unsaved = false

    /// `labels` saves working them out again when the caller already has them.
    public init(video: URL, faces: FaceTracks, project: Project, scorer: any StillScorer, scores: [StillScore] = [],
                labels: FaceLabels? = nil) {
        self.video = video
        self.faces = faces
        self.labels = labels ?? FaceLabels(faces: faces, project: project)
        self.scorer = scorer
        self.scores = Dictionary(scores.map { (Self.key($0.t), $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func key(_ t: Seconds) -> Int { Int((t * 1000).rounded()) }

    public func markSaved() { unsaved = false }

    /// The clip's candidates from the given places, each with its fine score (scoring
    /// any not yet scored), the fine score's best first within each place.
    public func candidates(for clip: Clip, in p: Project, from origins: [StillPicker.Candidate.Origin] = StillPicker.Candidate.Origin.allCases)
    async throws -> [(candidate: StillPicker.Candidate, score: StillScore?)] {
        var out: [(candidate: StillPicker.Candidate, score: StillScore?)] = []
        for origin in origins {
            let cs = StillPicker.candidates(origin, for: clip, in: p, faces: faces, labels: labels)
                .filter { c in !out.contains { abs($0.candidate.t - c.t) < 0.3 } }
            try await ensure(cs.map { ($0.t, $0.face) })
            out += cs.map { ($0, scores[Self.key($0.t)]) }.sorted { ($0.1?.total ?? 0) > ($1.1?.total ?? 0) }
        }
        return out
    }

    /// The clip's still: its `still=` if it has one, else the automatic pick. Nil when
    /// no frame of a face was found in the clip or the talk.
    /// The automatic pick, whether or not the clip has a `still=`.
    public func automaticChoice(for clip: Clip, in p: Project) async throws -> Choice? {
        var c = clip
        c.still = nil
        return try await choice(for: c, in: p)
    }

    public func choice(for clip: Clip, in p: Project) async throws -> Choice? {
        if let t = clip.still {
            let speaker = StillPicker.mainSpeaker(of: clip, in: p)
            let near = StillPicker.face(at: t, faces: faces, labels: labels, speaker: speaker)
            try await ensure([(t, near)])
            let s = scores[Self.key(t)]
            return Choice(t: t, automatic: false, face: s?.face ?? near, score: s)
        }
        // The opening if it has a good frame; else the rest of the clip; else the talk.
        // Places are scored only as needed.
        let start = p.resolvedSegments(of: clip).first?.start
        var seen: [StillPicker.Candidate] = []
        for origin in StillPicker.Candidate.Origin.allCases {
            let cs = try await candidates(for: clip, in: p, from: [origin]).map(\.candidate)
            seen += cs
            let found = StillPicker.pick(cs, score: { self.scores[Self.key($0)] }, near: origin == .talk ? start : nil)
                // Nothing good anywhere: the best there is.
                ?? (origin == .talk ? StillPicker.pick(seen, score: { self.scores[Self.key($0)] }, threshold: 1e-9) : nil)
            if let best = found {
                let s = scores[Self.key(best.t)]
                return Choice(t: best.t, automatic: true, face: s?.face ?? best.face, score: s)
            }
        }
        // No frame of the speaker scored at all (eyes never found, say): the opening's
        // steadiest frame, so the card still shows them.
        let fallback = seen.filter { $0.origin == .opening }.max { $0.coarse < $1.coarse } ?? seen.max { $0.coarse < $1.coarse }
        return fallback.map { Choice(t: $0.t, automatic: true, face: $0.face, score: scores[Self.key($0.t)]) }
    }

    func ensure(_ requests: [(t: Seconds, near: FaceBox?)]) async throws {
        let missing = requests.filter { scores[Self.key($0.t)] == nil }
        guard !missing.isEmpty else { return }
        let got = try await scorer.score(video: video, missing)
        for s in got { scores[Self.key(s.t)] = s }
        unsaved = true
    }
}
