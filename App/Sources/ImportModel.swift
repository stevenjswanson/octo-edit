import AppKit
import Observation
import Core
import Ingest
import Save
import Transcribe
import Waveform

/// File ▸ Import Video…: ingest → save → open, the same path as `octoedit init`.
/// Ingest's project goes straight to Save into a temporary package beside the
/// destination; only a finished save is moved into place, so a cancelled or failed
/// import leaves nothing behind (and never touches an existing package).
@MainActor @Observable
final class ImportModel {
    enum Phase: Equatable {
        case editing
        case running(stage: String, fraction: Double)
        case failed(String)
    }

    var video: URL? { didSet { if video != oldValue { videoChanged() } } }
    var zoom: URL?
    var destination: URL?
    private(set) var phase: Phase = .editing
    private(set) var started: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onFinished: (URL) -> Void = { _ in }
    @ObservationIgnored let queue: any TranscriptionQueue = PassThroughTranscriptionQueue()

    var isRunning: Bool { if case .running = phase { true } else { false } }
    var canStart: Bool { video != nil && destination != nil && !isRunning }
    var destinationExists: Bool { destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Defaults that follow the video: the package beside it, and a Zoom transcript
    /// from the same folder when one matches (Zoom names both `GMTyyyymmdd-hhmmss_…`).
    private func videoChanged() {
        guard let video else { return }
        let folder = video.deletingLastPathComponent()
        destination = folder.appendingPathComponent(video.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("octoedit")
        zoom = Self.matchingTranscript(for: video)
    }

    static func matchingTranscript(for video: URL) -> URL? {
        let folder = video.deletingLastPathComponent()
        let vtts = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "vtt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let stem = video.deletingPathExtension().lastPathComponent
        let key = stem.split(separator: "_").first.map(String.init) ?? stem
        return vtts.first { $0.lastPathComponent.hasPrefix(key) } ?? (vtts.count == 1 ? vtts[0] : nil)
    }

    /// Defaults for now (pads, crossfade, codec same as the video); they're in the
    /// project's front matter if a project ever needs different ones.
    var settings: ProjectSettings { ProjectSettings() }

    // MARK: Running

    func start() {
        guard let video, let destination, !isRunning else { return }
        let zoom = self.zoom, settings = self.settings, queue = self.queue
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).importing.octoedit")
        started = Date()
        phase = .running(stage: "Starting", fraction: 0)
        task = Task {
            do {
                try? FileManager.default.removeItem(at: temp)
                let result = try await queue.run {
                    try await Ingest(transcriber: AppleSpeechTranscriber(), analyzer: AssetEnvelopeAnalyzer())
                        .run(video: video, zoom: zoom, settings: settings) { stage, fraction in
                            Task { @MainActor [weak self] in self?.progress(stage.rawValue, fraction) }
                        }
                }
                try Task.checkCancellation()
                phase = .running(stage: "Saving", fraction: 1)
                // Ingest → Save, and nothing else.
                try PackageWriter.save(result.project, to: temp,
                                       options: .init(words: result.words, envelope: result.envelope, zoomTranscript: zoom))
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: destination)
                }
                phase = .editing
                onFinished(destination)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                phase = error is CancellationError ? .editing : .failed(Self.describe(error))
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    private func progress(_ stage: String, _ fraction: Double) {
        guard isRunning else { return }
        phase = .running(stage: stage, fraction: fraction)
    }

    private static func describe(_ error: Error) -> String {
        // Framework errors carry a localized description; our own errors describe themselves.
        type(of: error) is NSError.Type ? (error as NSError).localizedDescription : String(describing: error)
    }
}
