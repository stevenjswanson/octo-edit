import AVFoundation
import Observation
import Core
import Render
import SpeakerFraming

/// The clip preview: plays the selected clip's composition — built by Render's
/// CompositionBuilder, the same code export uses, so preview and export can't differ.
@MainActor @Observable
final class PreviewModel {
    private(set) var clipID: ClipID?
    private(set) var title = ""
    /// Kept segments as (clip-time start, duration), for the segment strip.
    private(set) var segments: [(start: Double, duration: Double)] = []
    private(set) var duration: Double = 0
    private(set) var message: String?
    private(set) var building = false
    /// The preview playhead as a source time (for the inspector's playhead line).
    private(set) var position: Double?
    /// Whether the preview is playing, observable by views (the play/pause button).
    private(set) var isPlayingObserved = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var asset: AVURLAsset?
    @ObservationIgnored private var sourceDuration: Double?
    @ObservationIgnored private var built: CompositionBuilder.Output?
    @ObservationIgnored private var shownSegments: [ResolvedSegment] = []
    @ObservationIgnored private var shownColumn: ColumnPath?
    @ObservationIgnored private var shownLevels = false
    /// The 9:16 column the preview is cropped to, if any.
    var column: ColumnPath? { shownColumn }
    /// Whose face is where, for the 9:16 column (nil: a centred column).
    @ObservationIgnored var faceLabels: () -> FaceLabels? = { nil }
    /// The source frame's width ÷ height.
    @ObservationIgnored private var aspect = 16.0 / 9.0
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    /// Seeks the app makes itself (loading a clip, lining up with a click) are not the
    /// user moving the preview, so they don't move the transcript highlight.
    @ObservationIgnored private var programmaticSeeks = 0
    /// Pauses an auto-preview excerpt at its end.
    @ObservationIgnored private var stopObserver: Any?
    @ObservationIgnored private var readyCue: Cue?
    /// Bumped whenever an excerpt is cancelled, so a loop restart already on its way
    /// (seek back, then play) can tell it has been superseded.
    @ObservationIgnored private var excerptGeneration = 0

    /// What auto preview plays once the rebuilt clip is ready. Source times, so they
    /// survive the rebuild; resolved against the new composition.
    enum Cue {
        case start                                    // the first few seconds
        case end                                      // the last few seconds
        case around(from: Double, to: Double)         // a changed source span, ± the length
        case loop(around: Double, half: Double)       // repeat ±half around a source-time cut
        case once(around: Double, half: Double)       // play ±half around a source-time cut, once
        case from(Double)                             // play on from a source time (a click during playback)
    }

    /// The user played or scrubbed the preview: its position as a source time.
    @ObservationIgnored var onTime: (Double) -> Void = { _ in }
    /// The preview started playing.
    @ObservationIgnored var onPlay: () -> Void = {}

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.built != nil, let source = self.sourceTime(forClip: t.seconds) else { return }
                let last = self.position
                self.position = source
                guard self.programmaticSeeks == 0 else { return }
                // Paused, the observer also fires as playback stops (the time barely
                // moves); only a real jump is the user scrubbing.
                if self.player.rate == 0, let last, abs(source - last) < 0.1 { return }
                self.onTime(source)
            }
        }
        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            let playing = p.rate != 0
            DispatchQueue.main.async {
                guard let self else { return }
                playbackLog.debug("preview rate \(p.rate) status \(p.timeControlStatus.rawValue) waiting \(p.reasonForWaitingToPlay?.rawValue ?? "-")")
                self.isPlayingObserved = playing
                guard playing else { return }
                self.onPlay()
                // Play at the end of the clip (the player's own button): from the start again.
                if self.duration > 0, self.player.currentTime().seconds >= self.duration - 0.05 {
                    Task { await self.player.seek(to: .zero); self.player.play() }
                }
            }
        }
    }

    func attach(source: URL?) {
        asset = source.map { AVURLAsset(url: $0) }
        sourceDuration = nil
        shownSegments = []
        if let asset {
            Task { sourceDuration = try? await asset.load(.duration).seconds }
            Task {
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (size, transform) = try? await (track.load(.naturalSize), track.load(.preferredTransform)) {
                    let shown = size.applying(transform)
                    if shown.height != 0 { aspect = abs(shown.width / shown.height) }
                }
            }
        }
    }

    func shutDown() {
        job?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// Shows `clip` (or nothing). Rebuilds the composition only when the clip's
    /// resolved segments or crossfade actually changed.
    func show(clip: Clip?, in project: Project, cue: Cue? = nil) {
        guard let clip, let asset else {
            clear(message: clip == nil ? "Select a clip to preview it." : "The input video is missing.")
            return
        }
        title = clip.name ?? project.slug(of: clip.id) ?? "Clip"
        let segs = project.resolvedSegments(of: clip, sourceDuration: sourceDuration)
        guard !segs.isEmpty else { clear(message: "This clip has no timed words."); clipID = clip.id; return }
        // With 9:16 preview on, it plays the cropped column, exactly as a 9:16 export.
        let column = PlaybackSettings.shared.portraitPreview
            ? ColumnPath(segments: segs.map { ($0.start, $0.end) }, timeline: SpeechTimeline(project),
                         labels: faceLabels(), aspect: aspect)
            : nil
        let sameClip = clip.id == clipID
        guard !sameClip || segs != shownSegments || column != shownColumn || clip.autoLevels != shownLevels else { return }
        // Same clip edited: stay at the same moment of the recording (not the same clip
        // time, which shifts when material before it is cut).
        let wasPlaying = player.rate != 0
        let keepSource = sameClip ? sourceTime(forClip: player.currentTime().seconds) : nil
        let keepTime = sameClip ? player.currentTime().seconds : 0
        // Auto preview never interrupts playback; inspector cues always (re)start.
        let cue: Cue? = switch cue {
        case .loop, .once: cue
        default: wasPlaying ? nil : cue
        }
        cancelExcerpt()
        // A stop (e.g. closing the inspector) while this rebuild runs cancels its cue.
        let cueGeneration = excerptGeneration
        if wasPlaying { player.pause() }
        clipID = clip.id
        shownSegments = segs
        shownColumn = column
        shownLevels = clip.autoLevels
        message = nil
        // Seeks that arrive before the new composition exists wait for it.
        if !sameClip { built = nil }
        building = true
        job?.cancel()
        let crossfade = project.settings.crossfade
        job = Task {
            do {
                let levels = clip.autoLevels ? try await AutoLevels.measure(asset, segments: segs) : nil
                try Task.checkCancellation()
                let out = try await CompositionBuilder.build(asset: asset, segments: segs, crossfade: crossfade, column: column,
                                                             levels: Array(repeating: levels, count: segs.count))
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: out.composition)
                item.audioMix = out.audioMix
                item.videoComposition = out.videoComposition
                built = out
                player.replaceCurrentItem(with: item)
                segments = zip(out.segmentStarts, out.sourceRanges).map { ($0, $1.duration) }
                duration = out.sourceRanges.reduce(0) { $0 + $1.duration }
                building = false
                let target: Double
                if let p = pendingSeek, let t = clipTime(forSource: p) {
                    target = t
                } else if let src = keepSource {
                    // If that moment was just cut, carry on right after the cut.
                    target = clipTime(atOrAfterSource: src) ?? duration
                } else {
                    target = min(keepTime, max(duration - 0.05, 0))
                }
                pendingSeek = nil
                let cue = excerptGeneration == cueGeneration ? (readyCue ?? cue) : nil
                readyCue = nil
                if let cue, cue.playsWithoutAutoPreview {
                    await playExcerpt(cue)
                } else if let cue, PlaybackSettings.shared.autoPreview {
                    await playExcerpt(cue)
                } else {
                    await quietSeek(min(target, max(duration - 0.02, 0)))
                    if wasPlaying && excerptGeneration == cueGeneration { player.play() }
                }
            } catch is CancellationError {
            } catch {
                clear(message: "Can’t build the preview: \(error)")
            }
        }
    }

    private func clear(message: String) {
        job?.cancel()
        cancelExcerpt()
        clipID = nil
        built = nil
        shownSegments = []
        segments = []
        duration = 0
        building = false
        title = ""
        self.message = message
        player.replaceCurrentItem(with: nil)
    }

    /// Lines the preview up with a source-time position, if the clip keeps it.
    func seek(toSourceTime t: Double) {
        guard built != nil else { pendingSeek = t; return }
        guard let c = clipTime(forSource: t) else { return }
        Task { await quietSeek(c) }
    }

    private func quietSeek(_ t: Double) async {
        programmaticSeeks += 1
        await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        // Let the observer's callback for this jump arrive before listening again.
        try? await Task.sleep(nanoseconds: 100_000_000)
        programmaticSeeks -= 1
    }

    /// Clip time of source time `t`, or of the next kept moment after it when `t` was cut.
    func clipTime(atOrAfterSource t: Double) -> Double? {
        guard let built else { return nil }
        for (start, range) in zip(built.segmentStarts, built.sourceRanges) where range.end > t {
            return start + max(t - range.start, 0)
        }
        return nil
    }

    // MARK: Auto preview

    /// Pause/resume without dropping a loop (the loop's observer stays registered).
    func pauseOrResume() {
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    var isPlaying: Bool { player.rate != 0 }

    /// Plays a cue now on the current composition (e.g. starting the inspector's loop).
    func play(_ cue: Cue) {
        guard built != nil else { return }
        Task { await playExcerpt(cue) }
    }

    private func playExcerpt(_ cue: Cue) async {
        cancelExcerpt()
        let generation = excerptGeneration
        playbackLog.debug("preview excerpt \(String(describing: cue)) generation \(generation)")
        // Seek paused, then play: seeking while playing races to catch up.
        player.pause()
        let length = PlaybackSettings.shared.autoPreviewLength
        let (from, to): (Double, Double)
        var loops = false
        switch cue {
        case .loop(let t, let half):
            let c = clipTime(atOrAfterSource: t) ?? duration
            (from, to) = (c - half, c + half)
            loops = true
        case .once(let t, let half):
            let c = clipTime(atOrAfterSource: t) ?? duration
            (from, to) = (c - half, c + half)
        case .start:
            (from, to) = (0, length)
        case .end:
            (from, to) = (duration - length, duration)
        case .from(let t):
            (from, to) = (clipTime(atOrAfterSource: t) ?? duration, duration)
        case .around(let a, let b):
            let ca = clipTime(atOrAfterSource: a) ?? duration
            let cb = clipTime(atOrAfterSource: b) ?? duration
            (from, to) = (ca - length, max(cb, ca) + length)
        }
        let start = min(max(from, 0), max(duration - 0.05, 0))
        let stop = min(max(to, start + 0.1), duration)
        await quietSeek(start)
        // Superseded during the seek (another click, the source took over): stay put.
        guard excerptGeneration == generation else { return playbackLog.debug("preview excerpt \(generation) superseded") }
        if loops {
            // At the end of the span (or the clip), jump back and keep going.
            let end = min(stop, duration - 0.03)
            stopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
                                                          queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.excerptGeneration == generation else { return }
                    Task {
                        await self.quietSeek(start)
                        guard self.excerptGeneration == generation else { return }
                        self.player.play()
                    }
                }
            }
        } else if stop < duration - 0.01 {
            stopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: stop, preferredTimescale: 600))],
                                                          queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.player.pause()
                    self?.cancelExcerpt()
                }
            }
        }
        player.play()
    }

    var hasActiveExcerpt: Bool { stopObserver != nil }

    /// Plays a cue once the composition being built is ready (or now, if it is).
    func playWhenReady(_ cue: Cue) {
        if built != nil && !building { play(cue) } else { readyCue = cue }
    }

    /// Stops waiting to pause an excerpt (the user took over, or the clip changed).
    func cancelExcerpt() {
        excerptGeneration += 1
        if let stopObserver { player.removeTimeObserver(stopObserver) }
        stopObserver = nil
    }

    /// Stops any excerpt or loop for good: nothing playing, nothing queued to play once
    /// a composition finishes building.
    func stopExcerpts() {
        cancelExcerpt()
        readyCue = nil
        player.pause()
    }

    /// Space bar / Play-Pause: from the start again when at the end.
    func togglePlay() {
        cancelExcerpt()
        guard player.currentItem != nil else { return }
        if player.rate != 0 { player.pause(); return }
        if player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
        player.play()
    }

    /// Clip time → source time (the inverse of `clipTime(forSource:)`).
    func sourceTime(forClip t: Double) -> Double? {
        guard let built, !built.sourceRanges.isEmpty else { return nil }
        var k = 0
        while k + 1 < built.segmentStarts.count, built.segmentStarts[k + 1] <= t { k += 1 }
        let r = built.sourceRanges[k]
        return min(r.start + max(t - built.segmentStarts[k], 0), r.end)
    }

    private func clipTime(forSource t: Double) -> Double? {
        guard let built else { return nil }
        for (start, range) in zip(built.segmentStarts, built.sourceRanges) where range.start - 0.001 <= t && t < range.end {
            return start + (t - range.start)
        }
        return nil
    }
}

extension PreviewModel.Cue {
    /// Asked for directly (the inspector, a click), not an auto preview.
    var playsWithoutAutoPreview: Bool {
        switch self {
        case .loop, .once, .from: true
        default: false
        }
    }
}
