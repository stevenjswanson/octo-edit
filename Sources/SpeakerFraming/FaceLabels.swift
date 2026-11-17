import Foundation
import Core

/// Which face belongs to which speaker, worked out from the transcript: within each
/// shot, faces are linked into tracks, and a track is labelled with the paragraph
/// speaker whose words its mouth moves with (lip-motion voting). Because the labels
/// come from paragraph headers, correcting a header corrects the framing.
public struct FaceLabels: Sendable {
    public struct Sample: Equatable, Sendable {
        public var t: Seconds
        public var box: FaceBox
    }

    public struct Track: Equatable, Sendable {
        public var shot: Int
        public var samples: [Sample]
        /// The speaker this face belongs to, when the evidence is clear.
        public var speaker: String?
        /// Frames this track won for its speaker ÷ frames it was on screen while they spoke.
        public var score: Double
    }

    /// Mean luma change on the scanner's thumbnail that counts as a cut.
    public static let cutThreshold = 18.0

    public let tracks: [Track]
    /// Start time of each shot, ascending.
    public let shotStarts: [Seconds]
    public let aspect: Double

    public init(faces: FaceTracks, project: Project) {
        aspect = faces.height > 0 ? Double(faces.width) / Double(faces.height) : 16.0 / 9.0
        let (tracks, shotStarts) = Self.link(faces.frames)
        self.shotStarts = shotStarts
        self.tracks = Self.label(tracks, frames: faces.frames, voices: SpeechTimeline(project))
    }

    /// The shot playing at `t`.
    public func shot(at t: Seconds) -> Int {
        var lo = 0, hi = shotStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if shotStarts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return max(lo - 1, 0)
    }

    /// The speaker's face at `t` (within half a second), in the shot playing then.
    public func face(of speaker: String, at t: Seconds) -> FaceBox? {
        let s = shot(at: t)
        var best: (d: Double, box: FaceBox)?
        for tr in tracks where tr.shot == s && tr.speaker == speaker {
            guard let first = tr.samples.first, let last = tr.samples.last, first.t - 0.5 <= t, t <= last.t + 0.5 else { continue }
            for smp in tr.samples where abs(smp.t - t) <= 0.5 && (best == nil || abs(smp.t - t) < best!.d) {
                best = (abs(smp.t - t), smp.box)
            }
        }
        return best?.box
    }

    /// Every face on screen at `t`: in each track of the shot playing then, the sample
    /// nearest `t` (within 0.3 s), with the track's speaker when known.
    public func faces(at t: Seconds) -> [(box: FaceBox, speaker: String?)] {
        let s = shot(at: t)
        return tracks.compactMap { tr in
            guard tr.shot == s, let first = tr.samples.first, let last = tr.samples.last,
                  first.t - 0.3 <= t, t <= last.t + 0.3,
                  let near = tr.samples.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(near.t - t) <= 0.3 else { return nil }
            return (near.box, tr.speaker)
        }
    }

    /// Where the speaker's face sits in the shot playing at `t`: the median centre of
    /// their face over the shot. Steadier than any one sample.
    public func position(of speaker: String, inShotAt t: Seconds) -> Double? {
        let s = shot(at: t)
        let xs = tracks.filter { $0.shot == s && $0.speaker == speaker }.flatMap { $0.samples.map(\.box.centerX) }.sorted()
        return xs.isEmpty ? nil : xs[xs.count / 2]
    }

    /// A good frame of each speaker's face for a thumbnail: the largest face from
    /// their most confident long track.
    public func portraits() -> [String: Sample] {
        var out: [String: (score: Double, sample: Sample)] = [:]
        for tr in tracks {
            guard let name = tr.speaker, let biggest = tr.samples.max(by: { $0.box.h < $1.box.h }) else { continue }
            let score = tr.score * Double(min(tr.samples.count, 100)) * biggest.box.h
            if out[name] == nil || score > out[name]!.score { out[name] = (score, biggest) }
        }
        return out.mapValues(\.sample)
    }

    // MARK: Tracks

    /// Links each shot's faces into tracks: a face continues the nearest track whose
    /// last face was within 0.6 s and 0.6 face-heights of it.
    static func link(_ frames: [FaceFrame]) -> ([Track], [Seconds]) {
        var tracks: [Track] = []
        var shotStarts: [Seconds] = []
        var active: [(track: Int, t: Seconds, box: FaceBox)] = []
        for (k, f) in frames.enumerated() {
            if k == 0 || f.change > cutThreshold {
                shotStarts.append(f.t)
                active = []
            }
            let shot = shotStarts.count - 1
            var used = Set<Int>()
            var next: [(Int, Seconds, FaceBox)] = []
            for b in f.faces.sorted(by: { $0.h > $1.h }) {
                var best: (k: Int, d: Double)?
                for (j, a) in active.enumerated() where !used.contains(j) && f.t - a.t <= 0.6 {
                    let d = hypot(b.centerX - a.box.centerX, b.centerY - a.box.centerY) / max(b.h, a.box.h)
                    if d < 0.6, best == nil || d < best!.d { best = (j, d) }
                }
                let id: Int
                if let best {
                    used.insert(best.k)
                    id = active[best.k].track
                } else {
                    id = tracks.count
                    tracks.append(Track(shot: shot, samples: [], speaker: nil, score: 0))
                }
                tracks[id].samples.append(Sample(t: f.t, box: b))
                next.append((id, f.t, b))
            }
            active = next + active.enumerated().filter { !used.contains($0.offset) && f.t - $0.element.t <= 0.6 }.map(\.element)
        }
        return (tracks, shotStarts)
    }

    // MARK: Labels

    /// Mouth activity (mean change of the mouth's open ÷ width per sample, over ±0.5 s)
    /// below which a face isn't talking. A still face jitters at 0.01–0.02; a speaker
    /// talking measures 0.04–0.10 (Roy Guo's talk: median 0.059, 10th percentile 0.027).
    static let talking = 0.025

    /// The name with the most votes (ties to the first name alphabetically).
    static func top(_ votes: [String: Int]) -> (String, Int)? {
        votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }).map { ($0.key, $0.value) }
    }

    /// Per sampled frame with someone speaking, the face whose mouth moves most (by a
    /// 1.3× margin over the next, and at least `talking`) votes for that speaker. Votes
    /// are pooled by seat: the camera keeps coming back to the same framing and people
    /// stay in their chairs, so tracks at the same place and size in any shot are one
    /// person — unless a track's own votes clearly name someone else. A seat takes the
    /// speaker it won most often, if it won at least a second's worth and at least half
    /// the frames it was on screen while that speaker talked; in one shot, two seats
    /// can't both be the same speaker (the one with more votes keeps it).
    static func label(_ tracks: [Track], frames: [FaceFrame], voices: SpeechTimeline) -> [Track] {
        var tracks = tracks
        let dt = frames.count > 1 ? max((frames.last!.t - frames.first!.t) / Double(frames.count - 1), 0.01) : 0.1
        // Mouth activity per sample: mean change of the mouth's aspect ratio over ±0.5 s.
        let window = max(Int((0.5 / dt).rounded()), 1)
        var activity: [Seconds: [(track: Int, act: Double)]] = [:]
        for (id, tr) in tracks.enumerated() {
            let ratio = tr.samples.map { s -> Double? in
                guard let o = s.box.mouthOpen, let w = s.box.mouthWidth, w > 1e-3 else { return nil }
                return o / w
            }
            for (k, s) in tr.samples.enumerated() {
                let win = ratio[max(0, k - window)...min(ratio.count - 1, k + window)].compactMap { $0 }
                let diffs = zip(win, win.dropFirst()).map { abs($1 - $0) }
                activity[s.t, default: []].append((id, diffs.isEmpty ? 0 : diffs.reduce(0, +) / Double(diffs.count)))
            }
        }
        var won: [Int: [String: Int]] = [:], heard: [Int: [String: Int]] = [:]
        for f in frames {
            guard let speaker = voices.speaker(at: f.t), let faces = activity[f.t], !faces.isEmpty else { continue }
            for a in faces { heard[a.track, default: [:]][speaker, default: 0] += 1 }
            let ranked = faces.sorted { $0.act > $1.act }
            // Only a moving mouth votes: a listener alone on screen while someone
            // off-camera talks must not win their words.
            if ranked[0].act >= Self.talking, ranked.count == 1 || ranked[0].act > 1.3 * ranked[1].act {
                won[ranked[0].track, default: [:]][speaker, default: 0] += 1
            }
        }
        let seatOf = seats(tracks)
        var seatWon: [Int: [String: Int]] = [:], seatHeard: [Int: [String: Int]] = [:]
        for id in tracks.indices {
            for (n, c) in won[id] ?? [:] { seatWon[seatOf[id], default: [:]][n, default: 0] += c }
            for (n, c) in heard[id] ?? [:] { seatHeard[seatOf[id], default: [:]][n, default: 0] += c }
        }
        let minimum = Int((1.0 / dt).rounded())
        // Frames each track's seat won for its speaker: how much evidence there is.
        var votes = [Int](repeating: 0, count: tracks.count)
        for id in tracks.indices {
            let seat = seatOf[id]
            guard var (name, count) = seatWon[seat].flatMap(Self.top) else { continue }
            var score = Double(count) / Double(max(seatHeard[seat]?[name] ?? 1, 1))
            // A seat is only a place on screen, and different shots can frame different
            // people there (a questioner at the mic centred just like the speaker at the
            // podium). A track whose own mouth clearly moved for someone else is them.
            if let (own, n) = won[id].flatMap(Self.top), own != name, n > won[id]?[name] ?? 0, 2 * n >= minimum {
                (name, count) = (own, n)
                score = Double(n) / Double(max(heard[id]?[own] ?? 1, 1))
            }
            tracks[id].score = score
            votes[id] = count
            if count >= minimum, score >= 0.5 { tracks[id].speaker = name }
        }
        // One face per speaker per shot.
        let byShot = Dictionary(grouping: tracks.indices, by: { tracks[$0].shot })
        for (_, ids) in byShot {
            for (_, same) in Dictionary(grouping: ids.filter { tracks[$0].speaker != nil }, by: { tracks[$0].speaker! }) {
                // Overlapping in time: keep the one with more evidence (a stray detection
                // can win a few frames by a wide ratio); one person's track split in two is fine.
                func strength(_ k: Int) -> (Int, Double, Int) { (votes[k], tracks[k].score, -k) }
                for a in same {
                    for b in same where b != a && tracks[b].speaker != nil && overlap(tracks[a], tracks[b])
                    && strength(b) < strength(a) {
                        tracks[b].speaker = nil
                    }
                }
            }
        }
        return tracks
    }

    /// Whether two tracks are on screen at the same time.
    static func overlap(_ a: Track, _ b: Track) -> Bool {
        guard let a0 = a.samples.first?.t, let a1 = a.samples.last?.t, let b0 = b.samples.first?.t, let b1 = b.samples.last?.t
        else { return false }
        return a0 <= b1 && b0 <= a1
    }

    /// Track → seat: tracks whose typical face is in the same place at the same size
    /// (within 0.04 of the frame width, 0.05 of its height, and 25% in size).
    static func seats(_ tracks: [Track]) -> [Int] {
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let where_ = tracks.map { t in (x: median(t.samples.map(\.box.centerX)), y: median(t.samples.map(\.box.centerY)),
                                       h: median(t.samples.map(\.box.h))) }
        var seats: [(x: Double, y: Double, h: Double, n: Int)] = []
        var out: [Int] = []
        // Longest tracks first, so a seat is anchored on a steady face.
        var seatOf = [Int](repeating: 0, count: tracks.count)
        for id in tracks.indices.sorted(by: { tracks[$0].samples.count > tracks[$1].samples.count }) {
            let w = where_[id]
            if let k = seats.firstIndex(where: { abs($0.x - w.x) < 0.04 && abs($0.y - w.y) < 0.05 && abs($0.h - w.h) < 0.25 * max($0.h, w.h) }) {
                seatOf[id] = k
                seats[k].n += 1
            } else {
                seatOf[id] = seats.count
                seats.append((w.x, w.y, w.h, 1))
            }
        }
        out = seatOf
        return out
    }
}

/// Who is speaking when, from the transcript's timed words and paragraph speakers.
public struct SpeechTimeline: Sendable {
    /// Timed words, by start: (start, end, speaker).
    let spans: [(start: Seconds, end: Seconds, speaker: String)]

    public init(_ p: Project) {
        let speakerOf = Dictionary(uniqueKeysWithValues: p.paragraphs.filter { !$0.zoomOnly }.map { ($0.id, $0.speaker) })
        spans = p.words.compactMap { w in
            guard let s = w.start, let e = w.end, let name = speakerOf[w.paragraph] ?? nil else { return nil }
            return (s, e, name)
        }.sorted { $0.start < $1.start }
    }

    /// The speaker of the word being said at `t`, if any.
    public func speaker(at t: Seconds) -> String? {
        guard let k = lastStart(atOrBefore: t), spans[k].end >= t else { return nil }
        return spans[k].speaker
    }

    /// The speaker of the last word started at or before `t`.
    public func lastSpeaker(atOrBefore t: Seconds) -> String? {
        lastStart(atOrBefore: t).map { spans[$0].speaker }
    }

    /// Runs of one speaker between `from` and `to`, split where the speaker changes.
    public func turns(from: Seconds, to: Seconds) -> [(start: Seconds, end: Seconds, speaker: String)] {
        var out: [(start: Seconds, end: Seconds, speaker: String)] = []
        for s in spans where s.end > from && s.start < to {
            if let last = out.last, last.speaker == s.speaker {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append((max(s.start, from), s.end, s.speaker))
            }
        }
        if !out.isEmpty { out[out.count - 1].end = min(out[out.count - 1].end, to) }
        return out
    }

    private func lastStart(atOrBefore t: Seconds) -> Int? {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}
