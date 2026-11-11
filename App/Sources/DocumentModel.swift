import AVFoundation
import AppKit
import Observation
import Core
import Load
import Align
import SpeakerFraming
import Render
import os

/// Play, pause, seek and pane decisions, for diagnosing playback (`log stream --predicate 'subsystem == "edu.ucsd.OctoEdit"'`).
let playbackLog = Logger(subsystem: "edu.ucsd.OctoEdit", category: "playback")

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
    /// Clips selected together in the shelf (⇧-click), for Merge: always a consecutive
    /// run that includes `selectedClip` when there is one.
    private(set) var shelfSelection: Set<ClipID> = []
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
    /// What the video pane shows (and Space controls): the selected clip's preview,
    /// or the recording itself after a click or selection outside every clip.
    private(set) var activePane = Pane.preview {
        didSet { if activePane != oldValue { playbackLog.debug("pane → \(String(describing: self.activePane))") } }
    }
    /// The source playhead (for the inspector's playhead line).
    private(set) var sourceTime: Double?

    // Transcript tools.
    /// Keep the playing word in view (off: scroll freely while a video plays).
    var followPlayhead = UserDefaults.standard.object(forKey: "followPlayhead") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followPlayhead, forKey: "followPlayhead") }
    }
    var searchText = ""
    /// Find Next / Previous requests: +1 or -1, with a counter so repeats register.
    private(set) var searchStep = (delta: 0, id: 0)
    var searchStatus = ""
    private(set) var searchFocusRequest = 0
    /// Text-edit mode: the transcript's words can be typed over; clips and timing are
    /// kept. The session is applied as one undoable change when it ends.
    private(set) var textEditing = false
    /// Supplies each paragraph's edited words when a text session ends (set by the view).
    @ObservationIgnored var textProvider: (() -> [(ParagraphID, [String])])?
    /// Ask the clip panel to focus its name field (Rename… from the shelf).
    private(set) var renameRequest = 0

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
    /// The Re-export progress sheet is up.
    var reexporting = false
    /// Face boxes through the video (cache/faces.tsv), for 9:16 framing and speaker portraits.
    var faces: FaceTracks?
    /// Finding faces in the background: progress 0…1.
    var findingFaces: Double?
    @ObservationIgnored var labelsCache: (key: Int, labels: FaceLabels)?
    /// Replace Video…: the sheet's state while it runs and when it shows its result.
    var replacing: ReplaceVideoState?
    /// Clips to look at after a Replace Video, with why (an orange dot in the shelf).
    /// A clip's mark goes when it is played in the preview. Not saved.
    var needsReview: [ClipID: String] = [:]
    /// How the speakers' faces changed in the new video (a banner, until dismissed).
    var replaceNote: String?
    /// The speakers who had a face before a Replace Video, until faces are found again.
    @ObservationIgnored var facesBeforeReplace: Set<String>?
    /// Identify Speakers… progress (0…1) while it runs.
    var identifyingSpeakers: Double?
    var showingSpeakers = false
    /// Identify Speakers… sheet: the roster to name voices from.
    var identifyRequest = false
    @ObservationIgnored let exporter = ExportModel()

    /// The word at the transcript caret (for ⌘B with no selection).
    @ObservationIgnored var caretWord: Int?
    /// The word that ends exactly at the caret, if any (so a caret just after a
    /// struck-out word still counts as on it).
    @ObservationIgnored var wordBeforeCaret: Int?
    /// The package on disk (set by the document), for writing the waveform cache.
    @ObservationIgnored var packageURL: URL? {
        didSet { if packageURL != oldValue { refreshExportStates() } }
    }
    /// Clips whose export is out of date: changed since they were exported (or, once
    /// anything has been exported, never exported under their current name), with why.
    /// Checked against the stamps in the export folder whenever the project changes.
    private(set) var needsExport: [ClipID: String] = [:]

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored let preview = PreviewModel()
    @ObservationIgnored lazy var sourceSpeed = SpeedWatcher(player)
    @ObservationIgnored lazy var previewSpeed = SpeedWatcher(preview.player)
    @ObservationIgnored let thumbnails = Thumbnails()
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    /// Timed words sorted by start: (start, word index).
    @ObservationIgnored private var timeline: [(start: Double, index: Int)] = []
    @ObservationIgnored private var counter = 0
    /// Auto-preview cue for the edit being performed (consumed by the next preview refresh).
    @ObservationIgnored private var nextCue: PreviewModel.Cue?
    /// Bumped by each word click, so a play still waiting on an earlier click's seek is dropped.
    @ObservationIgnored private var clickGeneration = 0

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.sourceTimeChanged(t.seconds) }
        }
        rateObserver = player.observe(\.rate) { [weak self] p, _ in
            let playing = p.rate != 0
            DispatchQueue.main.async {
                guard let self else { return }
                playbackLog.debug("source rate \(p.rate) status \(p.timeControlStatus.rawValue) waiting \(p.reasonForWaitingToPlay?.rawValue ?? "-")")
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
        preview.faceLabels = { [weak self] in self?.faceLabels }
        exporter.onFinish = { [weak self] in self?.refreshExportStates() }
        preview.onPlay = { [weak self] in
            self?.player.pause()
            self?.activePane = .preview
            if let id = self?.selectedClip, self?.needsReview[id] != nil { self?.needsReview[id] = nil }
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
        textEditing = false   // a reload replaces whatever was being typed
        needsReview = [:]     // clip IDs belong to the project being replaced
        issues = result.issues
        loadErrors = result.hasErrors
        envelope = result.envelope
        undoManager?.removeAllActions()
        if result.sourceURL != sourceURL || player.currentItem == nil { attachSource(result.sourceURL) }
        setProject(result.project)
        playheadMoved(player.currentTime().seconds)
        // Packages made before the cache existed (or copied without it): rebuild it.
        if envelope == nil { analyzeWaveform() }
        loadFaces()
    }

    func setSource(_ url: URL) {
        project.source = url.path
        attachSource(url)
        refreshPreview()
        refreshExportStates()
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
        shelfSelection = shelfSelection.filter { p.clip($0) != nil }
        if let id = selectedClip { shelfSelection.insert(id) }
        if let b = inspected, p.role(of: b) == nil { inspected = nil }
        if let s = selection, s.upperBound >= p.words.count { selection = nil }
        refreshPreview()
        refreshExportStates()
    }

    /// Compares each clip with its export's stamp (see `ExportStamp`).
    func refreshExportStates() {
        guard let source = sourceURL, let folder = exporter.destination ?? ExportModel.lastFolder(package: packageURL) else {
            if !needsExport.isEmpty { needsExport = [:] }
            return
        }
        let states = ExportStamp.states(project, exports: folder, sourceIdentity: ExportStamp.sourceIdentity(source))
        let anyExported = states.values.contains { $0 != .notExported }
        var out: [ClipID: String] = [:]
        for (id, state) in states where project.clip(id)?.export != false {
            switch state {
            case .current: break
            case .changed: out[id] = "Changed since it was exported"
            case .notExported where anyExported: out[id] = "Not exported under this name yet"
            case .notExported: break
            }
        }
        if out != needsExport { needsExport = out }
    }

    // MARK: Editing

    var canEdit: Bool { !loadErrors && !textEditing }

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
        case .wouldOmitEverything: return "That would leave the clip with no words — they’re all omitted (⇧⌫ restores them)."
        case .invalidRange: return "A clip’s end can’t go before its start (or its start after its end)."
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

    // MARK: Search

    func findNext() { searchStep = (1, searchStep.id + 1) }
    func findPrevious() { searchStep = (-1, searchStep.id + 1) }
    func focusSearch() { searchFocusRequest += 1 }

    // MARK: Text editing

    func beginTextEditing() {
        guard !loadErrors, !textEditing else { return }
        closeInspector()
        player.pause()
        preview.player.pause()
        textEditing = true
    }

    /// Ends the text session, applying every changed paragraph as one undo step.
    /// A paragraph emptied of words keeps the session open (with a message).
    func endTextEditing() {
        guard textEditing else { return }
        let edits = textProvider?() ?? []
        if let empty = edits.first(where: { $0.1.isEmpty }) {
            _ = empty
            flash("A paragraph can’t be left empty — put a word back (omit words to cut them).")
            NSSound.beep()
            return
        }
        let changed = edits.filter { pid, tokens in
            project.words.filter { $0.paragraph == pid }.map(\.text) != tokens
        }
        textEditing = false
        if changed.isEmpty {
            revision += 1   // put the text back exactly as the project has it
        } else {
            perform("Edit Text") { p in
                for (pid, tokens) in changed { try p.replaceText(ofParagraph: pid, with: tokens) }
            }
        }
    }

    /// ⌥⌫ in cut mode: removes words from the transcript text, exactly as deleting them
    /// in text-edit mode would (clips and omissions keep their places). Playback carries
    /// on: only the text changes, so the video doesn't.
    func deleteWords(_ r: ClosedRange<Int>) {
        guard !textEditing, r.upperBound < project.words.count else { return }
        var edits: [(ParagraphID, [String])] = []
        for i in r where edits.last?.0 != project.words[i].paragraph {
            let pid = project.words[i].paragraph
            let tokens = project.words.indices
                .filter { project.words[$0].paragraph == pid && !r.contains($0) }
                .map { project.words[$0].text }
            guard !tokens.isEmpty else {
                flash("A paragraph can’t be left empty — omit its words to cut them.")
                NSSound.beep()
                return
            }
            edits.append((pid, tokens))
        }
        selection = nil
        perform(r.count == 1 ? "Delete Word" : "Delete Words") { p in
            for (pid, tokens) in edits { try p.replaceText(ofParagraph: pid, with: tokens) }
        }
    }

    func toggleTextEditing() { textEditing ? endTextEditing() : beginTextEditing() }

    // MARK: Clip shelf

    /// A click on a shelf card: plain selects just that clip (and goes to it); ⇧ selects
    /// every clip from the current one to it, so a group never has gaps.
    func shelfClick(_ id: ClipID, shift: Bool) {
        if shift, let anchor = selectedClip,
           let a = project.clips.firstIndex(where: { $0.id == anchor }),
           let b = project.clips.firstIndex(where: { $0.id == id }) {
            shelfSelection = Set(project.clips[min(a, b)...max(a, b)].map(\.id))
            return
        }
        let wasPlaying = player.rate != 0 || preview.player.rate != 0
        player.pause()
        select(clip: id, reveal: true, seekSource: true)
        focus(.preview)
        // The preview starts from the top of the clip, even when it was already showing
        // it (selecting the same clip again doesn't rebuild it, so it wouldn't move).
        guard let clip = project.clip(id), let start = project.resolvedSegments(of: clip).first?.start else { return }
        if wasPlaying { preview.playWhenReady(.from(start)) } else { preview.seek(toSourceTime: start) }
    }

    /// The shelf selection is two or more clips with no other clip between them.
    var canMerge: Bool {
        let idx = project.clips.indices.filter { shelfSelection.contains(project.clips[$0].id) }
        return idx.count >= 2 && idx.last! - idx.first! == idx.count - 1
    }

    /// The word a split would start the second clip at: the caret's word (or the start
    /// of the word selection), when it is inside a clip and not its first word.
    private var splitPoint: (clip: ClipID, word: Int)? {
        guard let w = selection?.lowerBound ?? caretWord, let c = project.clip(containingWordAt: w),
              let r = project.indexRange(of: c), w > r.lowerBound else { return nil }
        return (c.id, w)
    }

    var canSplit: Bool { splitPoint != nil }

    /// Clip ▸ Split Clip at Caret: the second clip starts at the caret's word.
    func splitAtCaret() {
        guard let (id, w) = splitPoint else {
            flash("Put the caret inside a clip, on the word the second clip should start with.")
            NSSound.beep()
            return
        }
        if perform("Split Clip", { try $0.splitClip(id, atWord: w) }) { select(clip: id) }
    }

    /// ⌫ with a clip selected (and no words selected): delete it after confirming.
    func confirmDeleteSelectedClip(in window: NSWindow) {
        guard canEdit, let id = selectedClip, let clip = project.clip(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete clip “\(clip.name ?? project.slug(of: id) ?? "clip")”?"
        alert.informativeText = "The transcript text stays; only the clip and its cuts are removed. You can undo this with ⌘Z."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.deleteClip(id) }
        }
    }

    func mergeSelectedClips() {
        guard shelfSelection.count >= 2 else { return }
        var merged: ClipID?
        let ids = Array(shelfSelection)
        if perform("Merge Clips", { merged = try $0.mergeClips(ids) }), let merged {
            select(clip: merged, reveal: true)
        }
    }

    func requestRename(_ id: ClipID) {
        select(clip: id, reveal: true)
        renameRequest += 1
    }

    func deleteClip(_ id: ClipID) {
        perform("Delete Clip") { try $0.deleteClip(id) }
    }

    func exportClip(_ id: ClipID) {
        select(clip: id)
        showExport(onlySelected: true)
    }

    // MARK: Clip commands (menu, keyboard, context menu)

    /// The clip that contains the whole selection, if any.
    var clipAroundSelection: Clip? {
        guard let s = selection, let c = project.clip(containingWordAt: s.lowerBound),
              project.clip(containingWordAt: s.upperBound)?.id == c.id else { return nil }
        return c
    }

    var canMakeClip: Bool { selection != nil && clipOverlappingSelection == nil }
    var canOmit: Bool { selection != nil }
    var canRestore: Bool { restoreTarget != nil }

    /// What ⇧⌫ restores: the selection, or with only a caret, the whole struck-out
    /// run the caret is on.
    private var restoreTarget: ClosedRange<Int>? {
        if let s = selection { return s }
        let runs = project.omissionMap().runs()
        for w in [caretWord, wordBeforeCaret].compactMap({ $0 }) {
            if let r = runs.first(where: { $0.contains(w) }) { return r }
        }
        return nil
    }
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

    /// Omits the selected words, inside a clip or not. Outside clips they stay struck
    /// out, and a clip made over them later leaves them out. Previews only inside a clip.
    func omitSelection() {
        guard let s = selection else { return hint() }
        if let c = clipAroundSelection { previewEdit(of: c.id, cue: span(of: s).map { .around(from: $0.end, to: $0.end) }) }
        if !perform("Omit", { try $0.omit(words: s) }) { refreshPreview() }
    }

    func restoreSelection() {
        guard let s = restoreTarget else { return hint() }
        if let c = project.clip(containingWordAt: s.lowerBound), project.clip(containingWordAt: s.upperBound)?.id == c.id {
            previewEdit(of: c.id, cue: span(of: s).map { .around(from: $0.start, to: $0.end) })
        }
        if !perform("Restore", { try $0.restore(words: s) }) { refreshPreview() }
    }

    private func hint() {
        flash("Select some words first.")
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

    /// Moves a clip's start or end marker to another word, trimming or extending the
    /// clip (an omission left outside it is dropped). The moved edge's explicit offset
    /// belonged to the old word, so it is cleared (the default pad applies again).
    func moveBoundary(clip id: ClipID, inPoint: Bool, to word: Int) {
        guard project.clip(id) != nil else { return }
        previewEdit(of: id, cue: inPoint ? .start : .end)
        let done = perform(inPoint ? "Move Clip Start" : "Move Clip End") {
            try $0.moveClipEdge(id, start: inPoint, to: word)
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
    func queuePreviewCueClear() { nextCue = nil }
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
        shelfSelection = id.map { [$0] } ?? []
        if id != nil { activePane = .preview }
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
    /// line the preview up with it. Outside every clip the video pane switches to the
    /// recording at the word. Playing or paused stays as it was: during playback, the
    /// video carries on from the clicked word.
    func clicked(word i: Int) {
        clickGeneration += 1
        let generation = clickGeneration
        let wasPlaying = player.rate != 0 || preview.player.rate != 0
        let c = project.clip(containingWordAt: i)
        playbackLog.debug("click word \(i) \(c == nil ? "outside" : "in clip") playing \(wasPlaying)")
        guard let c else {
            showSource(atWord: i)
            guard wasPlaying, let t = project.words[i].start else { return }
            // Seek paused and play once it lands: seeking while playing races to catch up.
            player.pause()
            Task {
                let landed = await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard landed, clickGeneration == generation else { return playbackLog.debug("click \(generation) play dropped") }
                player.play()
            }
            return
        }
        activePane = .preview
        player.pause()
        seekSource(toWord: i)
        if c.id != selectedClip { select(clip: c.id) }
        guard let t = project.words[i].start else { return }
        if wasPlaying { preview.playWhenReady(.from(t)) } else { preview.seek(toSourceTime: t) }
    }

    /// A dragged selection that starts outside every clip shows the recording there.
    func selected(words s: ClosedRange<Int>) {
        guard project.clip(containingWordAt: s.lowerBound) == nil else { return }
        showSource(atWord: s.lowerBound)
    }

    // MARK: Playback

    /// Shows the recording in the video pane, paused at word `i`.
    func showSource(atWord i: Int) {
        preview.cancelExcerpt()
        preview.player.pause()
        activePane = .source
        seekSource(toWord: i)
    }

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
