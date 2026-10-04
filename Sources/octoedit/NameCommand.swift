import Foundation
import ArgumentParser
import Core
import Load
import Save
import Naming

struct NameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "name",
        abstract: "Suggest clip names with Apple's on-device model.",
        discussion: """
        Writes suggestions into transcript.md's front matter. With --apply, unnamed
        clips ({clip} with no name) take the top suggestion; add --all to rename every
        clip. Saving rewrites transcript.md in canonical form.
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Option(name: .customLong("clip"), help: "Only this clip (by slug); repeatable.")
    var clips: [String] = []

    @Flag(help: "Name unnamed clips with the top suggestion.")
    var apply = false

    @Flag(help: "With --apply, rename clips that already have names too.")
    var all = false

    func validate() throws {
        if all && !apply { throw ValidationError("--all only makes sense with --apply") }
    }

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        Console.issues(loaded.issues, file: pkg.appendingPathComponent("transcript.md").path)
        if loaded.hasErrors { throw ExitCode.failure }
        var p = loaded.project
        let slugs = p.slugs()
        let ids = clips.isEmpty ? nil : p.clips.filter { clips.contains(slugs[$0.id]!) }.map(\.id)
        if let ids, ids.count != clips.count { throw ValidationError("unknown clip slug in \(clips.joined(separator: ", "))") }
        if p.clips.isEmpty { Console.note("No clips are marked yet."); return }

        let (namer, reason) = Namers.preferred()
        if let reason { Console.note("Using the \(namer.label) because \(reason).") }
        let outcomes = try await Suggest.run(&p, clips: ids, namer: namer, apply: apply ? (all ? .all : .unnamed) : .none)
        try PackageWriter.save(p, to: pkg)

        let newSlugs = p.slugs()
        for o in outcomes {
            print("\(newSlugs[o.clip]!)\(o.renamed ? "  (renamed)" : "")")
            for s in o.suggestions { print("    \(s)") }
        }
    }
}
