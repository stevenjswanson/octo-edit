import AppKit
import Observation
import Core
import Render
import SpeakerFraming

/// The Export sheet's state. Exports the project as it is in the window (unsaved edits
/// included) through Render — the same code as `octoedit render` — one clip at a time:
/// `C<n>-<slug>/C<n>-<slug>-4k.mp4` + `.vtt` captions + `.timeline.json` + `.md` notes, one folder per clip; the supercut is joined from
/// those files (no second encode) and its `.md` carries YouTube chapters.
@MainActor @Observable
final class ExportModel {
    struct Row: Identifiable {
        let id: ClipID
        var include: Bool
        var title: String
        var slug: String
        var duration: Double
        var progress: Double = 0
        var state: State = .waiting
        /// queued: encoded, waiting for the post-export program; finishing: it's running.
        enum State: Equatable { case waiting, exporting, queued, finishing, done, failed(String), skipped }
        /// What the post-export program printed, when it failed.
        var output: String?
    }

    enum Phase: Equatable { case choosing, exporting, finished(String), failed(String) }

    var rows: [Row] = []
    var codec: Codec?
    var destination: URL?
    var revealWhenDone = true
    /// Full resolution or 720p; remembered between exports.
    var resolution: Renderer.Resolution = Renderer.Resolution(rawValue: UserDefaults.standard.string(forKey: "exportResolution") ?? "") ?? .full {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "exportResolution") }
    }
    /// The source's details, for labels ("4k") and the summary line.
    private(set) var sourceInfo: SourceInfo?

    /// The label that goes into file names for the chosen resolution.
    var label: String {
        if resolution == .hd720 { return "720p" }
        return sourceInfo.map { Renderer.resolutionLabel(.full, info: $0) } ?? "full"
    }
    /// Run the project's post-export program (`post-export:`, e.g. brand-clip) on each
    /// file, so the export is its result; off gives plain exports. Remembered.
    var runPostExport: Bool = UserDefaults.standard.object(forKey: "runPostExport") as? Bool ?? true {
        didSet { UserDefaults.standard.set(runPostExport, forKey: "runPostExport"); onOutputChange() }
    }
    /// The post-export program's latest line of output, while it runs.
    private(set) var postExportLine = ""
    /// What the supercut's post-export program printed, when it failed.
    private(set) var supercutOutput: String?
    /// Export each checked clip as its own file.
    var individualClips = true
    /// Also join the checked clips, in order, into one `<project>-supercut.mp4`.
    var supercut = false
    /// Overall progress (0…1), weighted by duration, and what's being written now.
    private(set) var overall: Double = 0
    private(set) var currentLabel = ""
    /// The row being exported (the list keeps it in view); nil during the supercut.
    private(set) var currentRow: ClipID?
    private(set) var supercutState: Row.State = .waiting
    private(set) var supercutProgress: Double = 0
    private(set) var phase: Phase = .choosing
    private(set) var sourceCodec: Codec?
    private(set) var sourceSummary = ""

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Called when an export run ends (done, failed or cancelled), to recheck what's stale.
    @ObservationIgnored var onFinish: () -> Void = {}
    /// Hands back the title-card stills an export worked out (so their scores are kept).
    @ObservationIgnored var onStills: (TitleStills) async -> Void = { _ in }
    /// Called when an option that's part of an export's stamp changes (post-export on/off).
    @ObservationIgnored var onOutputChange: () -> Void = {}
    /// The package being exported, for remembering its export folder.
    @ObservationIgnored private var package: URL?
    @ObservationIgnored let queue: any ExportQueue = PassThroughExportQueue()
    /// Post-export jobs of the current run, one at a time beside the encoder.
    @ObservationIgnored private var lane: SerialLane?

    var isExporting: Bool { phase == .exporting }
    var includedCount: Int { rows.filter(\.include).count }
    var totalDuration: Double { rows.filter(\.include).reduce(0) { $0 + $1.duration } }

    /// Fills the sheet from the project; `selected` (if any) starts as the only checked clip
    /// when `onlySelected` is set.
    func prepare(project: Project, package: URL?, source: URL?, selected: ClipID?, onlySelected: Bool) {
        guard !isExporting else { return }
        let slugs = project.slugs()
        rows = project.clips.map { c in
            Row(id: c.id, include: onlySelected ? c.id == selected : c.export, title: c.name ?? "Unnamed",
                slug: slugs[c.id] ?? "", duration: project.duration(of: c))
        }
        codec = project.settings.codec
        self.package = package
        if destination == nil { destination = Self.lastFolder(package: package) }
        phase = .choosing
        if let source {
            Task {
                if let info = try? await SourceInfo.read(source) {
                    sourceInfo = info
                    sourceCodec = info.codec
                    sourceSummary = "\(info.width)×\(info.height), \(String(format: "%g", (info.frameRate * 100).rounded() / 100)) fps, \(info.codec.rawValue.uppercased())"
                }
            }
        }
    }

    var canExport: Bool { includedCount > 0 && (individualClips || supercut) && destination != nil }

    /// The post-export step for a run into `dest`, if the project has one and it's on.
    func postExportContext(_ project: Project, dest: URL) -> PostExportRunner.Context? {
        guard runPostExport, let command = project.settings.postExport, let package else { return nil }
        return PostExportRunner.Context(command: command, package: package, exports: dest,
                                        framing: project.settings.framing, resolution: resolution)
    }

    /// Queues the post-export step for a staged file. The job updates the row (or the
    /// supercut's status when `id` is nil) and returns the final export, or the failure;
    /// it throws only when cancelled.
    private func finish(_ staged: Renderer.Rendered, id: ClipID?, supercut: Bool, context: PostExportRunner.Context,
                        lane: SerialLane, completed: @escaping @MainActor () -> Void) async -> Task<Result<Renderer.Rendered, Error>, Error> {
        await lane.submit { [weak self] in
            await MainActor.run { self?.setFinishing(id, .finishing) }
            do {
                let done = try await PostExportRunner.run(staged, context, supercut: supercut) { l in
                    Task { @MainActor [weak self] in self?.postExportLine = l }
                }
                await MainActor.run { self?.setFinishing(id, .done); completed() }
                return .success(done)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let output = (error as? PostExportRunner.Failure)?.output
                await MainActor.run {
                    self?.setFinishing(id, .failed(String(describing: error)), output: output)
                    completed()
                }
                return .failure(error)
            }
        }
    }

    private func setFinishing(_ id: ClipID?, _ state: Row.State, output: String? = nil) {
        if let id { set(id) { $0.state = state; $0.output = output } } else { supercutState = state; supercutOutput = output }
        if state == .finishing { postExportLine = "" }
    }

    typealias Job = (staged: Renderer.Rendered, task: Task<Result<Renderer.Rendered, Error>, Error>)

    /// Waits for the queued post-export jobs, then removes the staged copies of those
    /// that succeeded. Returns the final exports and the failures (by staged file).
    private func collect(_ jobs: [Job]) async throws -> (done: [Renderer.Rendered], failed: [(Renderer.Rendered, Error)]) {
        var finals: [Renderer.Rendered] = [], failed: [(Renderer.Rendered, Error)] = []
        for job in jobs {
            let task = job.task
            switch try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() }) {
            case .success(let done):
                finals.append(done)
                PostExportRunner.removeStaging(of: job.staged)
            case .failure(let error):
                failed.append((job.staged, error))
            }
        }
        return (finals, failed)
    }

    func start(project: Project, source: URL, packageName: String, faces: FaceTracks? = nil, stills: TitleStills? = nil) {
        guard let dest = destination, !isExporting, canExport else { return }
        let chosen = project.clips.filter { c in rows.contains { $0.id == c.id && $0.include } }
        guard !chosen.isEmpty else { return }
        Self.remember(folder: dest, package: package)
        let individual = individualClips, makeSupercut = supercut
        let context = postExportContext(project, dest: dest)
        // Work, in seconds of output, for the overall bar.
        let clipSeconds = chosen.map { project.duration(of: $0) }
        // Joining finished clips is nearly free; only a supercut encoded from the source
        // (no individual clips) costs as much as the clips themselves.
        let supercutWork = makeSupercut ? (individual ? clipSeconds.reduce(0, +) * 0.05 : clipSeconds.reduce(0, +)) : 0
        // The post-export program (branding) takes about as long again per file.
        let finishWork = context == nil ? 0 : (individual ? clipSeconds.reduce(0, +) : 0) + (makeSupercut ? clipSeconds.reduce(0, +) : 0)
        let total = max((individual ? clipSeconds.reduce(0, +) : 0) + supercutWork + finishWork, 0.001)
        var finished = 0.0
        overall = 0
        supercutState = makeSupercut ? .waiting : .skipped
        supercutProgress = 0
        supercutOutput = nil
        postExportLine = ""
        for i in rows.indices {
            rows[i].progress = 0
            rows[i].output = nil
            rows[i].state = rows[i].include && individual ? .waiting : .skipped
        }
        phase = .exporting
        let options = Renderer.Options(codec: codec, resolution: resolution, postExport: context?.command)
        let queue = queue
        let lane = SerialLane()
        self.lane = lane
        task = Task {
            var done: [Renderer.Rendered] = []
            var jobs: [Job] = []
            do {
                let renderer = try await Renderer(project: project, source: source, faces: faces, stills: stills)
                for (n, clip) in chosen.enumerated() where individual {
                    try Task.checkCancellation()
                    let weight = clipSeconds[n]
                    set(clip.id) { $0.state = .exporting }
                    currentRow = clip.id
                    currentLabel = "Exporting \(n + 1) of \(chosen.count): \(clip.name ?? project.slug(of: clip.id) ?? "clip")"
                    do {
                        let base = finished
                        let r = try await queue.run {
                            try await renderer.render(clip, into: dest, options: options) { f in
                                Task { @MainActor [weak self] in
                                    self?.set(clip.id) { $0.progress = f }
                                    self?.overall = (base + f * weight) / total
                                }
                            }
                        }
                        done.append(r)
                        if let context {
                            set(clip.id) { $0.state = .queued; $0.progress = 1 }
                            jobs.append((r, await finish(r, id: clip.id, supercut: false, context: context, lane: lane) { [weak self] in
                                guard let self else { return }
                                finished += weight
                                overall = finished / total
                            }))
                        } else {
                            set(clip.id) { $0.state = .done; $0.progress = 1 }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        set(clip.id) { $0.state = .failed(String(describing: error)) }
                        if context != nil { finished += weight }
                    }
                    finished += weight
                    overall = finished / total
                }
                if makeSupercut {
                    try Task.checkCancellation()
                    let weight = supercutWork
                    let slug = renderer.supercutSlug(base: packageName)
                    currentRow = nil
                    currentLabel = "Joining \(chosen.count) clips into \(renderer.baseName(slug, options)).mp4"
                    supercutState = .exporting
                    do {
                        let base = finished
                        let update: @Sendable (Double) -> Void = { f in
                            Task { @MainActor [weak self] in
                                self?.supercutProgress = f
                                self?.overall = (base + f * weight) / total
                            }
                        }
                        // Every clip exported this run: join the files. Otherwise encode it.
                        let parts = done
                        let joinable = individual && parts.count == chosen.count
                        let r = try await queue.run {
                            joinable
                                ? try await renderer.joinSupercut(parts, slug: slug, into: dest, options: options, progress: update)
                                : try await renderer.renderSupercut(chosen, slug: slug, into: dest, options: options, progress: update)
                        }
                        done.append(r)
                        if let context {
                            supercutState = .queued
                            let brandWeight = clipSeconds.reduce(0, +)
                            jobs.append((r, await finish(r, id: nil, supercut: true, context: context, lane: lane) { [weak self] in
                                guard let self else { return }
                                finished += brandWeight
                                overall = finished / total
                            }))
                        } else {
                            supercutState = .done
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        supercutState = .failed(String(describing: error))
                    }
                    finished += weight
                    overall = finished / total
                }
                currentRow = nil
                if context != nil {
                    currentLabel = "Running \(context!.command.name)…"
                    done = try await collect(jobs).done
                }
                currentLabel = ""
                var failed = rows.filter { if case .failed = $0.state { true } else { false } }.count
                if case .failed = supercutState { failed += 1 }
                phase = .finished("Exported \(done.count) file\(done.count == 1 ? "" : "s")"
                                  + (failed > 0 ? "; \(failed) failed" : "") + ".")
                if revealWhenDone, let first = done.first { NSWorkspace.shared.activateFileViewerSelecting([first.file]) }
            } catch is CancellationError {
                for i in rows.indices where [.exporting, .waiting, .queued, .finishing].contains(rows[i].state) { rows[i].state = .skipped }
                if [.exporting, .waiting, .queued, .finishing].contains(supercutState) { supercutState = .skipped }
                currentRow = nil
                currentLabel = ""
                let kept = rows.filter { $0.state == .done }.count + (supercutState == .done ? 1 : 0)
                phase = .finished("Cancelled. \(kept) file\(kept == 1 ? "" : "s") finished; nothing partial was left behind.")
            } catch {
                phase = .failed(String(describing: error))
            }
            self.lane = nil
            task = nil
            if let stills { await onStills(stills) }
            onFinish()
        }
    }

    /// Shelf ▸ Re-export (one clip) and Re-export Changed (every stale clip): straight
    /// away, with the options as they are now (resolution, framing, codec, post-export),
    /// into the folder the last export went to. No choices, no Finder window; `phase` and
    /// `overall` drive a progress sheet.
    func reexport(_ ids: [ClipID], project: Project, source: URL, package: URL?, faces: FaceTracks?, stills: TitleStills? = nil) {
        let clips = project.clips.filter { ids.contains($0.id) }
        guard !isExporting, !clips.isEmpty, let dest = destination ?? Self.lastFolder(package: package) else { return }
        destination = dest
        self.package = package
        codec = project.settings.codec
        overall = 0
        phase = .exporting
        let context = postExportContext(project, dest: dest)
        let options = Renderer.Options(codec: codec, resolution: resolution, postExport: context?.command)
        let queue = queue
        let seconds = clips.map { project.duration(of: $0) }
        let total = max(seconds.reduce(0, +) * (context == nil ? 1 : 2), 0.001)
        let lane = SerialLane()
        self.lane = lane
        task = Task {
            var exported = 0
            var failures: [String] = []
            var jobs: [Job] = []
            do {
                let renderer = try await Renderer(project: project, source: source, faces: faces, stills: stills)
                var finished = 0.0
                for (n, clip) in clips.enumerated() {
                    try Task.checkCancellation()
                    let title = clip.name ?? project.slug(of: clip.id) ?? "clip"
                    currentRow = clip.id
                    currentLabel = clips.count == 1 ? "Exporting \(title)" : "Exporting \(n + 1) of \(clips.count): \(title)"
                    let base = finished, weight = seconds[n]
                    do {
                        let r = try await queue.run {
                            try await renderer.render(clip, into: dest, options: options) { f in
                                Task { @MainActor [weak self] in self?.overall = (base + f * weight) / total }
                            }
                        }
                        if let context {
                            jobs.append((r, await finish(r, id: clip.id, supercut: false, context: context, lane: lane) { [weak self] in
                                guard let self else { return }
                                finished += weight
                                overall = finished / total
                            }))
                        } else {
                            exported += 1
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append("\(title): \(error)")
                        if context != nil { finished += weight }
                    }
                    finished += weight
                    overall = finished / total
                }
                if let context {
                    currentLabel = "Running \(context.command.name)…"
                    let (finals, failed) = try await collect(jobs)
                    exported = finals.count
                    for (staged, error) in failed {
                        let title = staged.name ?? staged.slug
                        failures.append("\(title): \(error)")
                    }
                }
                phase = failures.isEmpty
                    ? .finished("Exported \(exported) clip\(exported == 1 ? "" : "s").")
                    : .failed("\(failures.count) of \(clips.count) failed. " + failures.joined(separator: "; "))
            } catch is CancellationError {
                phase = .finished("Cancelled after \(exported) clip\(exported == 1 ? "" : "s"); nothing partial was left behind.")
            } catch {
                phase = .failed(String(describing: error))
            }
            currentRow = nil
            currentLabel = ""
            self.lane = nil
            task = nil
            if let stills { await onStills(stills) }
            onFinish()
        }
    }

    /// The folder this package last exported to (else its own exports/ folder).
    static func lastFolder(package: URL?) -> URL? {
        guard let package else { return nil }
        if let path = (UserDefaults.standard.dictionary(forKey: "exportFolders") as? [String: String])?[package.path] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return package.appendingPathComponent("exports")
    }

    private static func remember(folder: URL, package: URL?) {
        guard let package else { return }
        var all = UserDefaults.standard.dictionary(forKey: "exportFolders") as? [String: String] ?? [:]
        all[package.path] = folder.path
        UserDefaults.standard.set(all, forKey: "exportFolders")
    }

    func cancel() {
        task?.cancel()
        if let lane { Task { await lane.cancelAll() } }
    }

    func reset() { if !isExporting { phase = .choosing } }

    private func set(_ id: ClipID, _ change: (inout Row) -> Void) {
        if let i = rows.firstIndex(where: { $0.id == id }) { change(&rows[i]) }
    }
}
