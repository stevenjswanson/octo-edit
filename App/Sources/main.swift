import AppKit

// AppKit lifecycle: documents are NSDocuments (see ProjectDocument for why), views are SwiftUI.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
