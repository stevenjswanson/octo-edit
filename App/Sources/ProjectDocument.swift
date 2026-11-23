import AppKit
import SwiftUI
import Core
import Load
import Save
import Ingest
import Transcribe
import Waveform
import Render

/// One `.octoedit` package. An NSDocument rather than a SwiftUI FileDocument because
/// Load and Save work on the package *URL* (the source path is relative to it, and
/// words.tsv / cache/ stay in place), which FileDocument never sees.
///
/// Edits made outside the app (a text editor, git, Drive sync, another AI) are noticed
/// when the package changes, when the window comes forward, and before every save:
/// the two versions' clips are shown side by side and the user loads or keeps.
final class ProjectDocument: NSDocument {
    let model = DocumentModel()
    private var transcriptStamp: FileStamp?
    private var watcher: DirectoryWatcher?
    private var asking = false
    private var autosaveTimer: Timer?
    private var replaceTask: Task<Void, Never>?

    /// Seconds after the first unsaved change before it is written to disk.
    static let autosaveDelay: TimeInterval = 10

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        MainActor.assumeIsolated { model.undoManager = undoManager }
        let host = NSHostingController(rootView: DocumentView(model: model, document: self))
        let window = NSWindow(contentViewController: host)
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.minSize = NSSize(width: 900, height: 600)
        // Each project remembers its own window frame (several can be open at once).
        if let path = fileURL?.path { window.setFrameAutosaveName("OctoEdit " + path) }
        let controller = NSWindowController(window: window)
        addWindowController(controller)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        installDeleteKey(for: window)
    }

    // MARK: Load / Save

    override func read(from url: URL, ofType typeName: String) throws {
        let result = try PackageReader.load(url)
        MainActor.assumeIsolated {
            model.packageURL = url
            model.apply(result)
        }
        transcriptStamp = FileStamp(Self.transcriptURL(url))
        startWatching(url)
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        // Last line of defence: never overwrite a change on disk nobody has reviewed
        // (every save path offers the comparison first; this catches any that don't).
        if url.standardizedFileURL == fileURL?.standardizedFileURL, changedOnDisk {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "transcript.md was changed on disk, so OctoEdit didn’t overwrite it.",
                NSLocalizedRecoverySuggestionErrorKey: "Switch away from OctoEdit and back to compare the two versions.",
            ])
        }
        let fm = FileManager.default
        if let old = fileURL, old.standardizedFileURL != url.standardizedFileURL {
            // Save As: carry words.tsv, the Zoom transcript and the cache along.
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(at: old, to: url)
        }
        var project = MainActor.assumeIsolated { model.project }
        // Absolute here; Save re-relativizes against the (possibly new) package location.
        if let source = MainActor.assumeIsolated({ model.sourceURL }) { project.source = source.path }
        try PackageWriter.save(project, to: url)
        if saveOperation != .saveToOperation { MainActor.assumeIsolated { model.packageURL = url } }
        transcriptStamp = FileStamp(Self.transcriptURL(url))
        if saveOperation != .saveToOperation { startWatching(url) }
    }

    // MARK: Autosave

    /// Every change (each one comes through the undo manager) starts a 10-second timer
    /// if none is running; when it fires, the project is saved. So while edits keep
    /// coming it saves about every 10 s, and the last edit is on disk within 10 s.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if isDocumentEdited, autosaveTimer == nil, fileURL != nil {
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveNow() }
            }
        }
    }

    private func autosaveNow() {
        autosaveTimer = nil
        guard isDocumentEdited, let url = fileURL, let type = fileType, !asking else { return }
        // Never overwrite a change made elsewhere: offer the comparison instead.
        if changedOnDisk {
            offerDiskVersion { [weak self] loaded in if !loaded { self?.autosaveNow() } }
            return
        }
        save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
            if let error {
                MainActor.assumeIsolated { self?.model.flash("Autosave failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Closing (or quitting, or opening another project) saves pending changes without
    /// asking. If transcript.md changed on disk meanwhile, the comparison comes first:
    /// load the disk version (and close), or keep OctoEdit's (save it, then close).
    override func canClose(withDelegate delegate: Any, shouldClose selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated { model.endTextEditing() }   // a text session is applied, not lost
        guard isDocumentEdited, let url = fileURL, let type = fileType else {
            return super.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: contextInfo)
        }
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        let saveAndClose = { [weak self] in
            guard let self else { return }
            self.save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
                guard let self else { return }
                if let error {
                    // Couldn't save: fall back to the standard question rather than lose work.
                    self.presentError(error)
                    self.askBeforeClosing(delegate, selector, contextInfo)
                    return
                }
                Self.reply(to: delegate, selector, document: self, shouldClose: true, contextInfo)
            }
        }
        if changedOnDisk {
            offerDiskVersion { [weak self] loaded in
                guard let self else { return }
                if loaded { Self.reply(to: delegate, selector, document: self, shouldClose: true, contextInfo) }
                else { saveAndClose() }
            }
        } else {
            saveAndClose()
        }
    }

    private func askBeforeClosing(_ delegate: Any, _ selector: Selector?, _ contextInfo: UnsafeMutableRawPointer?) {
        super.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: contextInfo)
    }

    /// Calls the `document:shouldClose:contextInfo:` callback NSDocument's API expects.
    private static func reply(to delegate: Any, _ selector: Selector?, document: NSDocument, shouldClose: Bool,
                              _ contextInfo: UnsafeMutableRawPointer?) {
        guard let selector, let target = delegate as? NSObject, let imp = target.method(for: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(imp, to: Callback.self)(target, selector, document, shouldClose, contextInfo)
    }

    override func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        watcher = nil
        MainActor.assumeIsolated { model.shutDown() }
        super.close()
    }

    static func transcriptURL(_ package: URL) -> URL { package.appendingPathComponent("transcript.md") }

    // MARK: External edits

    private func startWatching(_ url: URL) {
        watcher = DirectoryWatcher(url) { [weak self] in self?.checkForExternalChange() }
    }

    @objc private func windowDidBecomeKey(_ note: Notification) { checkForExternalChange() }

    /// transcript.md on disk differs from what OctoEdit last read or wrote.
    private var changedOnDisk: Bool {
        guard let url = fileURL else { return false }
        return FileStamp(Self.transcriptURL(url)) != transcriptStamp
    }

    private func checkForExternalChange() {
        guard changedOnDisk, !asking else { return }
        offerDiskVersion()
    }

    /// Shows OctoEdit's clips next to the version on disk and offers to load it.
    /// `then` gets true if the disk version was loaded, false if OctoEdit's was kept.
    private func offerDiskVersion(then: ((Bool) -> Void)? = nil) {
        guard let url = fileURL, !asking else { return }
        asking = true
        let stamp = FileStamp(Self.transcriptURL(url))
        let edited = isDocumentEdited
        var disk: PackageReader.Result?
        var problem: String?
        do {
            disk = try PackageReader.load(url)
            let errors = disk!.issues.filter { $0.severity == .error }.count
            if errors > 0 {
                problem = "The version on disk has \(errors) error\(errors == 1 ? "" : "s"); loaded, it opens read-only until they’re fixed."
            }
        } catch {
            problem = "The version on disk can’t be read: \(error)"
        }
        let (here, editing) = MainActor.assumeIsolated { (model.project, model.textEditing) }

        let alert = NSAlert()
        alert.messageText = "transcript.md was changed outside OctoEdit"
        var info = edited
            ? "You have unsaved changes here. Loading the version on disk discards them; keeping OctoEdit’s means its next save replaces the file on disk."
            : "OctoEdit has no unsaved changes, so loading the version on disk loses nothing."
        if editing { info += " Your text-editing session would be discarded too." }
        alert.informativeText = info
        let comparison = NSHostingView(rootView: ClipComparison(rows: ClipComparison.rows(here: here, disk: disk?.project),
                                                                diskProblem: problem))
        comparison.frame.size = comparison.fittingSize
        alert.accessoryView = comparison
        alert.addButton(withTitle: "Load Version on Disk")
        alert.addButton(withTitle: "Keep OctoEdit Version")
        if disk == nil { alert.buttons[0].isEnabled = false }

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.asking = false
            if response == .alertFirstButtonReturn {
                self.reload(url)
                then?(true)
            } else {
                // Keep: treat the disk version as seen, so the next save may replace it
                // (and NSDocument doesn't raise its own "changed by another app" alarm).
                self.transcriptStamp = stamp
                self.fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                then?(false)
            }
        }
        if let window = windowControllers.first?.window { alert.beginSheetModal(for: window, completionHandler: respond) }
        else { respond(alert.runModal()) }
    }

    private func reload(_ url: URL) {
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "edu.ucsd.octoedit.project")
        } catch {
            presentError(error)
            transcriptStamp = FileStamp(Self.transcriptURL(url))
        }
    }

    // MARK: Delete key

    private var keyMonitor: Any?

    /// ⌫ (or ⌦) with a clip selected deletes it, after confirming — wherever the focus is
    /// in this window, except where ⌫ already means something: typing in a text field,
    /// Edit Text mode, or a word selection in the transcript (⌫ omits those words).
    private func installDeleteKey(for window: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if event.keyCode == 123 || event.keyCode == 124 { return self.stepFrame(event, in: window) ? nil : event }
            guard event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            let responder = window.firstResponder
            if let text = responder as? WordTextView {
                if text.selectedRange().length > 0 { return event }
            } else if let text = responder as? NSTextView, text.isEditable {
                return event
            }
            let handled: Bool = MainActor.assumeIsolated {
                guard !self.model.textEditing, self.model.canEdit, !self.model.clipsToDelete.isEmpty else { return false }
                self.model.confirmDeleteSelectedClip(in: window)
                return true
            }
            return handled ? nil : event
        }
    }

    /// ← / → with the video paused step it one frame back or forward, unless a text
    /// view has the focus (there the arrows move the caret).
    private func stepFrame(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(window.firstResponder is NSTextView) else { return false }
        return MainActor.assumeIsolated { model.stepFrame(by: event.keyCode == 123 ? -1 : 1) }
    }

    // MARK: Clip commands

    @objc func makeClip(_ sender: Any?) { MainActor.assumeIsolated { model.makeClip() } }
    @objc func extendClip(_ sender: Any?) { MainActor.assumeIsolated { model.extendClip() } }
    @objc func omitSelection(_ sender: Any?) { MainActor.assumeIsolated { model.omitSelection() } }
    @objc func restoreSelection(_ sender: Any?) { MainActor.assumeIsolated { model.restoreSelection() } }
    @objc func setClipStart(_ sender: Any?) { MainActor.assumeIsolated { model.setBoundaryAtPlayhead(inPoint: true) } }
    @objc func setClipEnd(_ sender: Any?) { MainActor.assumeIsolated { model.setBoundaryAtPlayhead(inPoint: false) } }
    @objc func deleteClip(_ sender: Any?) { MainActor.assumeIsolated { model.deleteClip() } }
    @objc func mergeClips(_ sender: Any?) { MainActor.assumeIsolated { model.mergeSelectedClips() } }
    @objc func splitClip(_ sender: Any?) { MainActor.assumeIsolated { model.splitAtCaret() } }
    @objc func inspectCut(_ sender: Any?) { MainActor.assumeIsolated { model.inspectNearest() } }
    @objc func exportClips(_ sender: Any?) { MainActor.assumeIsolated { model.showExport() } }
    @objc func suggestNames(_ sender: Any?) {
        MainActor.assumeIsolated { if let id = model.selectedClip { model.suggestNames(for: id) } }
    }
    @objc func nameUnnamedClips(_ sender: Any?) { MainActor.assumeIsolated { model.nameUnnamedClips() } }

    @objc func showSpeakers(_ sender: Any?) { MainActor.assumeIsolated { model.showingSpeakers = true } }
    @objc func identifySpeakers(_ sender: Any?) { MainActor.assumeIsolated { model.identifyRequest = true } }
    @objc func setFraming(_ sender: Any?) {
        let framing: Framing = (sender as? NSMenuItem)?.tag == 1 ? .portrait : .source
        MainActor.assumeIsolated { model.setFraming(framing) }
    }
    @objc func findFaces(_ sender: Any?) { MainActor.assumeIsolated { model.findFaces() } }
    @objc func findInTranscript(_ sender: Any?) { MainActor.assumeIsolated { model.focusSearch() } }
    @objc func findNext(_ sender: Any?) { MainActor.assumeIsolated { model.findNext() } }
    @objc func findPrevious(_ sender: Any?) { MainActor.assumeIsolated { model.findPrevious() } }
    @objc func toggleTextEditing(_ sender: Any?) { MainActor.assumeIsolated { model.toggleTextEditing() } }

    /// ⌘S during a text session applies the session first, so what's saved is what you see.
    /// ⌘S: if transcript.md changed on disk, compare first (and save only if OctoEdit's
    /// version is kept).
    override func save(_ sender: Any?) {
        MainActor.assumeIsolated { model.endTextEditing() }
        if changedOnDisk {
            offerDiskVersion { [weak self] loaded in if !loaded { self?.saveNow(sender) } }
        } else {
            super.save(sender)
        }
    }

    private func saveNow(_ sender: Any?) { super.save(sender) }

    @objc func togglePlayPause(_ sender: Any?) { MainActor.assumeIsolated { model.togglePlay() } }
    @objc func toggleAutoPreview(_ sender: Any?) {
        MainActor.assumeIsolated { model.settings.autoPreview.toggle() }
    }
    @objc func togglePortraitPreview(_ sender: Any?) {
        MainActor.assumeIsolated { model.portraitPreview.toggle() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let responder = windowControllers.first?.window?.firstResponder
        let transcriptFocused = responder is WordTextView
        if item.action == #selector(togglePlayPause(_:)) {
            // Leave Space to text fields being typed in.
            if let text = responder as? NSTextView, text.isEditable, !(text is WordTextView) { return false }
            // In Edit Text mode Space types a space.
            if responder is WordTextView, MainActor.assumeIsolated({ model.textEditing }) { return false }
            return true
        }
        if item.action == #selector(toggleTextEditing(_:)) {
            let on = MainActor.assumeIsolated { model.textEditing }
            (item as? NSMenuItem)?.state = on ? .on : .off
            return !MainActor.assumeIsolated { model.loadErrors }
        }
        if [#selector(findInTranscript(_:)), #selector(findNext(_:)), #selector(findPrevious(_:))].contains(item.action) {
            return true
        }
        if item.action == #selector(toggleAutoPreview(_:)) {
            (item as? NSMenuItem)?.state = MainActor.assumeIsolated { model.settings.autoPreview } ? .on : .off
            return true
        }
        if item.action == #selector(togglePortraitPreview(_:)) {
            (item as? NSMenuItem)?.state = MainActor.assumeIsolated { model.settings.portraitPreview } ? .on : .off
            return true
        }
        let m = model
        if item.action == #selector(setFraming(_:)), let menuItem = item as? NSMenuItem {
            return MainActor.assumeIsolated {
                menuItem.state = (m.project.settings.framing == .portrait) == (menuItem.tag == 1) ? .on : .off
                return m.canEdit
            }
        }
        if item.action == #selector(deleteClip(_:)), let menuItem = item as? NSMenuItem {
            menuItem.title = MainActor.assumeIsolated { m.deleteClipsTitle }
        }
        let enabled: Bool? = MainActor.assumeIsolated {
            switch item.action {
            case #selector(makeClip(_:)): m.canEdit && m.canMakeClip
            case #selector(extendClip(_:)): m.canEdit && m.canExtend
            case #selector(omitSelection(_:)): transcriptFocused && m.canEdit && m.canOmit
            case #selector(restoreSelection(_:)): transcriptFocused && m.canEdit && m.canRestore
            case #selector(setClipStart(_:)), #selector(setClipEnd(_:)):
                transcriptFocused && m.canEdit && m.selectedClip != nil && m.currentWord != nil
            case #selector(deleteClip(_:)): m.canEdit && !m.clipsToDelete.isEmpty
            case #selector(mergeClips(_:)): m.canEdit && m.canMerge
            case #selector(splitClip(_:)): m.canEdit && m.canSplit
            case #selector(inspectCut(_:)): m.canEdit && !m.project.clips.isEmpty
            case #selector(exportClips(_:)): !m.project.clips.isEmpty && !m.loadErrors && !m.sourceMissing
            case #selector(suggestNames(_:)): m.canEdit && m.selectedClip != nil
            case #selector(nameUnnamedClips(_:)): m.canEdit && m.project.clips.contains { $0.name == nil }
            case #selector(showSpeakers(_:)): true
            case #selector(identifySpeakers(_:)): m.canEdit && m.identifyingSpeakers == nil && !m.sourceMissing
            case #selector(findFaces(_:)): m.findingFaces == nil && !m.sourceMissing
            // Not while a scan of the old video is running: it would finish into the new one's caches.
            case #selector(replaceVideo(_:)):
                m.canEdit && m.replacing == nil && m.findingFaces == nil && m.identifyingSpeakers == nil && !m.analyzingWaveform
            default: nil
            }
        }
        return enabled ?? super.validateUserInterfaceItem(item)
    }

    // MARK: Source video

    /// Asks for the input video when the stored path no longer resolves; the new path
    /// is written on the next save.
    func locateSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.message = "Locate the input video for this project"
        guard let window = windowControllers.first?.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self.model.setSource(url) }
            self.updateChangeCount(.changeDone)
        }
    }

    // MARK: Replace Video

    /// File ▸ Replace Video…: use another video of the same recording (e.g. the
    /// high-resolution original), which may start earlier or later. The same steps as
    /// `octoedit replace-video`: transcribe the new video, save the project (unsaved
    /// edits included) with the new words.tsv, and load it again so Load re-times the
    /// transcript against it.
    @objc func replaceVideo(_ sender: Any?) {
        guard let window = windowControllers.first?.window, let package = fileURL else { return }
        MainActor.assumeIsolated { model.endTextEditing() }
        if changedOnDisk { offerDiskVersion(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.message = "Choose the video to use from now on. OctoEdit transcribes it and finds your clips in it."
        panel.prompt = "Replace"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self.runReplaceVideo(url, package: package) }
        }
    }

    func cancelReplaceVideo() { replaceTask?.cancel() }

    @MainActor private func runReplaceVideo(_ video: URL, package: URL) {
        let model = self.model
        let before = model.project
        let oldURL = model.sourceMissing ? nil : model.sourceURL
        let oldName = model.sourceURL?.lastPathComponent ?? "the old video"
        let facesBefore = Set(model.faceLabels?.tracks.compactMap(\.speaker) ?? [])
        let oldEnvelope = model.envelope
        // The package's own copy of the Zoom transcript, so the new words read as the old ones did.
        let zoom = before.zoom.map { package.appendingPathComponent($0.file) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        model.replacing = .running(stage: "Starting", fraction: 0)
        replaceTask = Task { @MainActor [weak self] in
            defer { self?.replaceTask = nil }
            do {
                let newInfo = try await SourceInfo.read(video)
                var oldInfo: SourceInfo?
                if let oldURL { oldInfo = try? await SourceInfo.read(oldURL) }
                let result = try await Ingest(transcriber: AppleSpeechTranscriber(), analyzer: AssetEnvelopeAnalyzer())
                    .run(video: video, zoom: zoom, settings: before.settings) { stage, fraction in
                        Task { @MainActor in
                            if case .running = model.replacing { model.replacing = .running(stage: stage.rawValue, fraction: fraction) }
                        }
                    }
                try Task.checkCancellation()
                guard let self else { return }
                model.replacing = .running(stage: "Saving", fraction: 1)
                let oldWords = try PackageReader.loadWords(package)
                let retiming = ReplaceCheck.retiming(old: oldWords, new: result.words, oldEnvelope: oldEnvelope, newEnvelope: result.envelope)
                let project = ReplaceCheck.retarget(before, to: result.project, retiming: retiming)
                // Our own write is not an outside change to ask about.
                self.asking = true
                defer { self.asking = false }
                try PackageWriter.saveReplacingVideo(project, words: retiming.words, envelope: result.envelope, to: package)
                // Load re-times the text against the new words.tsv; saving that writes the paragraph times to match.
                try PackageWriter.save(try PackageReader.load(package).project, to: package)
                model.faces = nil
                model.replaceNote = nil
                model.facesBeforeReplace = facesBefore.isEmpty ? nil : facesBefore
                try self.revert(toContentsOf: package, ofType: self.fileType ?? "edu.ucsd.octoedit.project")
                let changes = ReplaceCheck.clips(before: before, after: model.project, duration: newInfo.duration)
                model.videoReplaced(changes)
                func size(_ info: SourceInfo?) -> String { info.map { " \($0.width)×\($0.height)" } ?? "" }
                model.replacing = .done(ReplaceVideoResult(before: oldName + size(oldInfo), after: video.lastPathComponent + size(newInfo),
                                                           shift: retiming.summary, changes: changes))
            } catch is CancellationError {
                model.replacing = nil
            } catch {
                model.replacing = .failed(type(of: error) is NSError.Type ? (error as NSError).localizedDescription : String(describing: error))
            }
        }
    }
}

/// Modification date + size: enough to tell our own last write from someone else's.
struct FileStamp: Equatable {
    let modified: Date
    let size: Int
    init?(_ url: URL) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let d = a[.modificationDate] as? Date, let s = a[.size] as? Int else { return nil }
        modified = d
        size = s
    }
}

/// Fires when entries in a directory are added, removed or renamed — which is how
/// text editors save (write a temp file, rename it over the original). In-place
/// writes are caught by the window-became-key check instead.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(_ url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { source = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        var pending = false
        s.setEventHandler {
            // Editors often touch the directory several times per save; coalesce.
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pending = false; onChange() }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    deinit { source?.cancel() }
}
