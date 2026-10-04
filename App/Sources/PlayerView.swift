import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.allowsMagnification = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
