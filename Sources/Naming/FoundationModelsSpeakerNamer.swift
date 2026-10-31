import Foundation
import FoundationModels
import Core

/// Names voices with the textual cues first, then asks Apple's on-device model about
/// the voices and roster names still unmatched, for cues the rules miss ("Questions.
/// Steve's first." from the moderator). Answers outside the roster are ignored.
public struct FoundationModelsSpeakerNamer: SpeakerNamer {
    public var label: String { "on-device model" }
    public var cues = CueSpeakerNamer()
    /// Voices with less speech than this are left to the cues alone.
    public var minimumSeconds: Seconds = 20
    public var turnsPerVoice = 5
    public var wordsPerTurn = 30

    public init() {}

    @Generable
    struct Match {
        @Guide(description: "The voice label, exactly as given, e.g. S3.")
        var voice: String
        @Guide(description: "The roster name of this voice's speaker, exactly as written in the roster, or unknown.")
        var name: String
    }

    @Generable
    struct Matches {
        var matches: [Match]
    }

    static let instructions = """
    You identify speakers in a transcript of a recorded panel or meeting. Each voice is \
    one person. For each voice you see a few of its turns, each with the words said just \
    before it by someone else. Decide which roster name belongs to each voice, using \
    introductions, people being called on by name, people being thanked, and people \
    referring to themselves. Use a roster name only when the text supports it, use each \
    name for at most one voice, and answer unknown otherwise.
    """

    public func names(for voices: [VoiceSample], roster: [String]) async -> [String: String] {
        var out = await cues.names(for: voices, roster: roster)
        guard case .success = FoundationModelsNamer.availability else { return out }
        let names = roster.filter { !out.values.contains($0) }
        let open = voices.filter { out[$0.voice] == nil && $0.seconds >= minimumSeconds }
        guard !names.isEmpty, !open.isEmpty else { return out }

        var prompt = "Roster: " + names.joined(separator: "; ") + "\n\nVoices:\n"
        for v in open {
            prompt += "\nVoice \(v.voice) (speaks for \(Int(v.seconds)) seconds):\n"
            for t in v.turns.sorted(by: { $0.text.count > $1.text.count }).prefix(turnsPerVoice).sorted(by: { $0.start < $1.start }) {
                let before = t.before.split(separator: " ").suffix(12).joined(separator: " ")
                let text = t.text.split(separator: " ").prefix(wordsPerTurn).joined(separator: " ")
                prompt += "- (before: \"\(before)\") \(v.voice): \"\(text)\"\n"
            }
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        guard let response = try? await session.respond(to: prompt, generating: Matches.self,
                                                        options: GenerationOptions(temperature: 0)) else { return out }
        let openVoices = Set(open.map(\.voice))
        for m in response.content.matches {
            let name = m.name.trimmingCharacters(in: .whitespaces)
            guard openVoices.contains(m.voice), out[m.voice] == nil, names.contains(name), !out.values.contains(name) else { continue }
            out[m.voice] = name
        }
        return out
    }
}

public enum SpeakerNamers {
    /// The on-device model with the textual cues, or the cues alone when Apple
    /// Intelligence is unavailable (`reason` says why).
    public static func preferred() -> (namer: any SpeakerNamer, fallbackReason: String?) {
        switch FoundationModelsNamer.availability {
        case .success: return (FoundationModelsSpeakerNamer(), nil)
        case .failure(let reason): return (CueSpeakerNamer(), reason.description)
        }
    }
}
