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
        A project is a folder ending in .octoedit. Its transcript.md holds the
        transcript; clips are marked by inserting markers into the text. The
        video is never changed.

        WORKFLOW
          1. octoedit init --video talk.mp4 --zoom talk.vtt talk.octoedit
               transcribe the video; writes talk.octoedit/transcript.md
          2. edit talk.octoedit/transcript.md: insert {clip "Title"} … {/clip} around
               each clip, ~~ … ~~ around words to cut out of a clip
               (the full rules: octoedit guide)
          3. octoedit render --check --json talk.octoedit
               validate; repeat 2–3 until "valid": true
          4. octoedit render talk.octoedit
               export each clip to talk.octoedit/exports/
               as .mp4 video, .vtt captions and .md notes

        FOR AI AGENTS
          Read `octoedit guide` before editing transcript.md. Change it only by
          inserting markers, never by changing words. Use --json for
          machine-readable results. Results go to stdout; progress and messages
          go to stderr.

        EXIT CODES
          0  success
          1  transcript.md has errors, or an export failed
          64 bad command-line arguments
          130 cancelled (Ctrl-C); finished clips stay, nothing partial is left
        """,
        subcommands: [InitCommand.self, RenderCommand.self, SplitCommand.self, NameCommand.self, SpeakersCommand.self, FacesCommand.self, GuideCommand.self]
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
extension Framing: ExpressibleByArgument {}

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
