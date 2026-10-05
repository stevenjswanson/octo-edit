import AVFoundation
import Observation
import SwiftUI

/// Watches a player's chosen speed (`defaultRate`, set by the player controls' speed
/// menu, and the speed it resumes at) and its current rate.
@MainActor @Observable
final class SpeedWatcher {
    private(set) var speed: Float = 1
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    init(_ player: AVPlayer) {
        speed = player.defaultRate
        let update: (AVPlayer) -> Void = { [weak self] p in
            // While playing, the actual rate; while paused, the speed play will use.
            let s = p.rate != 0 ? p.rate : p.defaultRate
            DispatchQueue.main.async { self?.speed = s }
        }
        observers = [
            player.observe(\.defaultRate) { p, _ in update(p) },
            player.observe(\.rate) { p, _ in update(p) },
        ]
    }
}

/// "1×", "1.5×" in the corner of a video pane; highlighted when not 1×.
struct SpeedBadge: View {
    let watcher: SpeedWatcher

    var body: some View {
        let s = watcher.speed
        let normal = abs(s - 1) < 0.01
        Text(Self.label(s))
            .font(.caption.monospacedDigit().weight(normal ? .regular : .bold))
            .foregroundStyle(normal ? Color.white.opacity(0.6) : Color.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(normal ? Color.black.opacity(0.35) : Color.yellow, in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
            .help("Playback speed (change it from the player’s ⋯ menu)")
    }

    static func label(_ s: Float) -> String {
        let r = (Double(s) * 100).rounded() / 100
        return (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)) + "×"
    }
}
