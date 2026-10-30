import Foundation
import ArgumentParser
import Core
import Align
import Load
import Save
import Render

struct SplitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split a clip in two before a given phrase.",
        discussion: """
        The second clip starts at the first word of --before; the first clip ends just
        before it. Each part keeps its own omissions (~~ … ~~); the first keeps the
        clip's name and notes, the second is unnamed. The phrase is matched ignoring
        case and punctuation, and must occur exactly once in the clip. Rewrites
        transcript.md (if the OctoEdit app has the project open, it offers to load
        the change).

        EXAMPLE
          octoedit split seminar.octoedit --clip lightning-round \\
              --before "What's the most important thing"
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Option(help: "The clip to split (its slug, as listed by `octoedit render --check`).")
    var clip: String

    @Option(help: "A few words of the transcript: the second clip starts at the first of them.")
    var before: String

    @Flag(help: "Print the two resulting clips as JSON (same fields as render --check --json).")
    var json = false

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        let transcript = pkg.appendingPathComponent("transcript.md").path
        if loaded.hasErrors {
            Console.issues(loaded.issues, file: transcript)
            Console.note("Fix transcript.md before splitting.")
            throw ExitCode.failure
        }
        var p = loaded.project
        let slugs = p.slugs()
        guard let target = p.clips.first(where: { slugs[$0.id] == clip }), let range = p.indexRange(of: target) else {
            throw ValidationError("no clip named \(clip); clips are: " + p.clips.compactMap { slugs[$0.id] }.joined(separator: ", "))
        }
        let hits = p.occurrences(of: before, in: range)
        guard hits.count == 1 else {
            Console.note(hits.isEmpty ? "“\(before)” isn't in clip \(clip)."
                                      : "“\(before)” occurs \(hits.count) times in clip \(clip); quote more words.")
            throw ExitCode.failure
        }
        let second: ClipID
        do { second = try p.splitClip(target.id, atWord: hits[0]) } catch {
            Console.note("Can't split there: \(error)")
            throw ExitCode.failure
        }
        try PackageWriter.save(p, to: pkg)

        let newSlugs = p.slugs()
        let parts = [target.id, second]
        if json {
            let index = { (id: ClipID) in p.clips.firstIndex { $0.id == id }! }
            JSONReport.emit(["clips": parts.map { JSONReport.clipOut(p, p.clip($0)!, index: index($0), slug: newSlugs[$0] ?? "") }])
        } else {
            for id in parts {
                let c = p.clip(id)!
                print("\(newSlugs[id] ?? "")  \(Captions.clock(p.duration(of: c)))  \(c.name ?? "(unnamed)")")
            }
            Console.note("Split \(clip) in two; transcript.md saved.")
        }
    }
}
