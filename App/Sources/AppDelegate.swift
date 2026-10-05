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
        DispatchQueue.main.async { NSDocumentController.shared.openDocument(nil) }
        return true
    }

    @MainActor @objc func importVideo(_ sender: Any?) {
        ImportWindowController.shared.begin()
    }
}
