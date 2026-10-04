import Testing
import Foundation

/// Enforces the layering in the plan by scanning each target's `import` lines.
/// Project modules a target may import, and which system frameworks are confined
/// to which targets.
@Suite struct DependencyRulesTests {
    static let projectModules: Set<String> = ["Core", "Align", "MarkupGrammar", "Naming", "Load", "Save",
                                               "Ingest", "Transcribe", "Waveform", "Render"]

    static let allowed: [String: Set<String>] = [
        "Core": [],
        "Align": ["Core"],
        "MarkupGrammar": ["Core"],
        "Naming": ["Core"],
        "Load": ["Core", "Align", "MarkupGrammar"],
        "Save": ["Core", "MarkupGrammar"],
        "Ingest": ["Core", "Align"],
        "Transcribe": ["Core"],
        "Waveform": ["Core"],
        "Render": ["Core"],
    ]

    /// Framework → the only targets allowed to import it.
    static let confined: [String: Set<String>] = [
        "Speech": ["Transcribe"],
        "FoundationModels": ["Naming"],
        "AVFoundation": ["Transcribe", "Waveform", "Render"],
        "AVFAudio": ["Transcribe", "Waveform", "Render"],
        "CoreMedia": ["Transcribe", "Waveform", "Render"],
        "Yams": ["Load"],
        "AppKit": [],
        "SwiftUI": [],
    ]

    static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    static func imports(of target: String) throws -> [(file: String, module: String)] {
        let dir = sourcesDir.appendingPathComponent(target)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        var out: [(String, String)] = []
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let k = words.firstIndex(of: "import"), k + 1 < words.count,
                      words[..<k].allSatisfy({ $0.hasPrefix("@") || ["public", "internal", "private"].contains($0) }) else { continue }
                out.append((f, words[k + 1].split(separator: ".").first.map(String.init)!))
            }
        }
        return out
    }

    @Test(arguments: Array(allowed.keys).sorted())
    func targetImportsOnlyWhatItMay(_ target: String) throws {
        for (file, module) in try Self.imports(of: target) {
            if Self.projectModules.contains(module) {
                #expect(Self.allowed[target]!.contains(module), "\(target)/\(file) imports \(module)")
            }
            if let owners = Self.confined[module] {
                #expect(owners.contains(target), "\(target)/\(file) imports \(module), which is confined to \(owners.sorted())")
            }
        }
    }
}
