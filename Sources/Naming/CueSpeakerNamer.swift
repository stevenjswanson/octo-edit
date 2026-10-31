import Foundation
import Core

/// Names voices from textual cues, without a language model:
/// - self-introductions in the voice's own turns ("I'm Kathy", "my name's Ori");
/// - being handed the floor at the end of the turn before ("Leena, do you want to start?");
/// - being thanked at the start of the turn after ("Thanks, Mia.").
/// A voice saying a name outside an introduction counts against that name, since
/// people rarely talk about themselves in the third person.
public struct CueSpeakerNamer: SpeakerNamer {
    public var label: String { "textual cues" }
    /// The least evidence that names a voice.
    public var threshold = 2.0

    public init() {}

    public func names(for voices: [VoiceSample], roster: [String]) async -> [String: String] {
        let scores = score(voices, roster: roster)
        return Self.assign(scores, threshold: threshold)
    }

    /// Voice → roster name → evidence.
    func score(_ voices: [VoiceSample], roster: [String]) -> [String: [String: Double]] {
        let keys = roster.map { (name: $0, keys: Self.keys(for: $0)) }
        var out: [String: [String: Double]] = [:]
        for v in voices {
            var s: [String: Double] = [:]
            for t in v.turns {
                let own = Self.tokens(t.text)
                let before = Self.tokens(t.before)
                let after = Self.tokens(t.after)
                for (name, ks) in keys {
                    var intro = false
                    for k in ks where Self.introduces(own, k) { intro = true }
                    if intro { s[name, default: 0] += 3 }
                    else if ks.contains(where: { own.contains($0) }) { s[name, default: 0] -= 0.5 }
                    if ks.contains(where: { before.suffix(8).contains($0) }) { s[name, default: 0] += 1.5 }
                    if Self.thanks(after.prefix(5), ks) { s[name, default: 0] += 1.5 }
                }
            }
            out[v.voice] = s
        }
        return out
    }

    /// Best pairs first; each voice and each name used once.
    static func assign(_ scores: [String: [String: Double]], threshold: Double) -> [String: String] {
        var pairs: [(voice: String, name: String, score: Double)] = []
        for (v, s) in scores { for (n, x) in s where x >= threshold { pairs.append((v, n, x)) } }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.voice, $0.name) < ($1.voice, $1.name) }
        var out: [String: String] = [:]
        var used = Set<String>()
        for p in pairs where out[p.voice] == nil && !used.contains(p.name) {
            out[p.voice] = p.name
            used.insert(p.name)
        }
        return out
    }

    /// Words that identify a roster name in speech: the full name and its first word
    /// ("mia minnes", "mia").
    static func keys(for name: String) -> [String] {
        let t = tokens(name)
        guard let first = t.first else { return [] }
        return t.count > 1 ? [t.joined(separator: " "), first] : [first]
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
    }

    static func introduces(_ words: [String], _ key: String) -> Bool {
        let k = key.split(separator: " ").map(String.init)
        guard let first = k.first else { return false }
        for i in words.indices where words[i] == first && Array(words[i..<min(i + k.count, words.count)]) == k {
            let pre = words[max(0, i - 3)..<i].joined(separator: " ")
            if pre.hasSuffix("i'm") || pre.hasSuffix("i am") || pre.hasSuffix("name is") || pre.hasSuffix("my name") || pre.hasSuffix("this is")
                || pre.hasSuffix("call me") { return true }
        }
        return false
    }

    static func thanks(_ words: ArraySlice<String>, _ keys: [String]) -> Bool {
        let w = Array(words)
        guard w.contains("thanks") || w.contains("thank") else { return false }
        return keys.contains { w.contains($0) }
    }
}
