import AVFoundation
import Observation
import Core
import Load

/// Per-window state: the project (a Core value; the app mutates it only through Core
/// operations), load issues, and the source-video player.
@MainActor @Observable
final class DocumentModel {
    private(set) var project = Project(source: "")
    private(set) var issues: [Issue] = []
    private(set) var sourceURL: URL?
    private(set) var sourceMissing = false
    private(set) var envelope: Envelope?
    /// Bumped whenever `project` is replaced, so views can rebuild derived state cheaply.
    private(set) var revision = 0

    /// Index into `project.words` of the word under the source playhead.
    private(set) var currentWord: Int?
    private(set) var isPlaying = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    /// Timed words sorted by start: (start, word index).
    @ObservationIgnored private var timeline: [(start: Double, index: Int)] = []

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.playheadMoved(t.seconds) }
        }
        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            let playing = p.rate != 0
            DispatchQueue.main.async { self?.isPlaying = playing }
        }
    }

    func shutDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Loading

    func apply(_ result: PackageReader.Result) {
        project = result.project
        issues = result.issues
        envelope = result.envelope
        timeline = project.words.indices.compactMap { i in project.words[i].start.map { ($0, i) } }.sorted { $0.start < $1.start }
        revision += 1
        if result.sourceURL != sourceURL || player.currentItem == nil { attachSource(result.sourceURL) }
        playheadMoved(player.currentTime().seconds)
    }

    func setSource(_ url: URL) {
        project.source = url.path
        attachSource(url)
    }

    private func attachSource(_ url: URL) {
        sourceURL = url
        sourceMissing = !FileManager.default.fileExists(atPath: url.path)
        player.replaceCurrentItem(with: sourceMissing ? nil : AVPlayerItem(url: url))
    }

    var hasErrors: Bool { issues.contains { $0.severity == .error } }

    // MARK: Playback

    func seek(toWord i: Int) {
        guard project.words.indices.contains(i), let t = project.words[i].start else { return }
        seek(to: t)
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadMoved(t)
    }

    private func playheadMoved(_ t: Double) {
        guard t.isFinite else { return }
        // Last word starting at or before t.
        var lo = 0, hi = timeline.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timeline[mid].start <= t + 0.001 { lo = mid + 1 } else { hi = mid }
        }
        let w = lo > 0 ? timeline[lo - 1].index : nil
        if w != currentWord { currentWord = w }
    }
}
