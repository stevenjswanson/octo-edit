import Foundation
import Core

/// What a namer sees of a clip.
public struct ClipContext: Sendable, Equatable {
    /// The clip's kept words, in order.
    public var text: String
    public var speakers: [String]
    /// Names of the project's other clips, so suggestions don't repeat them.
    public var otherNames: [String]

    public init(text: String, speakers: [String] = [], otherNames: [String] = []) {
        self.text = text
        self.speakers = speakers
        self.otherNames = otherNames
    }

    public init(clip: Clip, in project: Project) {
        let words = project.keptWords(of: clip)
        text = words.map(\.text).joined(separator: " ")
        var seen: [String] = []
        for w in words {
            if let s = project.paragraph(w.paragraph)?.speaker, !seen.contains(s) { seen.append(s) }
        }
        speakers = seen
        otherNames = project.clips.filter { $0.id != clip.id }.compactMap(\.name)
    }
}

/// Suggests titles for a clip. Swappable: the CLI and GUI only see this protocol.
public protocol ClipNamer: Sendable {
    /// Short description for messages ("on-device model", …).
    var label: String { get }
    /// Best suggestion first.
    func suggest(for clip: ClipContext) async throws -> [String]
}

public enum Namers {
    /// The default namer: Apple's on-device model when Apple Intelligence is available,
    /// otherwise the heuristic. `reason` explains a fallback.
    public static func preferred() -> (namer: any ClipNamer, fallbackReason: String?) {
        switch FoundationModelsNamer.availability {
        case .success: return (FoundationModelsNamer(), nil)
        case .failure(let reason): return (HeuristicNamer(), reason.description)
        }
    }
}

/// Fills `suggestions` for clips and optionally names them from the top suggestion.
public enum Suggest {
    public enum Apply: Sendable {
        case none
        /// Name clips that have no name yet.
        case unnamed
        /// Rename every requested clip.
        case all
    }

    public struct Outcome: Sendable, Equatable {
        public var clip: ClipID
        public var suggestions: [String]
        public var renamed: Bool
    }

    public static func run(_ project: inout Project, clips: [ClipID]? = nil, namer: any ClipNamer,
                           apply: Apply) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for id in clips ?? project.clips.map(\.id) {
            guard let clip = project.clip(id) else { continue }
            var list = try await namer.suggest(for: ClipContext(clip: clip, in: project))
            list = dedupe(list)
            try project.setSuggestions(clip: id, list)
            var renamed = false
            if let top = list.first, apply == .all || (apply == .unnamed && clip.name == nil) {
                try project.setName(clip: id, top)
                renamed = true
            }
            outcomes.append(Outcome(clip: id, suggestions: list, renamed: renamed))
        }
        return outcomes
    }

    static func dedupe(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
