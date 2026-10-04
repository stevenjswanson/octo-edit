import Foundation
import ArgumentParser
import Core
import Load
import Render

struct RenderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Export the clips marked in a project's transcript.md.",
        discussion: """
        Each clip becomes <slug>.mp4 (same resolution and frame rate as the input,
        hardware-encoded) with <slug>.vtt captions; notes.md lists what was exported.
        Use --check to validate transcript.md without rendering, and --preview for fast
        720p <slug>.preview.mp4 versions in exports/preview/.
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Flag(help: "Only validate transcript.md and list the clips.")
    var check = false

    @Flag(help: "Fast 720p H.264 <slug>.preview.mp4 files in exports/preview/ (no captions).")
    var preview = false

    @Option(help: "Output codec (default: the project's, else same as the input).")
    var codec: Codec?

    @Option(name: .customLong("clip"), help: "Only this clip (by slug); repeatable.")
    var clips: [String] = []

    @Option(help: "Output folder (default: the package's exports/ folder).")
    var dest: String?

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        let p = loaded.project
        Console.issues(loaded.issues, file: pkg.appendingPathComponent("transcript.md").path)
        if loaded.hasErrors { throw ExitCode.failure }

        let slugs = p.slugs()
        var selected = p.clips
        if !clips.isEmpty {
            let unknown = clips.filter { s in !p.clips.contains { slugs[$0.id] == s } }
            if !unknown.isEmpty {
                throw ValidationError("no clip named \(unknown.joined(separator: ", ")); clips are: "
                                      + p.clips.compactMap { slugs[$0.id] }.joined(separator: ", "))
            }
            selected = p.clips.filter { clips.contains(slugs[$0.id]!) }
        }
        if selected.isEmpty {
            Console.note("No clips are marked yet. Add {clip \"Name\"} … {/clip} around text in transcript.md.")
            return
        }

        if check {
            for c in selected {
                let omits = p.omittedRanges(of: c).count
                let slug = slugs[c.id]!.padding(toLength: max(28, slugs[c.id]!.count), withPad: " ", startingAt: 0)
                let clock = String(repeating: " ", count: max(0, 8 - Captions.clock(p.duration(of: c)).count)) + Captions.clock(p.duration(of: c))
                let segs = "\(c.segments.count) segment\(c.segments.count == 1 ? "" : "s")" + (omits > 0 ? ", \(omits) omitted" : "")
                print("\(slug) \(clock)  \(segs)")
            }
            Console.note("transcript.md is valid; \(selected.count) clip\(selected.count == 1 ? "" : "s") ready to render.")
            return
        }

        let renderer = try await Renderer(project: p, source: loaded.sourceURL)
        let outDir = dest.map(URL.init(cliPath:)) ?? pkg.appendingPathComponent(preview ? "exports/preview" : "exports")
        let options = Renderer.Options(codec: codec, preview: preview)
        var done: [Renderer.Rendered] = []
        for (n, clip) in selected.enumerated() {
            let label = "[\(n + 1)/\(selected.count)] \(slugs[clip.id]!)"
            let r = try await renderer.render(clip, into: outDir, options: options) { Console.progress(label, $0) }
            done.append(r)
            print(r.file.path)
        }
        if !preview {
            let notes = outDir.appendingPathComponent("notes.md")
            try renderer.notesFile(for: done).write(to: notes, atomically: true, encoding: .utf8)
        }
        Console.note("Exported \(done.count) clip\(done.count == 1 ? "" : "s") to \(outDir.path)")
    }
}
