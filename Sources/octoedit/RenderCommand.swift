import Foundation
import ArgumentParser
import Core
import Load
import Render
import FaceTrack
import SpeakerFraming

struct RenderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Export the clips marked in a project's transcript.md.",
        discussion: """
        Each clip gets its own folder, exports/C<n>-<slug>/, holding C<n>-<slug>-4k.mp4
        (same resolution and frame rate as the input, hardware-encoded; the label is
        the resolution), .vtt captions, .timeline.json (see TIMELINE) and .md notes
        with the same name; --720p makes C<n>-<slug>-720p.* in the same folder.
        C<n> is the clip's place in the video (C01, C02, …; three digits from 100
        clips), so exports list in video order. --clip still takes the bare slug.
        Clips marked {clip … noexport} (the app's unchecked Export box) are skipped
        unless named with --clip.
        --supercut also joins the clips into one video in its own folder, whose .md
        has YouTube chapters.
        Use --check to validate transcript.md without rendering, and --preview for fast
        720p C<n>-<slug>.preview.mp4 versions in exports/preview/ (no folders, no sidecars).
        With framing 9:16 (front matter `defaults: { framing: "9:16" }`, or --framing),
        clips are a full-height 9:16 column that follows whoever is speaking, named
        C<n>-<slug>-4k-9x16.*; build face tracks first with `octoedit faces`.

        TIMELINE
          <name>.timeline.json says who speaks when and where the cuts are, so other
          tools need not parse transcript.md. Every time is in seconds on the
          exported video's own clock (0 = its first frame), rounded to 1 ms, from
          the frame-snapped cuts the encoder used. Arrays have one element per line.
          {"octoedit": 1,                 format version
           "source": path,                input video, as written in transcript.md
           "duration": s,                 length of the exported video
           "speakers": [name],            in order of first appearance
           "clips": [{"slug", "title", "start", "end"}],
                                          one per clip in the video (several in a
                                          supercut)
           "segments": [{"clip", "start", "end", "sourceStart", "sourceEnd"}],
                                          each kept run of the input, in order;
                                          every boundary between two is a cut, and
                                          sourceStart/End are on the input's clock
           "turns": [{"speaker", "start", "end", "text"}],
                                          consecutive kept words by one speaker; a
                                          turn may span a cut, and a new one starts
                                          at each change of speaker or of clip
           "words": [{"start", "end", "speaker", "segment", "text"}],
                                          each kept word; segment indexes segments
           "titlecard": {"time", "auto", "image"}}
                                          single clips with a face found (needs
                                          cache/faces.tsv): the title card's still,
                                          time on the input's clock, auto = picked
                                          automatically (no still= on the clip),
                                          image = <name>.still.jpg beside it, that
                                          frame framed like the video (see
                                          `octoedit stills --help`)
          speaker is null for words with no speaker. Words typed by hand (never
          spoken, so untimed) are left out, as in the captions.

        POST-EXPORT
          A project can name a program that turns each plain export into the real one
          (the seminar's clips are branded this way), in the front matter:
          post-export: { run: ~/bin/brand-clip, args: ["{timeline}", -o, "{output}"] }
          (`post-export: ~/tools/brand-clip` alone means those args). The app's Export
          sheet sets it too (Configure Export Hook…). Then, unless --no-post-export:
          - Each clip is first exported into exports/C<n>-<slug>/.unbranded/ (the .mp4
            and its .timeline.json, .vtt and .md, named as usual).
          - As soon as a clip is encoded, the program runs on it, while the next clip
            encodes; one program runs at a time, in clip order, then once for the
            supercut (joined from the plain clips). Never for --preview.
          - run is a path: absolute, ~/…, or relative to the package. It is started
            directly (no shell), in the package folder. Placeholders in args:
              {timeline}  the plain export's .timeline.json (.mp4/.vtt/.md beside it)
              {video}     the plain export's .mp4
              {output}    the .mp4 to write (a hidden partial name; required)
              {exports}   the export folder
            Environment: OCTOEDIT_PROJECT, OCTOEDIT_EXPORTS, OCTOEDIT_FRAMING (source
            or 9:16), OCTOEDIT_QUALITY (full or 720p), OCTOEDIT_SLUG, and
            OCTOEDIT_SUPERCUT=1 for the supercut; PATH gains /opt/homebrew/bin and
            /usr/local/bin. stdout and stderr are shown to the user.
          - Exit 0 having written {output}: it becomes C<n>-<slug>-4k.mp4 (the usual
            name), the sidecars are copied beside it, and .unbranded/ is removed after
            the run. Anything else fails that clip: nothing appears under the final
            name (an older export there is kept), .unbranded/ stays for a look, and
            render exits 1.
          - Ctrl-C (or Cancel in the app) sends SIGTERM; {output} is removed.

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
                                      "notes", "timeline", "duration",
                                      "postExport", "postExportOutput"}]}
          (each file's paths are inside folder/C<n>-<slug>/, except previews;
           "slug" is the bare slug, as --clip takes it; "postExport" is "done",
           "failed" or "skipped" when the project has a post-export program, with
           the program's output in "postExportOutput" when it failed)
        Exit code 1 if transcript.md has errors or a post-export step failed.
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Flag(help: "Only validate transcript.md and list the clips.")
    var check = false

    @Flag(help: "Fast 720p H.264 C<n>-<slug>.preview.mp4 files in exports/preview/ (no captions).")
    var preview = false

    @Option(help: "Output codec (default: the project's, else same as the input).")
    var codec: Codec?

    @Option(help: "Output shape for this run: source or 9:16 (default: the project's defaults.framing).")
    var framing: Framing?

    @Flag(name: .customLong("720p"), help: "Export at 1280×720 (H.264) instead of the input's resolution.")
    var hd720 = false

    @Option(name: .customLong("clip"), help: "Only this clip (by slug); repeatable.")
    var clips: [String] = []

    @Option(help: "Output folder, which gets one subfolder per clip (default: the package's exports/ folder).")
    var dest: String?

    @Flag(help: "Also join the exported clips, in order, into one <project>-supercut-4k.mp4 (with chapters in its .md).")
    var supercut = false

    @Flag(help: "Print results as one JSON object on stdout (see below).")
    var json = false

    @Flag(help: "Skip the project's post-export program (see POST-EXPORT): plain exports.")
    var noPostExport = false

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
        // Clips marked `noexport` are skipped unless asked for by name.
        var selected = p.clips.filter(\.export)
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
            Console.note(p.clips.isEmpty ? "No clips are marked yet. Add {clip \"Name\"} … {/clip} around text in transcript.md."
                                         : "Every clip is marked noexport; name one with --clip to export it anyway.")
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

        let postExport = preview || noPostExport ? nil : p.settings.postExport
        if let postExport, let problem = PostExportRunner.problem(postExport, package: pkg) {
            throw ValidationError("post-export: \(problem). Fix `post-export:` in transcript.md, or add --no-post-export.")
        }
        let options = Renderer.Options(codec: codec, preview: preview, resolution: hd720 ? .hd720 : .full, framing: framing,
                                       postExport: postExport)
        var faces: FaceTracks?
        if (framing ?? p.settings.framing) == .portrait {
            faces = PackageReader.loadFaces(pkg)
            if faces == nil { Console.note("No face tracks yet, so the 9:16 column stays centred. Run `octoedit faces` first.") }
        }
        // Title-card stills need the face tracks (in either framing); not for previews.
        let stills = preview ? nil : (faces ?? PackageReader.loadFaces(pkg)).map {
            TitleStills(video: loaded.sourceURL, faces: $0, project: p, scorer: VisionStillScorer(),
                        scores: PackageReader.loadStillScores(pkg))
        }
        let renderer = try await Renderer(project: p, source: loaded.sourceURL, faces: faces, stills: stills)
        let outDir = dest.map(URL.init(cliPath:)) ?? pkg.appendingPathComponent(preview ? "exports/preview" : "exports")
        let supercut = supercut
        let json = json
        let context = postExport.map {
            PostExportRunner.Context(command: $0, package: pkg, exports: outDir, framing: renderer.framing(options),
                                     resolution: options.resolution)
        }
        let lane = SerialLane()

        let work = Task { () -> [JSONReport.Outcome] in
            var staged: [Renderer.Rendered] = []
            var finishing: [(Renderer.Rendered, Task<Renderer.Rendered, Error>?)] = []
            // The post-export step for one staged file, queued behind the others.
            func finish(_ r: Renderer.Rendered, supercut: Bool = false) async -> Task<Renderer.Rendered, Error>? {
                guard let context else { return nil }
                let name = context.command.name
                return await lane.submit {
                    Console.note("\(name): \(r.file.lastPathComponent)")
                    let done = try await PostExportRunner.run(r, context, supercut: supercut) { Console.note("  \(name): \($0)") }
                    if !json { print(done.file.path) }
                    return done
                }
            }
            for (n, clip) in selected.enumerated() {
                let label = "[\(n + 1)/\(selected.count)] \(slugs[clip.id]!)"
                let r = try await renderer.render(clip, into: outDir, options: options) { Console.progress(label, $0) }
                staged.append(r)
                if context == nil, !json { print(r.file.path) }
                finishing.append((r, await finish(r)))
            }
            if supercut {
                // Joined from the clips just exported: no second encode.
                let slug = renderer.supercutSlug(base: pkg.deletingPathExtension().lastPathComponent)
                let r = try await renderer.joinSupercut(staged, slug: slug, into: outDir, options: options) {
                    Console.progress("[supercut] \(slug)", $0)
                }
                if context == nil, !json { print(r.file.path) }
                finishing.append((r, await finish(r, supercut: true)))
            }
            var outcomes: [JSONReport.Outcome] = []
            var finished: [Renderer.Rendered] = []
            for (r, task) in finishing {
                guard let task else { outcomes.append(JSONReport.Outcome(rendered: r)); continue }
                do {
                    let done = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    outcomes.append(JSONReport.Outcome(rendered: done, postExport: "done"))
                    finished.append(r)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Console.note("\(r.slug): \(error)")
                    outcomes.append(JSONReport.Outcome(rendered: r, postExport: "failed",
                                                       output: (error as? PostExportRunner.Failure)?.output))
                }
            }
            // Staged files are kept only where the step failed, to look at.
            finished.forEach(PostExportRunner.removeStaging)
            return outcomes
        }
        // Ctrl-C cancels cleanly: the clip being encoded is abandoned and its partial
        // file removed; clips already finished stay.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { work.cancel(); Task { await lane.cancelAll() } }
        interrupt.resume()
        defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }

        do {
            let done = try await work.value
            if let stills { await StillsCommand.saveScores(stills, pkg) }
            if json { JSONReport.emit(JSONReport.export(done, folder: outDir)) }
            let failed = done.filter { $0.postExport == "failed" }.count
            Console.note("Exported \(done.count) clip\(done.count == 1 ? "" : "s") to \(outDir.path)"
                         + (failed > 0 ? "; \(failed) failed in \(postExport!.name)" : ""))
            if failed > 0 { throw ExitCode.failure }
        } catch is CancellationError {
            if let stills { await StillsCommand.saveScores(stills, pkg) }
            Console.note("Cancelled. Clips that finished are in \(outDir.path); nothing partial was left behind.")
            throw ExitCode(130)
        }
    }
}
