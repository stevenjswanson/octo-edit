import Foundation
import Core

/// Splits paragraphs at voice changes and names the voices. Used by ingest
/// (`init --speakers`) and on a loaded project (`octoedit speakers`, Identify
/// Speakers…), where it resets every speaker name.
///
/// Name sources, best first: Zoom's names when Zoom credits more than one person,
/// then the namer (roster names only), then `Speaker N`.
public enum SpeakerID {
    public struct ShortTurn: Equatable, Sendable {
        public var start: Seconds
        public var seconds: Seconds
        public var speaker: String?
        public var text: String
    }

    public struct Report: Sendable {
        /// Voice label → the name it was given, for every voice found.
        public var names: [String: String]
        /// Voices named by Zoom or the namer (the rest are `Speaker N`).
        public var matched: Set<String>
        /// Speaking time per voice.
        public var seconds: [String: Seconds]
        /// Timed words whose speaker changed.
        public var changedWords: Int
        public var paragraphsBefore: Int
        public var paragraphsAfter: Int
        /// One-voice runs shorter than `shortTurn`, worth checking by ear.
        public var shortTurns: [ShortTurn]
    }

    public static let shortTurn: Seconds = 1.0

    public static func identify(_ p: inout Project, turns: [VoiceTurn], cues: [Cue] = [], namer: any SpeakerNamer) async -> Report {
        let voiceOfWord = p.voices(from: turns)
        let samples = samples(p, voiceOfWord)
        var names = zoomNames(p, voiceOfWord, cues: cues)
        for name in Set(names.values).sorted() { p.addSpeaker(name) }
        var matched = Set(names.keys)
        if names.isEmpty, !p.speakers.isEmpty {
            let found = await namer.names(for: samples, roster: p.speakers)
            for (voice, name) in found where p.speakers.contains(name) {
                names[voice] = name
                matched.insert(voice)
            }
        }
        // Unmatched voices become Speaker 1, 2, … in order of first appearance.
        var n = 0
        for s in samples where names[s.voice] == nil {
            repeat { n += 1 } while p.speakers.contains("Speaker \(n)") || names.values.contains("Speaker \(n)")
            names[s.voice] = "Speaker \(n)"
        }

        let before = p
        p.applyVoices(voiceOfWord, names: names)
        let speakerOf = { (q: Project) in Dictionary(uniqueKeysWithValues: q.paragraphs.map { ($0.id, $0.speaker) }) }
        let old = speakerOf(before), new = speakerOf(p)
        var changed = 0
        for (a, b) in zip(before.words, p.words) where a.isTimed && old[a.paragraph] ?? nil != new[b.paragraph] ?? nil {
            changed += 1
        }
        return Report(names: names, matched: matched,
                      seconds: Dictionary(uniqueKeysWithValues: samples.map { ($0.voice, $0.seconds) }),
                      changedWords: changed, paragraphsBefore: before.paragraphs.count, paragraphsAfter: p.paragraphs.count,
                      shortTurns: shortTurns(p))
    }

    /// Runs of consecutive voiced words with one voice.
    static func runs(_ p: Project, _ voiceOfWord: [String?]) -> [(voice: String, words: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        for (i, v) in voiceOfWord.enumerated() {
            guard let v else { continue }
            if let last = out.last, last.0 == v { out[out.count - 1].1 = last.1.lowerBound..<(i + 1) } else { out.append((v, i..<(i + 1))) }
        }
        return out
    }

    /// What each voice says, in order of first appearance, with the words just before
    /// and after each of its turns.
    static func samples(_ p: Project, _ voiceOfWord: [String?]) -> [VoiceSample] {
        let runs = runs(p, voiceOfWord)
        let text = { (r: Range<Int>) in p.words[r].map(\.text).joined(separator: " ") }
        var order: [String] = []
        var bySpeaker: [String: VoiceSample] = [:]
        for (k, run) in runs.enumerated() {
            let before = k > 0 ? text(max(runs[k - 1].words.lowerBound, run.words.lowerBound - 15)..<run.words.lowerBound) : ""
            let after = k + 1 < runs.count ? text(runs[k + 1].words.lowerBound..<min(runs[k + 1].words.upperBound, run.words.upperBound + 8)) : ""
            let seconds = p.words[run.words].reduce(0.0) { $0 + (($1.end ?? 0) - ($1.start ?? 0)) }
            if bySpeaker[run.voice] == nil {
                order.append(run.voice)
                bySpeaker[run.voice] = VoiceSample(voice: run.voice, seconds: 0, turns: [])
            }
            bySpeaker[run.voice]!.seconds += seconds
            bySpeaker[run.voice]!.turns.append(.init(start: p.words[run.words.lowerBound].start ?? 0, text: text(run.words),
                                                     before: before, after: after))
        }
        return order.map { bySpeaker[$0]! }
    }

    /// Voice → the Zoom name most of its words fall under, when Zoom credits more than
    /// one person (a room account credits one name for everyone, which says nothing).
    static func zoomNames(_ p: Project, _ voiceOfWord: [String?], cues: [Cue]) -> [String: String] {
        guard let offset = p.zoom?.offset, Set(cues.compactMap(\.speaker)).count > 1 else { return [:] }
        let sorted = cues.filter { $0.speaker != nil }.sorted { $0.start < $1.start }
        var votes: [String: [String: Int]] = [:]
        var k = 0
        for (i, w) in p.words.enumerated() {
            guard let v = voiceOfWord[i], let s = w.start, let e = w.end else { continue }
            let z = (s + e) / 2 + offset
            while k < sorted.count - 1, sorted[k].end <= z { k += 1 }
            guard k < sorted.count, sorted[k].start <= z + 0.5, let name = sorted[k].speaker else { continue }
            votes[v, default: [:]][name, default: 0] += 1
        }
        return votes.compactMapValues { $0.max { $0.value < $1.value }?.key }
    }

    static func shortTurns(_ p: Project) -> [ShortTurn] {
        p.paragraphs.compactMap { para -> ShortTurn? in
            guard !para.zoomOnly else { return nil }
            let ws = p.words.filter { $0.paragraph == para.id && $0.isTimed }
            guard let s = ws.first?.start, let e = ws.last?.end, e - s < shortTurn else { return nil }
            return ShortTurn(start: s, seconds: e - s, speaker: para.speaker, text: ws.map(\.text).joined(separator: " "))
        }
    }
}
