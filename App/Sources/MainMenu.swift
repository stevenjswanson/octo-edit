import AppKit

/// The menu bar, built in code (no nib). Items target the responder chain, so
/// NSDocument / NSDocumentController / NSTextView supply the behaviour.
enum MainMenu {
    static func build() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu()))
        bar.addItem(submenu(fileMenu()))
        bar.addItem(submenu(editMenu()))
        bar.addItem(submenu(clipMenu()))
        bar.addItem(submenu(playbackMenu()))
        let window = windowMenu()
        bar.addItem(submenu(window))
        NSApp.windowsMenu = window
        return bar
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "OctoEdit")
        m.addItem(item("About OctoEdit", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        let services = item("Services", nil)
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        m.addItem(services)
        m.addItem(.separator())
        m.addItem(item("Hide OctoEdit", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit OctoEdit", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        let importItem = item("Import Video…", #selector(AppDelegate.importVideo(_:)), "i", [.command, .shift])
        importItem.target = NSApp.delegate
        m.addItem(importItem)
        m.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        // NSDocumentController fills a submenu whose item uses clearRecentDocuments:.
        let recent = item("Open Recent", nil)
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        m.addItem(recent)
        m.addItem(.separator())
        m.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        m.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        m.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(item("Undo", Selector(("undo:")), "z"))
        m.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        m.addItem(item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f"))
        m.items.last?.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        return m
    }

    private static func clipMenu() -> NSMenu {
        let m = NSMenu(title: "Clip")
        for item in clipItems() { m.addItem(item) }
        return m
    }

    private static func playbackMenu() -> NSMenu {
        let m = NSMenu(title: "Playback")
        // Bare Space: disabled while a text field is being typed in, so it never steals spaces.
        m.addItem(item("Play/Pause", #selector(ProjectDocument.togglePlayPause(_:)), " ", []))
        m.addItem(.separator())
        m.addItem(item("Auto Preview", #selector(ProjectDocument.toggleAutoPreview(_:)), "p", [.command, .shift]))
        return m
    }

    /// Clip commands, shared by the Clip menu and the transcript's context menu. They go
    /// to the first responder (ProjectDocument handles them). The bare-key shortcuts
    /// (⌫, ⇧⌫, I, O) are enabled only while the transcript has focus, so they never
    /// steal keystrokes from a text field.
    static func clipItems() -> [NSMenuItem] {
        [
            item("New Clip from Selection", #selector(ProjectDocument.makeClip(_:)), "k"),
            item("Extend Clip to Selection", #selector(ProjectDocument.extendClip(_:)), "e"),
            .separator(),
            item("Omit Selection", #selector(ProjectDocument.omitSelection(_:)), "\u{8}", []),
            item("Restore Selection", #selector(ProjectDocument.restoreSelection(_:)), "\u{8}", .shift),
            .separator(),
            item("Set Clip Start at Playhead", #selector(ProjectDocument.setClipStart(_:)), "i", []),
            item("Set Clip End at Playhead", #selector(ProjectDocument.setClipEnd(_:)), "o", []),
            .separator(),
            item("Delete Clip", #selector(ProjectDocument.deleteClip(_:)), "\u{8}", [.command, .option]),
        ]
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }
}
