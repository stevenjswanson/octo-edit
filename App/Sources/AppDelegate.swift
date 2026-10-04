import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The first NSDocumentController instantiated becomes the shared one.
        _ = SingleDocumentController()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With nothing restored or opened from Finder, offer the Open panel.
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

/// v1 opens one project at a time: opening a second closes the first (after its save
/// prompt). Nothing else in the app assumes a single document, so lifting this guard
/// is the whole of turning multi-document on.
final class SingleDocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        let others = documents.filter { $0.fileURL?.standardizedFileURL != url.standardizedFileURL }
        guard let current = others.first else {
            return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
        close(current) { closed in
            if closed {
                super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            } else {
                completionHandler(nil, false, nil)
            }
        }
    }

    private final class Pending {
        let done: (Bool) -> Void
        init(_ done: @escaping (Bool) -> Void) { self.done = done }
    }

    private func close(_ document: NSDocument, then done: @escaping (Bool) -> Void) {
        let context = Unmanaged.passRetained(Pending(done)).toOpaque()
        document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: context)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let pending = Unmanaged<Pending>.fromOpaque(contextInfo!).takeRetainedValue()
        if shouldClose { document.close() }
        pending.done(shouldClose)
    }
}
