import AppKit
import SwiftUI
import Core
import Load
import Save

/// One `.octoedit` package. An NSDocument rather than a SwiftUI FileDocument because
/// Load and Save work on the package *URL* (the source path is relative to it, and
/// words.tsv / cache/ stay in place), which FileDocument never sees.
///
/// Edits made outside the app (the text editor workflow) are picked up when the
/// package changes or the window comes forward: an unedited document reloads,
/// one with unsaved changes asks first.
final class ProjectDocument: NSDocument {
    let model = DocumentModel()
    private var transcriptStamp: FileStamp?
    private var watcher: DirectoryWatcher?
    private var asking = false

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        MainActor.assumeIsolated { model.undoManager = undoManager }
        let host = NSHostingController(rootView: DocumentView(model: model, document: self))
        let window = NSWindow(contentViewController: host)
        window.styleMask.insert(.fullSizeContentView)
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.minSize = NSSize(width: 900, height: 600)
        window.setFrameAutosaveName("OctoEditProject")
        let controller = NSWindowController(window: window)
        addWindowController(controller)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
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

    override func close() {
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

    private func checkForExternalChange() {
        guard let url = fileURL, !asking else { return }
        let stamp = FileStamp(Self.transcriptURL(url))
        guard stamp != transcriptStamp else { return }
        if !isDocumentEdited {
            reload(url)
            return
        }
        asking = true
        let alert = NSAlert()
        alert.messageText = "transcript.md was changed by another application."
        alert.informativeText = "Reload it and discard your unsaved changes here, or keep the version in OctoEdit (saving will overwrite the file)."
        alert.addButton(withTitle: "Keep OctoEdit Version")
        alert.addButton(withTitle: "Reload from Disk")
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.asking = false
            if response == .alertSecondButtonReturn { self.reload(url) } else { self.transcriptStamp = stamp }
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

    // MARK: Clip commands

    @objc func makeClip(_ sender: Any?) { MainActor.assumeIsolated { model.makeClip() } }
    @objc func extendClip(_ sender: Any?) { MainActor.assumeIsolated { model.extendClip() } }
    @objc func omitSelection(_ sender: Any?) { MainActor.assumeIsolated { model.omitSelection() } }
    @objc func restoreSelection(_ sender: Any?) { MainActor.assumeIsolated { model.restoreSelection() } }
    @objc func setClipStart(_ sender: Any?) { MainActor.assumeIsolated { model.setBoundaryAtPlayhead(inPoint: true) } }
    @objc func setClipEnd(_ sender: Any?) { MainActor.assumeIsolated { model.setBoundaryAtPlayhead(inPoint: false) } }
    @objc func deleteClip(_ sender: Any?) { MainActor.assumeIsolated { model.deleteClip() } }
    @objc func inspectCut(_ sender: Any?) { MainActor.assumeIsolated { model.inspectNearest() } }
    @objc func exportClips(_ sender: Any?) { MainActor.assumeIsolated { model.showExport() } }
    @objc func suggestNames(_ sender: Any?) {
        MainActor.assumeIsolated { if let id = model.selectedClip { model.suggestNames(for: id) } }
    }
    @objc func nameUnnamedClips(_ sender: Any?) { MainActor.assumeIsolated { model.nameUnnamedClips() } }

    @objc func togglePlayPause(_ sender: Any?) { MainActor.assumeIsolated { model.togglePlay() } }
    @objc func toggleAutoPreview(_ sender: Any?) {
        MainActor.assumeIsolated { PlaybackSettings.shared.autoPreview.toggle() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let responder = windowControllers.first?.window?.firstResponder
        let transcriptFocused = responder is WordTextView
        if item.action == #selector(togglePlayPause(_:)) {
            // Leave Space to text fields being typed in.
            if let text = responder as? NSTextView, text.isEditable, !(text is WordTextView) { return false }
            return true
        }
        if item.action == #selector(toggleAutoPreview(_:)) {
            (item as? NSMenuItem)?.state = MainActor.assumeIsolated { PlaybackSettings.shared.autoPreview } ? .on : .off
            return true
        }
        let m = model
        let enabled: Bool? = MainActor.assumeIsolated {
            switch item.action {
            case #selector(makeClip(_:)): m.canEdit && m.canMakeClip
            case #selector(extendClip(_:)): m.canEdit && m.canExtend
            case #selector(omitSelection(_:)), #selector(restoreSelection(_:)): transcriptFocused && m.canEdit && m.canOmit
            case #selector(setClipStart(_:)), #selector(setClipEnd(_:)):
                transcriptFocused && m.canEdit && m.selectedClip != nil && m.currentWord != nil
            case #selector(deleteClip(_:)): m.canEdit && m.selectedClip != nil
            case #selector(inspectCut(_:)): m.canEdit && !m.project.clips.isEmpty
            case #selector(exportClips(_:)): !m.project.clips.isEmpty && !m.loadErrors && !m.sourceMissing
            case #selector(suggestNames(_:)): m.canEdit && m.selectedClip != nil
            case #selector(nameUnnamedClips(_:)): m.canEdit && m.project.clips.contains { $0.name == nil }
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
