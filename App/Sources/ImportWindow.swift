import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Core

/// The one Import window (File ▸ Import Video…). It lives outside any document;
/// a finished import opens the new package through the normal document path.
@MainActor
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ImportWindowController()
    let model = ImportModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Import Video"
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ImportView(model: model, controller: self))
        window.delegate = self
        model.onFinished = { [weak self] url in
            self?.close()
            // Re-importing over the open project: its window reloads the new package.
            if let open = NSDocumentController.shared.documents.first(where: {
                $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                do { try open.revert(toContentsOf: url, ofType: open.fileType ?? "edu.ucsd.octoedit.project") }
                catch { NSApp.presentError(error) }
                open.showWindows()
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func begin() {
        if !model.isRunning, model.video == nil { showWindow(nil); window?.center(); chooseVideo() }
        showWindow(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isRunning { model.cancel() }
        return true
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.message = "Choose the recording to edit"
        if let window { panel.beginSheetModal(for: window) { r in if r == .OK { self.model.video = panel.url } } }
    }

    func chooseZoom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vtt") ?? .plainText]
        panel.message = "Choose the Zoom transcript (.vtt) for this recording"
        if let dir = model.video?.deletingLastPathComponent() { panel.directoryURL = dir }
        if let window { panel.beginSheetModal(for: window) { r in if r == .OK { self.model.zoom = panel.url } } }
    }

    func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("edu.ucsd.octoedit.project") ?? .package]
        panel.message = "Where should the project be saved?"
        if let d = model.destination {
            panel.directoryURL = d.deletingLastPathComponent()
            panel.nameFieldStringValue = d.lastPathComponent
        }
        if let window { panel.beginSheetModal(for: window) { r in if r == .OK { self.model.destination = panel.url } } }
    }
}

struct ImportView: View {
    @Bindable var model: ImportModel
    // Passed in, not looked up via `.shared`: the view's first layout happens inside
    // the controller's init, and touching `.shared` there re-enters its lazy init.
    let controller: ImportWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                fileRow("Video", model.video, placeholder: "None", action: controller.chooseVideo)
                fileRow("Zoom transcript", model.zoom, placeholder: "None (no speakers)", action: controller.chooseZoom,
                        clear: model.zoom == nil ? nil : { model.zoom = nil })
                fileRow("Save as", model.destination, placeholder: "—", action: controller.chooseDestination)
                if model.destinationExists {
                    Text("A project with this name exists and will be replaced.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .disabled(model.isRunning)

            status

            HStack {
                Spacer()
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Close") { controller.close() }.keyboardShortcut(.cancelAction)
                    Button("Import") { model.start() }.keyboardShortcut(.defaultAction).disabled(!model.canStart)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .editing:
            Text("Transcribes on this Mac — about 1½ minutes per hour of video.")
                .font(.caption).foregroundStyle(.secondary)
        case .running(let stage, let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction) { Text(stage) }
                if let started = model.started {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("\(Int(ctx.date.timeIntervalSince(started))) s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func fileRow(_ label: String, _ url: URL?, placeholder: String, action: @escaping () -> Void,
                         clear: (() -> Void)? = nil) -> some View {
        LabeledContent(label) {
            HStack {
                Text(url?.lastPathComponent ?? placeholder)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(url?.path ?? "")
                Spacer()
                if let clear { Button("Clear", action: clear) }
                Button("Choose…", action: action)
            }
        }
    }
}
