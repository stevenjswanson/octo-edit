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
        Each clip becomes <slug>-4k.mp4 (same resolution and frame rate as the input,
        hardware-encoded; the label is the resolution) with <slug>-4k.vtt captions and
        <slug>-4k.md notes, or <slug>-720p.* with --720p. --supercut also joins them into
        one video whose .md has YouTube chapters.
        Use --check to validate transcript.md without rendering, and --preview for fast
        720p <slug>.preview.mp4 versions in exports/preview/.
        With framing 9:16 (front matter `defaults: { framing: "9:16" }`, or --framing),
        clips are a full-height 9:16 column that follows whoever is speaking, named
        <slug>-4k-9x16.*; build face tracks first with `octoedit faces`.

        EXAMPLES
          octoedit render --check seminar.octoedit           validate; list the clips
          octoedit render --check --json seminar.octoedit    the same, as JSON
          octoedit render seminar.octoedit --720p --supercut
          octoedit render seminar.octoedit --clip what-makes-a-good-swe-today

        --json prints one JSON object on stdout. With --check:
          {"valid": bool, "transcript": path,
           "issues": [{"severity", "line", "message"}],
           "clips": [{"index", "name", "slug", "duration", "segments",
                      "omissions", "sourceStart", "sourceEnd",
                      "firstWords", "lastWords"}]}
        After an export:
          {"folder": path, "files": [{"slug", "name", "video", "captions",
                                      "notes", "duration"}]}
        Exit code 1 if transcript.md has errors.
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

    @Option(help: "Output shape for this run: source or 9:16 (default: the project's defaults.framing).")
    var framing: Framing?

    @Flag(name: .customLong("720p"), help: "Export at 1280×720 (H.264) instead of the input's resolution.")
    var hd720 = false

    @Option(name: .customLong("clip"), help: "Only this clip (by slug); repeatable.")
    var clips: [String] = []

    @Option(help: "Output folder (default: the package's exports/ folder).")
    var dest: String?

    @Flag(help: "Also join the exported clips, in order, into one <project>-supercut-4k.mp4 (with chapters in its .md).")
    var supercut = false

    @Flag(help: "Print results as one JSON object on stdout (see below).")
    var json = false

    func run() async throws {
        let pkg = URL(cliPath: package)
        let transcript = pkg.appendingPathComponent("transcript.md").path
        let loaded: PackageReader.Result
        do { loaded = try PackageReader.load(pkg) } catch {
            if json { JSONReport.emit(JSONReport.Check(valid: false, transcript: transcript, error: "\(error)", issues: [], clips: [])) }
            throw error
        }
        let p = loaded.project
        if json, check || loaded.hasErrors {
            JSONReport.emit(JSONReport.check(loaded, transcript: transcript, only: clips))
            if loaded.hasErrors { throw ExitCode.failure }
            if check { return }
        }
        if !json { Console.issues(loaded.issues, file: transcript) }
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
            if json { JSONReport.emit(JSONReport.Export(folder: nil, files: [])) }
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

        let options = Renderer.Options(codec: codec, preview: preview, resolution: hd720 ? .hd720 : .full, framing: framing)
        var faces: FaceTracks?
        if (framing ?? p.settings.framing) == .portrait {
            faces = PackageReader.loadFaces(pkg)
            if faces == nil { Console.note("No face tracks yet, so the 9:16 column stays centred. Run `octoedit faces` first.") }
        }
        let renderer = try await Renderer(project: p, source: loaded.sourceURL, faces: faces)
        let outDir = dest.map(URL.init(cliPath:)) ?? pkg.appendingPathComponent(preview ? "exports/preview" : "exports")
        let preview = preview
        let supercut = supercut
        let json = json

        let work = Task { () -> [Renderer.Rendered] in
            var done: [Renderer.Rendered] = []
            for (n, clip) in selected.enumerated() {
                let label = "[\(n + 1)/\(selected.count)] \(slugs[clip.id]!)"
                let r = try await renderer.render(clip, into: outDir, options: options) { Console.progress(label, $0) }
                done.append(r)
                if !json { print(r.file.path) }
            }
            if supercut {
                // Joined from the clips just exported: no second encode.
                let slug = renderer.supercutSlug(base: pkg.deletingPathExtension().lastPathComponent)
                let r = try await renderer.joinSupercut(done, slug: slug, into: outDir, options: options) {
                    Console.progress("[supercut] \(slug)", $0)
                }
                done.append(r)
                if !json { print(r.file.path) }
            }
            return done
        }
        // Ctrl-C cancels cleanly: the clip being encoded is abandoned and its partial
        // file removed; clips already finished stay.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { work.cancel() }
        interrupt.resume()
        defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }

        do {
            let done = try await work.value
            if json { JSONReport.emit(JSONReport.export(done, folder: outDir)) }
            Console.note("Exported \(done.count) clip\(done.count == 1 ? "" : "s") to \(outDir.path)")
        } catch is CancellationError {
            Console.note("Cancelled. Clips that finished are in \(outDir.path); nothing partial was left behind.")
            throw ExitCode(130)
        }
    }
}
