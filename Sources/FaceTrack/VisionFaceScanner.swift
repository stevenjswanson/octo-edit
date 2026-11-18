import Foundation
import AVFoundation
import Vision
import Core

/// Faces through a video with Apple's Vision face landmarks, sampled `fps` times a
/// second. About 0.3× the video's length for 4K at 10 fps. Keeps boxes, mouth shape
/// and head turn only, never face fingerprints.
public struct VisionFaceScanner: FaceScanner {
    public var fps: Double
    /// Faces Vision is less sure of than this are dropped.
    public var minimumConfidence: Float = 0.5

    public init(fps: Double = 10) {
        self.fps = fps
    }

    public func scan(video url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FaceTracks {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FaceTrackError.noVideo(url.lastPathComponent) }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FaceTrackError.noVideo(url.lastPathComponent) }

        var frames: [FaceFrame] = []
        var next = 0.0
        var previous: [Float]?
        var lastReport = -10.0
        while true {
            try Task.checkCancellation()
            // Vision and the decoder hold buffers until the pool drains; without a pool
            // per frame they pile up and every request fails after a few minutes.
            let more: Bool = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard t + 1e-3 >= next, let pixels = CMSampleBufferGetImageBuffer(sample) else { return true }
                next += 1 / fps
                let signature = Self.signature(pixels)
                let change = previous.map { p in zip(p, signature).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(signature.count) } ?? 255
                previous = signature
                frames.append(FaceFrame(t: t, change: Double(change), faces: faces(in: pixels)))
                if t - lastReport >= 5 {
                    lastReport = t
                    progress(min(t / max(duration, 1), 1))
                }
                return true
            }
            if !more { break }
        }
        if reader.status == .failed { throw reader.error ?? FaceTrackError.noVideo(url.lastPathComponent) }
        progress(1)
        return FaceTracks(width: Int(size.width), height: Int(size.height), frames: frames)
    }

    private func faces(in pixels: CVPixelBuffer) -> [FaceBox] {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        return (request.results ?? []).filter { $0.confidence >= minimumConfidence }.map { f in
            let b = f.boundingBox   // origin bottom-left
            var open: Double?, width: Double?
            if let inner = f.landmarks?.innerLips?.normalizedPoints, let outer = f.landmarks?.outerLips?.normalizedPoints {
                open = Self.extent(inner).h
                width = Self.extent(outer).w
            }
            return FaceBox(x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height, mouthOpen: open, mouthWidth: width,
                           yaw: f.yaw.map(\.doubleValue))
        }
    }

    static func extent(_ pts: [CGPoint]) -> (w: Double, h: Double) {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return (Double((xs.max() ?? 0) - (xs.min() ?? 0)), Double((ys.max() ?? 0) - (ys.min() ?? 0)))
    }

    /// A 32×18 luma thumbnail, for telling cuts from motion.
    static func signature(_ pb: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var sig: [Float] = []
        sig.reserveCapacity(576)
        for gy in 0..<18 {
            for gx in 0..<32 { sig.append(Float(base[(gy * h / 18 + h / 36) * stride + gx * w / 32 + w / 64])) }
        }
        return sig
    }
}

public enum FaceTrackError: Error, CustomStringConvertible {
    case noVideo(String)

    public var description: String {
        switch self {
        case .noVideo(let f): "\(f) has no video track"
        }
    }
}
