import Foundation
import Core
import Align

/// Replacing a project's video. The new video is transcribed, and the two
/// transcriptions say how far apart the two clocks are. When that distance is the
/// same from start to finish (the usual case: another copy of one recording), the
/// old word times are kept and shifted by it, so every cut stays exactly where it
/// was in the sound. When the clocks drift apart, the new transcription's times are
/// used instead (Load re-times the text against words.tsv), and clips whose length
/// changed are listed. These are the pure parts.
public enum ReplaceCheck {
    /// How far the new video's clock is from the old one's: new = old + `offset`.
    public struct ClockShift: Equatable, Sendable {
        public var offset: Seconds
        /// The offset among the first and the last third of the matched words.
        public var early: Seconds
        public var late: Seconds
        public var matched: Int

        /// The clocks stay together to within a frame or so, on enough evidence.
        public var steady: Bool { matched >= ClockShift.minimumMatches && abs(late - early) <= ClockShift.driftTolerance }

        public static let minimumMatches = 20
        public static let driftTolerance: Seconds = 0.04
    }

    /// Compares two transcriptions of the same speech. A recognizer times a word a
    /// little differently on every run (tenths of a second), so the offset is the
    /// median over every word the two share. nil when they share none.
    public static func clockShift(old: [TimedWord], new: [TimedWord]) -> ClockShift? {
        let pairs = Aligner.matches(old.map { Aligner.normalize($0.text) }, new.map { Aligner.normalize($0.text) })
        guard !pairs.isEmpty else { return nil }
        func median(_ slice: ArraySlice<(Int, Int)>) -> Seconds {
            let d = slice.flatMap { [new[$0.1].start - old[$0.0].start, new[$0.1].end - old[$0.0].end] }.sorted()
            return d[d.count / 2]
        }
        let third = max(pairs.count / 3, 1)
        return ClockShift(offset: median(pairs[...]), early: median(pairs.prefix(third)), late: median(pairs.suffix(third)),
                          matched: pairs.count)
    }

    /// The words give the offset to a few hundredths of a second; the two waveforms
    /// pin it down. Tries every offset within `reach` of `offset`, one waveform bucket
    /// (5 ms) apart, and returns the one where the loudness curves agree best. If they
    /// don't agree well anywhere (say, a waveform cache left over from another video),
    /// the words' offset stands.
    public static let waveformAgreement = 0.8

    public static func refined(_ offset: Seconds, old: Envelope, new: Envelope, reach: Seconds = 0.1) -> Seconds {
        guard old.bucketsPerSecond == new.bucketsPerSecond, !old.rms.isEmpty, !new.rms.isEmpty else { return offset }
        let rate = old.bucketsPerSecond
        let base = Int((offset * rate).rounded()), span = Int((reach * rate).rounded())
        var best = (score: -Double.infinity, lag: base)
        for lag in (base - span)...(base + span) {
            let lo = max(0, -lag), hi = min(old.rms.count, new.rms.count - lag)
            guard hi - lo > Int(rate) else { continue }
            var dot = 0.0, a2 = 0.0, b2 = 0.0
            for i in lo..<hi {
                let a = Double(old.rms[i]), b = Double(new.rms[i + lag])
                dot += a * b; a2 += a * a; b2 += b * b
            }
            let score = dot / max((a2 * b2).squareRoot(), 1e-12)
            if score > best.score { best = (score, lag) }
        }
        return best.score >= waveformAgreement ? Double(best.lag) / rate : offset
    }

    public static func shifted(_ words: [TimedWord], by offset: Seconds) -> [TimedWord] {
        words.map { TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
    }

    /// What to write as the package's words.tsv, and the Zoom offset that goes with it.
    public struct Retiming: Equatable, Sendable {
        public var words: [TimedWord]
        public var shift: ClockShift?
        /// True: the old times, shifted. False: the new transcription's times.
        public var keptOldTimes: Bool

        public var summary: String {
            guard let shift else { return "The two videos share no words, so word times come from the new transcription." }
            let apart = String(format: "The new video starts %.2f s %@ than the old one", abs(shift.offset), shift.offset >= 0 ? "earlier" : "later")
            if keptOldTimes { return apart + "; word timings were kept and moved by that much." }
            if shift.matched < ClockShift.minimumMatches { return apart + ", judging by only \(shift.matched) shared words, so word times come from the new transcription." }
            return String(format: "The two videos drift apart (%.2f s at the start, %.2f s at the end), so word times come from the new transcription.",
                          shift.early, shift.late)
        }
    }

    /// The envelopes are the two videos' waveforms, when both are at hand.
    public static func retiming(old: [TimedWord], new: [TimedWord], oldEnvelope: Envelope? = nil, newEnvelope: Envelope? = nil) -> Retiming {
        var shift = clockShift(old: old, new: new)
        if let s = shift, s.steady {
            if let oldEnvelope, let newEnvelope { shift?.offset = refined(s.offset, old: oldEnvelope, new: newEnvelope) }
            return Retiming(words: shifted(old, by: shift!.offset), shift: shift, keptOldTimes: true)
        }
        return Retiming(words: new, shift: shift, keptOldTimes: false)
    }

    /// A clip whose length moved by more than this needs a look: the new
    /// transcription heard a word at one of its edges differently.
    public static let tolerance: Seconds = 0.1

    public struct ClipChange: Equatable, Sendable {
        public var clip: ClipID
        public var slug: String
        public var name: String?
        /// Seconds of video the clip produced with the old video, and produces now.
        public var before: Seconds
        public var after: Seconds

        /// Part of the clip is before the new video's start or after its end.
        public var outside = false

        public var changed: Bool { outside || abs(after - before) > ReplaceCheck.tolerance }

        /// Why the clip needs a look; nil when it came through unchanged.
        public var reason: String? {
            guard changed else { return nil }
            if outside { return "is partly outside the new video, which starts later or ends sooner" }
            if after == 0 { return "has no timed words in the new video" }
            return String(format: "was %.1f s, now %.1f s: check its start and end", before, after)
        }
    }

    /// `project` (as loaded from the package) pointed at the video `ingested` was
    /// made from. Nothing else changes: text, clips, speakers and settings stay.
    /// The Zoom offset moves with the clock when the old times were kept; otherwise
    /// it is the one the new ingest measured, when it measured one.
    public static func retarget(_ project: Project, to ingested: Project, retiming: Retiming? = nil) -> Project {
        var p = project
        p.source = ingested.source
        if let retiming, retiming.keptOldTimes, let shift = retiming.shift {
            p.zoom?.offset -= shift.offset      // Zoom clock = source clock + offset
        } else if let offset = ingested.zoom?.offset {
            p.zoom?.offset = offset
        }
        return p
    }

    /// Every clip's length before and after, in document order. The two projects are
    /// the same transcript loaded against the old and the new words.tsv.
    /// `duration` is the new video's length.
    public static func clips(before: Project, after: Project, duration: Seconds? = nil) -> [ClipChange] {
        let slugs = after.slugs()
        return zip(before.clips, after.clips).map { old, new in
            let timed = after.keptWords(of: new).filter(\.isTimed)
            let outside = (timed.first?.start).map { $0 < 0 } ?? false
                || (timed.last?.end).map { e in duration.map { e > $0 } ?? false } ?? false
            return ClipChange(clip: new.id, slug: slugs[new.id] ?? "", name: new.name,
                              before: before.duration(of: old), after: after.duration(of: new), outside: outside)
        }
    }

    public static func issues(_ changes: [ClipChange]) -> [Issue] {
        changes.compactMap { c in
            c.reason.map { Issue(.warning, "clip \(c.name.map { "\"\($0)\"" } ?? c.slug) \($0)") }
        }
    }

    /// How the speakers who have a face changed when faces were found again in the
    /// new video. Names are in `speakers` order.
    public struct FaceChange: Equatable, Sendable {
        public var now: [String]
        public var gained: [String]
        public var lost: [String]

        public var summary: String {
            if now.isEmpty && lost.isEmpty { return "No faces matched to speakers." }
            var s = "Faces matched to speakers: " + (now.isEmpty ? "none" : now.map { gained.contains($0) ? "\($0) (new)" : $0 }.joined(separator: ", ")) + "."
            if !lost.isEmpty { s += " No face found for \(lost.joined(separator: ", ")) in the new video." }
            return s
        }
    }

    public static func faces(before: Set<String>, after: Set<String>, speakers: [String]) -> FaceChange {
        FaceChange(now: speakers.filter(after.contains),
                   gained: speakers.filter { after.contains($0) && !before.contains($0) },
                   lost: speakers.filter { before.contains($0) && !after.contains($0) })
    }
}

extension Project {
    /// Clips in which `speaker` has a paragraph.
    public func clips(withSpeaker speaker: String) -> [ClipID] {
        let theirs = Set(paragraphs.filter { $0.speaker == speaker }.map(\.id))
        return clips.filter { c in keptWords(of: c).contains { theirs.contains($0.paragraph) } }.map(\.id)
    }
}
