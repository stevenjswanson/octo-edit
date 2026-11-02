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
    /// Play clip previews as the 9:16 column that follows the speaker, whatever the
    /// project's export framing.
    var portraitPreview: Bool {
        didSet { UserDefaults.standard.set(portraitPreview, forKey: "portraitPreview") }
    }

    /// Label the faces on the video with a dot in their speaker's colour and the name
    /// (a viewing aid only; never exported).
    var showFaces: Bool {
        didSet { UserDefaults.standard.set(showFaces, forKey: "showFaces") }
    }

    private init() {
        let d = UserDefaults.standard
        showFaces = d.object(forKey: "showFaces") as? Bool ?? false
        portraitPreview = d.object(forKey: "portraitPreview") as? Bool ?? false
        autoPreview = d.object(forKey: "autoPreview") as? Bool ?? true
        autoPreviewLength = d.object(forKey: "autoPreviewLength") as? Double ?? 2
    }
}
