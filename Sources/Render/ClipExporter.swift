import Foundation
import AVFoundation
import Core

/// Exports one clip with the hardware encoder.
public enum ClipExporter {
    public enum Quality: Sendable {
        /// Same resolution and frame rate as the input; codec from settings or the input's.
        case full(Codec)
        /// Fast, small 720p H.264 for checking cuts.
        case preview
    }

    /// The export preset: an exact-size preset when one exists for the source's
    /// dimensions, otherwise "highest quality", which keeps the source size.
    public static func preset(for info: SourceInfo, quality: Quality) -> String {
        switch quality {
        case .preview:
            return AVAssetExportPreset1280x720
        case .full(.hevc):
            switch (info.width, info.height) {
            case (3840, 2160): return AVAssetExportPresetHEVC3840x2160
            case (1920, 1080): return AVAssetExportPresetHEVC1920x1080
            case (4320, 2160): return AVAssetExportPresetHEVC4320x2160
            case (7680, 4320): return AVAssetExportPresetHEVC7680x4320
            default: return AVAssetExportPresetHEVCHighestQuality
            }
        case .full(.h264):
            switch (info.width, info.height) {
            case (3840, 2160): return AVAssetExportPreset3840x2160
            case (1920, 1080): return AVAssetExportPreset1920x1080
            case (1280, 720): return AVAssetExportPreset1280x720
            case (960, 540): return AVAssetExportPreset960x540
            case (640, 480): return AVAssetExportPreset640x480
            default: return AVAssetExportPresetHighestQuality
            }
        }
    }

    public static func export(_ built: CompositionBuilder.Output, info: SourceInfo, quality: Quality, to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset(for: info, quality: quality)) else {
            throw RenderError.exportFailed("no export session for this source")
        }
        session.audioMix = built.audioMix
        // A video composition forces a real re-encode. Without it AVFoundation may pass
        // the source's GOPs through and hide the extra frames with edit lists, which many
        // players and upload sites ignore (stray frames at every cut).
        session.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: built.composition)
        // Export to a hidden temporary name and rename when done, so a half-written
        // file (which players can't open) never appears under the clip's name.
        let fm = FileManager.default
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).partial.mp4")
        try? fm.removeItem(at: partial)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: partial, as: .mp4)
        } catch {
            try? fm.removeItem(at: partial)
            throw RenderError.exportFailed(error.localizedDescription)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: url)
        }
        progress(1)
    }
}
