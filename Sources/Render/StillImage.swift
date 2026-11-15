import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Core

/// The title card's picture as a file: the exact source frame at the still's time,
/// framed like the export (a full-height 9:16 column centred on the speaker's face, or
/// the whole frame), with the clip's auto levels, at the source's resolution.
public enum StillImage {
    /// The frame at `t`, framed and levelled. `faceX` is the face centre as a fraction of
    /// the width (nil centres the column). `maxHeight` scales it down (for thumbnails).
    public static func render(source: URL, at t: Seconds, faceX: Double?, framing: Framing,
                              levels: AutoLevels?, maxHeight: Int? = nil) async throws -> CGImage {
        let asset = AVURLAsset(url: source)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let frame = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var image = CIImage(cgImage: frame)
        if let levels { image = levels.apply(image) }
        let w = Double(frame.width), h = Double(frame.height)
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        if framing == .portrait {
            let cw = min((h * 9 / 16).rounded(), w)
            let left = min(max((faceX ?? 0.5) * w - cw / 2, 0), w - cw).rounded()
            rect = CGRect(x: left, y: 0, width: cw, height: h)
        }
        var cropped = image.cropped(to: rect)
        if let maxHeight, Double(maxHeight) < h {
            let k = Double(maxHeight) / h
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: k, y: k))
            rect = cropped.extent.integral
        }
        let context = CIContext()
        guard let out = context.createCGImage(cropped, from: rect) else { throw RenderError.exportFailed("could not draw the title-card still") }
        return out
    }

    /// A clip's auto levels (measured once per clip and remembered).
    public static func levels(source: URL, segments: [ResolvedSegment]) async throws -> AutoLevels {
        try await AutoLevels.measure(AVURLAsset(url: source), segments: segments)
    }

    /// Writes `image` as a JPEG.
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
