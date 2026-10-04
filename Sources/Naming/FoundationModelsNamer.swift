import Foundation
import FoundationModels
import Core

/// Titles from Apple's on-device language model (macOS 26, Apple Intelligence).
/// No network, no key; nothing leaves the Mac.
public struct FoundationModelsNamer: ClipNamer {
    public var label: String { "on-device model" }
    /// Clip text beyond this is cut (the on-device context window is small).
    public var maxCharacters = 6000

    public init() {}

    public enum Unavailable: Error, CustomStringConvertible {
        case notEligible, notEnabled, notReady, other

        public var description: String {
            switch self {
            case .notEligible: "this Mac can't run Apple's on-device model"
            case .notEnabled: "Apple Intelligence is turned off in System Settings"
            case .notReady: "Apple's on-device model is still downloading"
            case .other: "Apple's on-device model is unavailable"
            }
        }
    }

    public static var availability: Result<Void, Unavailable> {
        switch SystemLanguageModel.default.availability {
        case .available: return .success(())
        case .unavailable(.deviceNotEligible): return .failure(.notEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .failure(.notEnabled)
        case .unavailable(.modelNotReady): return .failure(.notReady)
        case .unavailable: return .failure(.other)
        }
    }

    @Generable
    struct Titles {
        @Guide(description: "Three distinct titles for the clip, best first. Each 3 to 8 words, sentence case, specific to what is said.", .count(3))
        var titles: [String]
    }

    static let instructions = """
    You title short video clips cut from a recorded meeting. Read the clip's transcript and \
    propose titles that tell a viewer what the clip is about. Be specific: name the topic, \
    decision, or question discussed. Use sentence case. Do not use quotation marks, speaker \
    names, the words "clip" or "video", or a trailing period.
    """

    public func suggest(for clip: ClipContext) async throws -> [String] {
        if case .failure(let reason) = Self.availability { throw reason }
        let session = LanguageModelSession(instructions: Self.instructions)
        var prompt = "Transcript:\n" + String(clip.text.prefix(maxCharacters))
        if !clip.otherNames.isEmpty {
            prompt += "\n\nOther clips from the same meeting are titled: " + clip.otherNames.joined(separator: "; ")
                + ". Make these titles distinct from those."
        }
        let response = try await session.respond(to: prompt, generating: Titles.self,
                                                 options: GenerationOptions(temperature: 0.3))
        return response.content.titles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .\"“”")) }
    }
}
