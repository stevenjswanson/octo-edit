import Foundation
import Observation

/// App-wide playback preferences, remembered between launches.
@MainActor @Observable
final class PlaybackSettings {
    static let shared = PlaybackSettings()

    /// After an edit to the previewed clip (while it isn't playing), play the spot that changed.
    var autoPreview: Bool {
        didSet { UserDefaults.standard.set(autoPreview, forKey: "autoPreview") }
    }
    /// How much auto preview plays on each side of the change, in seconds.
    var autoPreviewLength: Double {
        didSet { UserDefaults.standard.set(autoPreviewLength, forKey: "autoPreviewLength") }
    }

    private init() {
        let d = UserDefaults.standard
        autoPreview = d.object(forKey: "autoPreview") as? Bool ?? true
        autoPreviewLength = d.object(forKey: "autoPreviewLength") as? Double ?? 2
    }
}
