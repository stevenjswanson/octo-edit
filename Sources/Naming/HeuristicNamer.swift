import Foundation
import Core

/// Offline fallback: the clip's first substantive sentence, trimmed to a title.
public struct HeuristicNamer: ClipNamer {
    public var label: String { "heuristic (first sentence)" }
    public var maxWords = 8

    static let fillers: Set<String> = ["um", "uh", "er", "ah", "so", "okay", "ok", "well", "like", "yeah", "right", "sure", "and"]

    public init() {}

    public func suggest(for clip: ClipContext) async throws -> [String] {
        let sentences = clip.text.split(omittingEmptySubsequences: true) { ".?!".contains($0) }
            .map { $0.split(separator: " ").map(String.init) }
        var titles: [String] = []
        for words in sentences {
            var w = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            while let f = w.first, Self.fillers.contains(f.lowercased()) { w.removeFirst() }
            w = w.filter { !["um", "uh", "er", "ah"].contains($0.lowercased()) }
            guard w.count >= 3 else { continue }
            let title = w.prefix(maxWords).joined(separator: " ")
            titles.append(title.prefix(1).uppercased() + title.dropFirst())
            if titles.count == 2 { break }
        }
        return titles.isEmpty ? [] : titles
    }
}
