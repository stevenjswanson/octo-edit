import AppKit
import Observation
import Core
import Render

/// The Export sheet's state. Exports the project as it is in the window (unsaved edits
/// included) through Render — the same code as `octoedit render` — one clip at a time:
/// `<slug>-4k.mp4` + `.vtt` captions + `.md` notes per clip; the supercut is joined from
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
        enum State: Equatable { case waiting, exporting, done, failed(String), skipped }
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
    @ObservationIgnored let queue: any ExportQueue = PassThroughExportQueue()

    var isExporting: Bool { phase == .exporting }
    var includedCount: Int { rows.filter(\.include).count }
    var totalDuration: Double { rows.filter(\.include).reduce(0) { $0 + $1.duration } }

    /// Fills the sheet from the project; `selected` (if any) starts as the only checked clip
    /// when `onlySelected` is set.
    func prepare(project: Project, package: URL?, source: URL?, selected: ClipID?, onlySelected: Bool) {
        guard !isExporting else { return }
        let slugs = project.slugs()
        rows = project.clips.map { c in
            Row(id: c.id, include: !onlySelected || c.id == selected, title: c.name ?? "Unnamed",
                slug: slugs[c.id] ?? "", duration: project.duration(of: c))
        }
        codec = project.settings.codec
        if destination == nil { destination = package?.appendingPathComponent("exports") }
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

    func start(project: Project, source: URL, packageName: String) {
        guard let dest = destination, !isExporting, canExport else { return }
        let chosen = project.clips.filter { c in rows.contains { $0.id == c.id && $0.include } }
        guard !chosen.isEmpty else { return }
        let individual = individualClips, makeSupercut = supercut
        // Work, in seconds of output, for the overall bar.
        let clipSeconds = chosen.map { project.duration(of: $0) }
        // Joining finished clips is nearly free; only a supercut encoded from the source
        // (no individual clips) costs as much as the clips themselves.
        let supercutWork = makeSupercut ? (individual ? clipSeconds.reduce(0, +) * 0.05 : clipSeconds.reduce(0, +)) : 0
        let total = max((individual ? clipSeconds.reduce(0, +) : 0) + supercutWork, 0.001)
        var finished = 0.0
        overall = 0
        supercutState = makeSupercut ? .waiting : .skipped
        supercutProgress = 0
        for i in rows.indices {
            rows[i].progress = 0
            rows[i].state = rows[i].include && individual ? .waiting : .skipped
        }
        phase = .exporting
        let options = Renderer.Options(codec: codec, resolution: resolution)
        let queue = queue
        task = Task {
            var done: [Renderer.Rendered] = []
            do {
                let renderer = try await Renderer(project: project, source: source)
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
                        set(clip.id) { $0.state = .done; $0.progress = 1 }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        set(clip.id) { $0.state = .failed(String(describing: error)) }
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
                        supercutState = .done
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        supercutState = .failed(String(describing: error))
                    }
                    finished += weight
                    overall = finished / total
                }
                currentRow = nil
                currentLabel = ""
                var failed = rows.filter { if case .failed = $0.state { true } else { false } }.count
                if case .failed = supercutState { failed += 1 }
                phase = .finished("Exported \(done.count) file\(done.count == 1 ? "" : "s")"
                                  + (failed > 0 ? "; \(failed) failed" : "") + ".")
                if revealWhenDone, let first = done.first { NSWorkspace.shared.activateFileViewerSelecting([first.file]) }
            } catch is CancellationError {
                for i in rows.indices where rows[i].state == .exporting || rows[i].state == .waiting { rows[i].state = .skipped }
                if supercutState == .exporting || supercutState == .waiting { supercutState = .skipped }
                currentRow = nil
                currentLabel = ""
                phase = .finished("Cancelled. \(done.count) file\(done.count == 1 ? "" : "s") finished; nothing partial was left behind.")
            } catch {
                phase = .failed(String(describing: error))
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func reset() { if !isExporting { phase = .choosing } }

    private func set(_ id: ClipID, _ change: (inout Row) -> Void) {
        if let i = rows.firstIndex(where: { $0.id == id }) { change(&rows[i]) }
    }
}
