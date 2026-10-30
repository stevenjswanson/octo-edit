import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    /// Asked only when the app starts (or is reopened from the Dock) with nothing to
    /// open — never when launched with a project (Finder, `open x.octoedit`) or when
    /// windows are being restored. Offer the Open panel instead of an untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Clicking the Dock icon while the panel is up asks again: bring that one forward.
        if let panel = NSApp.windows.first(where: { $0 is NSOpenPanel && $0.isVisible }) {
            panel.makeKeyAndOrderFront(nil)
            return true
        }
        DispatchQueue.main.async { NSDocumentController.shared.openDocument(nil) }
        return true
    }

    @MainActor @objc func importVideo(_ sender: Any?) {
        ImportWindowController.shared.begin()
    }
}
