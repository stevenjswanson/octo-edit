import Foundation
import AVFoundation
import Vision
import Core

/// Rates exact video frames as title-card stills with Vision: face capture quality,
/// eye openness and mouth closure from the face landmarks. Each frame is decoded
/// exactly (no keyframe snapping), so the score is for the very frame a card will use.
public struct VisionStillScorer: StillScorer {
    public init() {}

    public func score(video url: URL, _ requests: [(t: Seconds, near: FaceBox?)]) async throws -> [StillScore] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var out: [StillScore] = []
        for r in requests {
            try Task.checkCancellation()
            let time = CMTime(seconds: r.t, preferredTimescale: 600)
            guard let image = try? await gen.image(at: time).image else {
                out.append(StillScore(t: r.t, quality: 0, eyes: 0, lips: nil, face: nil))
                continue
            }
            out.append(Self.score(image, t: r.t, near: r.near))
        }
        return out
    }

    static func score(_ image: CGImage, t: Seconds, near: FaceBox?) -> StillScore {
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([landmarks])
        let found = (landmarks.results ?? []).filter { $0.confidence >= 0.5 }
        func box(_ f: VNFaceObservation) -> FaceBox {
            FaceBox(x: f.boundingBox.minX, y: 1 - f.boundingBox.maxY, w: f.boundingBox.width, h: f.boundingBox.height)
        }
        let pick: VNFaceObservation? = if let near {
            found.min { hypot(box($0).centerX - near.centerX, box($0).centerY - near.centerY)
                < hypot(box($1).centerX - near.centerX, box($1).centerY - near.centerY) }
                .flatMap { hypot(box($0).centerX - near.centerX, box($0).centerY - near.centerY) < max(near.w, 0.02) ? $0 : nil }
        } else {
            found.max { $0.boundingBox.width < $1.boundingBox.width }
        }
        guard let face = pick else { return StillScore(t: t, quality: 0, eyes: 0, lips: nil, face: nil) }

        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = [face]
        try? handler.perform([quality])
        let q = Double(quality.results?.first?.faceCaptureQuality ?? 0)

        var eyes = 0.0
        var lips: Double?
        if let l = face.landmarks {
            // Eye opening: height ÷ width of each eye's outline (in face-box units). Open
            // and looking at the audience is 0.30–0.38; looking down or half-shut, under
            // 0.25; a blink lower still. The smaller eye counts, so a wink loses too.
            let ratios = [l.leftEye, l.rightEye].compactMap { $0?.normalizedPoints }.map(Self.aspect)
            if let r = ratios.min() { eyes = min(max((r - 0.20) / 0.12, 0), 1) }
            // Looking at the audience, not off to the side: each pupil's offset from its
            // eye's centre, as a fraction of the eye's width (about ±0.1 looking ahead,
            // 0.2+ glancing sideways).
            var offsets: [Double] = []
            for (eye, pupil) in [(l.leftEye, l.leftPupil), (l.rightEye, l.rightPupil)] {
                guard let e = eye?.normalizedPoints, let p = pupil?.normalizedPoints.first, !e.isEmpty else { continue }
                let xs = e.map(\.x)
                let lo = xs.min()!, hi = xs.max()!
                guard hi > lo else { continue }
                offsets.append(abs(Double(p.x - (lo + hi) / 2) / Double(hi - lo)))
            }
            if !offsets.isEmpty {
                let off = offsets.reduce(0, +) / Double(offsets.count)
                eyes *= exp(-pow(max(off - 0.08, 0) / 0.1, 2))
            }
            // Inner-lip height as a fraction of the face box (`StillScore.closedness`).
            if let inner = l.innerLips?.normalizedPoints { lips = Self.extent(inner).h }
        }
        var b = box(face)
        if let near { b.mouthOpen = near.mouthOpen; b.mouthWidth = near.mouthWidth }
        return StillScore(t: t, quality: q, eyes: eyes, lips: lips, face: b)
    }

    static func aspect(_ pts: [CGPoint]) -> Double {
        let e = extent(pts)
        return e.w > 0 ? e.h / e.w : 0
    }

    static func extent(_ pts: [CGPoint]) -> (w: Double, h: Double) {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return (Double((xs.max() ?? 0) - (xs.min() ?? 0)), Double((ys.max() ?? 0) - (ys.min() ?? 0)))
    }
}
