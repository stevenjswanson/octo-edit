import Foundation
import ArgumentParser
import Core
import MarkupGrammar

@main
struct OctoEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "octoedit",
        abstract: "Cut a recorded meeting into clips by editing its transcript.",
        discussion: """
        Workflow: `octoedit init` creates a .octoedit package with transcript.md;
        mark clips and omissions in transcript.md with any text editor;
        `octoedit render` exports the clips.
        """,
        subcommands: [InitCommand.self, RenderCommand.self, NameCommand.self]
    )
}

/// A duration given as `120ms`.
struct Milliseconds: ExpressibleByArgument {
    let seconds: Seconds
    init?(argument: String) {
        guard let s = Grammar.parseMilliseconds(argument), s >= 0 else { return nil }
        seconds = s
    }
}

extension Codec: ExpressibleByArgument {}

/// Writes progress and messages to stderr, keeping stdout for results.
enum Console {
    nonisolated(unsafe) static var lastWasProgress = false

    static func progress(_ label: String, _ fraction: Double) {
        let pct = Int((fraction * 100).rounded())
        FileHandle.standardError.write(Data("\r\(label)… \(pct)%   ".utf8))
        lastWasProgress = true
        if fraction >= 1 { FileHandle.standardError.write(Data("\n".utf8)); lastWasProgress = false }
    }

    static func note(_ s: String) {
        if lastWasProgress { FileHandle.standardError.write(Data("\n".utf8)); lastWasProgress = false }
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Errors first, in file order, then warnings; at most `limit` lines, since later
    /// errors are often knock-on effects of the first.
    static func issues(_ issues: [Issue], file: String, limit: Int = 10) {
        let sorted = issues.filter { $0.severity == .error } + issues.filter { $0.severity == .warning }
        for i in sorted.prefix(limit) {
            note("\(file):\(i.line.map(String.init) ?? "-"): \(i.severity.rawValue): \(i.message)")
        }
        if sorted.count > limit {
            note("…and \(sorted.count - limit) more. Fix the first error and re-check; later ones are often caused by it.")
        }
    }
}

extension URL {
    init(cliPath: String) {
        self = URL(fileURLWithPath: (cliPath as NSString).expandingTildeInPath).standardizedFileURL
    }
}
