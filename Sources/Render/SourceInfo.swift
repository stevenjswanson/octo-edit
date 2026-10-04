import Foundation
import AVFoundation
import Core

/// What Render needs to know about the input video. Read from the file every time;
/// never stored in the project.
public struct SourceInfo: Sendable {
    public var duration: Seconds
    public var frameRate: Double
    /// Display size (rotation applied).
    public var width: Int
    public var height: Int
    public var codec: Codec
    public var hasAudio: Bool

    public static func read(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let (duration, fps, size, transform, formats) = try await (
            asset.load(.duration), video.load(.nominalFrameRate), video.load(.naturalSize),
            video.load(.preferredTransform), video.load(.formatDescriptions))
        let shown = size.applying(transform)
        let sub = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let codec: Codec = sub == kCMVideoCodecType_H264 ? .h264 : .hevc
        return SourceInfo(duration: duration.seconds, frameRate: Double(fps), width: Int(abs(shown.width).rounded()),
                          height: Int(abs(shown.height).rounded()), codec: codec, hasAudio: audio != nil)
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noVideoTrack
    case missingSource(String)
    case emptyClip(String)
    case exportFailed(String)

    public var description: String {
        switch self {
        case .noVideoTrack: "the input has no video track"
        case .missingSource(let p): "can't find the input video at \(p)"
        case .emptyClip(let s): "clip \(s) has no timed words, so there is nothing to render"
        case .exportFailed(let m): "export failed: \(m)"
        }
    }
}
