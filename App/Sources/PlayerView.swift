import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Called when the user clicks in the view or it takes keyboard focus.
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> AVPlayerView {
        let view = FocusReportingPlayerView()
        view.onFocus = onFocus
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.allowsMagnification = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        (view as? FocusReportingPlayerView)?.onFocus = onFocus
    }
}

final class FocusReportingPlayerView: AVPlayerView {
    var onFocus: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus() }
        return ok
    }

    // Clicks on the controls are handled by subviews and never reach here, so also
    // listen for any mouse-down inside the view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onFocus() }
        return hit
    }
}
