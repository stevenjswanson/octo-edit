import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Whether this player is the one on screen. The video pane stacks the recording
    /// and the clip preview and hides one; the hidden one must not take keyboard focus
    /// or clicks, or it would report focus and switch the pane to itself.
    var isShown = true
    /// Called when the user clicks in the view or it takes keyboard focus.
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> AVPlayerView {
        let view = FocusReportingPlayerView()
        view.onFocus = onFocus
        view.isShown = isShown
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.allowsMagnification = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        guard let view = view as? FocusReportingPlayerView else { return }
        view.onFocus = onFocus
        view.isShown = isShown
    }
}

final class FocusReportingPlayerView: AVPlayerView {
    var onFocus: () -> Void = {}
    var isShown = true {
        didSet {
            // Hidden while focused: hand focus back to the window so keys (Space) go
            // through the responder chain to whichever pane is showing.
            if !isShown, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }

    override var acceptsFirstResponder: Bool { isShown && super.acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
        guard isShown else { return false }
        let ok = super.becomeFirstResponder()
        if ok { onFocus() }
        return ok
    }

    // Clicks on the controls are handled by subviews and never reach here, so also
    // listen for any mouse-down inside the view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown else { return nil }
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onFocus() }
        return hit
    }
}
