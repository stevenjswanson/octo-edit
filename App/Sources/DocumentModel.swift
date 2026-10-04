import AVFoundation
import AppKit
import Observation
import Core
import Load

/// Per-window state: the project (a Core value, changed only through Core operations
/// via `perform`), load issues, selection, and the source-video player.
@MainActor @Observable
final class DocumentModel {
    private(set) var project = Project(source: "")
    private(set) var issues: [Issue] = []
    private(set) var sourceURL: URL?
    private(set) var sourceMissing = false
    var envelope: Envelope?
    /// Bumped whenever `project` changes, so views can rebuild derived state cheaply.
    private(set) var revision = 0
    /// Errors in transcript.md (from Load) make the document read-only until fixed on disk.
    private(set) var loadErrors = false

    // Selection. Word indices into `project.words`.
    var selection: ClosedRange<Int>?
    private(set) var selectedClip: ClipID?
    /// Ask the transcript to scroll a word into view (the counter makes repeats distinct).
    private(set) var reveal: (word: Int, request: Int)?
    /// A short message shown over the transcript (e.g. why an edit was refused).
    private(set) var toast: (text: String, id: Int)?

    /// Index into `project.words` of the word under the source playhead.
    private(set) var currentWord: Int?
    private(set) var isPlaying = false
    /// Either video playing: the transcript follows the playhead only then.
    var anyPlaying: Bool { isPlaying || preview.isPlayingObserved }

    enum Pane { case source, preview }
    /// The video pane Space controls. The preview unless the user deliberately turns
    /// to the source (clicks in it, plays it, or clicks a word outside every clip).
    private(set) var activePane = Pane.preview
    /// The source playhead (for the inspector's playhead line).
    private(set) var sourceTime: Double?

    // Boundary inspector (B3).
    /// The cut being inspected; the transcript shows the inspector popover for it.
    var inspected: BoundaryRef?
    /// Bumped to (re)present the inspector even when `inspected` is unchanged.
    var inspectRequest = 0
    /// Loop playback across the inspected cut.
    var loopCut = false
    var analyzingWaveform = false
    /// Source frame rate, for frame nudges and frame snapping.
    var sourceFPS: Double = 30
    /// Clips whose names are being suggested (✨ shows a spinner).
    var suggesting = Set<ClipID>()
    @ObservationIgnored var warnedAboutNamer = false
    var showingExport = false
    @ObservationIgnored let exporter = ExportModel()

    /// The word at the transcript caret (for ⌘B with no selection).
    @ObservationIgnored var caretWord: Int?
    /// The package on disk (set by the document), for writing the waveform cache.
    @ObservationIgnored var packageURL: URL?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored let preview = PreviewModel()
    @ObservationIgnored let thumbnails = Thumbnails()
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    /// Timed words sorted by start: (start, word index).
    @ObservationIgnored private var timeline: [(start: Double, index: Int)] = []
    @ObservationIgnored private var counter = 0
    /// Auto-preview cue for the edit being performed (consumed by the next preview refresh).
    @ObservationIgnored private var nextCue: PreviewModel.Cue?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.sourceTimeChanged(t.seconds) }
        }
        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            let playing = p.rate != 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = playing
                if playing {
                    self.preview.player.pause()   // one video plays at a time
                    self.activePane = .source
                }
            }
        }
        // The highlighted word follows whichever video last moved: playing or
        // scrubbing the preview moves it too (mapped back to source time).
        preview.onTime = { [weak self] t in
            self?.activePane = .preview
            self?.playheadMoved(t)
        }
        preview.onPlay = { [weak self] in
            self?.player.pause()
            self?.activePane = .preview
        }
    }

    func shutDown() {
        player.pause()
        preview.shutDown()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Loading

    func apply(_ result: PackageReader.Result) {
        issues = result.issues
        loadErrors = result.hasErrors
        envelope = result.envelope
        undoManager?.removeAllActions()
        if result.sourceURL != sourceURL || player.currentItem == nil { attachSource(result.sourceURL) }
        setProject(result.project)
        playheadMoved(player.currentTime().seconds)
        // Packages made before the cache existed (or copied without it): rebuild it.
        if envelope == nil { analyzeWaveform() }
    }

    func setSource(_ url: URL) {
        project.source = url.path
        attachSource(url)
        refreshPreview()
    }

    private func attachSource(_ url: URL) {
        sourceURL = url
        sourceMissing = !FileManager.default.fileExists(atPath: url.path)
        player.replaceCurrentItem(with: sourceMissing ? nil : AVPlayerItem(url: url))
        preview.attach(source: sourceMissing ? nil : url)
        if !sourceMissing {
            let asset = AVURLAsset(url: url)
            Task {
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                    sourceFPS = Double(fps)
                }
            }
        }
        thumbnails.attach(source: sourceMissing ? nil : url)
    }

    private func setProject(_ p: Project) {
        let wordsChanged = p.words != project.words
        project = p
        revision += 1
        if wordsChanged || timeline.isEmpty {
            timeline = p.words.indices.compactMap { i in p.words[i].start.map { ($0, i) } }.sorted { $0.start < $1.start }
        }
        if let id = selectedClip, p.clip(id) == nil { selectedClip = nil }
        if let b = inspected, p.role(of: b) == nil { inspected = nil }
        if let s = selection, s.upperBound >= p.words.count { selection = nil }
        refreshPreview()
    }

    // MARK: Editing

    var canEdit: Bool { !loadErrors }

    /// Applies a Core operation as one undoable step. Refused edits (Core throws) show
    /// a message and leave the project untouched.
    @discardableResult
    func perform(_ actionName: String, _ change: (inout Project) throws -> Void) -> Bool {
        guard canEdit else {
            nextCue = nil
            flash("transcript.md has errors — fix them in your editor first")
            return false
        }
        var p = project
        do { try change(&p) } catch {
            nextCue = nil
            flash(describe(error))
            NSSound.beep()
            return false
        }
        guard p != project else { nextCue = nil; return false }
        replace(with: p, actionName: actionName)
        nextCue = nil
        return true
    }

    private func replace(with p: Project, actionName: String) {
        let old = project, oldSelection = selection, oldClip = selectedClip
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.replace(with: old, actionName: actionName)
                model.selection = oldSelection
                if let oldClip { model.selectedClip = oldClip }
            }
        }
        undoManager?.setActionName(actionName)
        setProject(p)
        // In-app edits make Load's line-numbered issues stale; show Core's checks instead.
        issues = p.validate()
    }

    /// Core's messages, with clips named the way the user sees them.
    private func describe(_ error: Error) -> String {
        func name(_ id: ClipID) -> String {
            project.clip(id).map { "“\($0.name ?? project.slug(of: id) ?? "clip")”" } ?? "another clip"
        }
        switch error as? EditError {
        case .overlapsClip(let id): return "That would overlap clip \(name(id))."
        case .outsideClip: return "Select words inside a single clip."
        case .wouldOmitEverything: return "Omitting that would leave the clip empty — delete the clip instead."
        case .invalidRange: return "A clip can’t end before it starts."
        case .some(let e): return e.description.prefix(1).uppercased() + e.description.dropFirst() + "."
        case nil: return String(describing: error)
        }
    }

    func flash(_ text: String) {
        counter += 1
        toast = (text, counter)
        let id = counter
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast?.id == id { self?.toast = nil }
        }
    }

    // MARK: Clip commands (menu, keyboard, context menu)

    /// The clip that contains the whole selection, if any.
    var clipAroundSelection: Clip? {
        guard let s = selection, let c = project.clip(containingWordAt: s.lowerBound),
              project.clip(containingWordAt: s.upperBound)?.id == c.id else { return nil }
        return c
    }

    var canMakeClip: Bool { selection != nil && clipOverlappingSelection == nil }
    var canOmit: Bool { clipAroundSelection != nil }
    var canExtend: Bool { selection != nil && selectedClip != nil && clipAroundSelection?.id != selectedClip }

    private var clipOverlappingSelection: Clip? {
        guard let s = selection else { return nil }
        return project.clips.first { project.indexRange(of: $0)?.overlaps(s) ?? false }
    }

    func makeClip() {
        guard let s = selection else { return }
        var id: ClipID?
        if perform("New Clip", { id = try $0.makeClip(words: s) }), let id {
            selection = nil
            select(clip: id)
        }
    }

    func omitSelection() {
        guard let s = selection, let c = clipAroundSelection else { return hint() }
        previewEdit(of: c.id, cue: span(of: s).map { .around(from: $0.end, to: $0.end) })
        if !perform("Omit", { try $0.omit(words: s, in: c.id) }) { refreshPreview() }
    }

    func restoreSelection() {
        guard let s = selection, let c = clipAroundSelection else { return hint() }
        previewEdit(of: c.id, cue: span(of: s).map { .around(from: $0.start, to: $0.end) })
        if !perform("Restore", { try $0.restore(words: s, in: c.id) }) { refreshPreview() }
    }

    private func hint() {
        flash(selection == nil ? "Select some words first." : "Select words inside a single clip.")
        NSSound.beep()
    }

    func extendClip() {
        guard let s = selection, let id = selectedClip,
              let old = project.clip(id).flatMap({ project.indexRange(of: $0) }) else { return }
        // Auto preview plays the end that moved (the start if both did).
        previewEdit(of: id, cue: s.lowerBound < old.lowerBound ? .start : .end)
        if !perform("Extend Clip", { try $0.extendClip(id, toInclude: s) }) { refreshPreview() }
    }

    func deleteClip() {
        guard let id = selectedClip else { return }
        perform("Delete Clip") { try $0.deleteClip(id) }
    }

    /// Moves the selected clip's start (or end) to the word under the source playhead.
    func setBoundaryAtPlayhead(inPoint: Bool) {
        guard let id = selectedClip, let w = currentWord else {
            flash(selectedClip == nil ? "Select a clip first." : "Play or click to a word first.")
            return
        }
        moveBoundary(clip: id, inPoint: inPoint, to: w)
    }

    /// Moves a clip's start or end marker to another word. An explicit offset belonged
    /// to the old word, so it is cleared (the default pad applies again).
    func moveBoundary(clip id: ClipID, inPoint: Bool, to word: Int) {
        guard let clip = project.clip(id) else { return }
        let k = inPoint ? 0 : clip.segments.count - 1
        previewEdit(of: id, cue: inPoint ? .start : .end)
        let done = perform(inPoint ? "Move Clip Start" : "Move Clip End") {
            try $0.moveBoundary(clip: id, segment: k, inPoint: inPoint, to: word)
            try $0.setOffset(clip: id, segment: k, inPoint: inPoint, nil)
        }
        if !done { refreshPreview() }
    }

    /// Makes the edited clip the previewed one (without a separate refresh) and queues
    /// the auto-preview cue the coming edit should play.
    private func previewEdit(of id: ClipID, cue: PreviewModel.Cue?) {
        selectedClip = id
        nextCue = cue
    }

    func queuePreviewCue(_ cue: PreviewModel.Cue) { nextCue = cue }
    func refreshPreviewNow() { refreshPreview() }

    /// Source-time extent of the timed words in `r`.
    private func span(of r: ClosedRange<Int>) -> (start: Double, end: Double)? {
        let timed = r.filter { project.words[$0].isTimed }
        guard let a = timed.first, let b = timed.last else { return nil }
        return (project.words[a].start!, project.words[b].end!)
    }

    // MARK: Selection

    /// Selects a clip: it becomes the preview's clip and its band is emphasised.
    func select(clip id: ClipID?, reveal: Bool = false, seekSource: Bool = false) {
        selectedClip = id
        refreshPreview()
        guard reveal || seekSource, let id, let clip = project.clip(id), let r = project.indexRange(of: clip) else { return }
        if reveal { revealWord(r.lowerBound) }
        if seekSource, let start = project.resolvedSegments(of: clip).first?.start { seek(to: start) }
    }

    func revealWord(_ i: Int) {
        counter += 1
        reveal = (i, counter)
    }

    /// A click on a word (no drag): seek the source, select the clip it is in, and
    /// line the preview up with it when it's in the selected clip. A click during
    /// playback also stops it; returns true then (the view selects the word).
    @discardableResult
    func clicked(word i: Int) -> Bool {
        // Inside a clip the preview is lined up with the word; outside, only the source can play it.
        activePane = project.clip(containingWordAt: i) == nil ? .source : .preview
        let wasPlaying = player.rate != 0 || preview.player.rate != 0
        if wasPlaying {
            player.pause()
            preview.cancelExcerpt()
            preview.player.pause()
        }
        defer { if wasPlaying { selection = i...i } }
        seekSource(toWord: i)
        if let c = project.clip(containingWordAt: i) {
            if c.id != selectedClip { select(clip: c.id) }
            if let t = project.words[i].start { preview.seek(toSourceTime: t) }
        }
        return wasPlaying
    }

    // MARK: Playback

    func seekSource(toWord i: Int) {
        guard project.words.indices.contains(i), let t = project.words[i].start else { return }
        seek(to: t)
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playheadMoved(t)
    }

    /// The source player's time moved (playing, scrubbing, or a seek we made).
    private func sourceTimeChanged(_ t: Double) {
        sourceTime = t
        playheadMoved(t)
    }

    func focus(_ pane: Pane) { activePane = pane }

    /// Space bar: play or pause the focused video pane.
    func togglePlay() {
        switch activePane {
        case .source:
            if player.rate != 0 { player.pause() } else if player.currentItem != nil { player.play() }
        case .preview:
            preview.togglePlay()
        }
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

    private func refreshPreview() {
        let clip = selectedClip.flatMap { project.clip($0) }
        preview.show(clip: clip, in: project, cue: nextCue)
        nextCue = nil
        thumbnails.update(project)
    }
}
