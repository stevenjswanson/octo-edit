import AVFoundation
import AppKit
import Observation
import Core

/// One small frame per clip, taken at the clip's first kept moment. In memory only
/// for now (the plan's cache/thumbs/ on disk can come later); regenerated when a
/// clip's start moves.
@MainActor @Observable
final class Thumbnails {
    private(set) var images: [ClipID: NSImage] = [:]
    @ObservationIgnored private var times: [ClipID: Double] = [:]
    @ObservationIgnored private var generator: AVAssetImageGenerator?

    func attach(source: URL?) {
        images = [:]
        times = [:]
        generator = source.map {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: $0))
            g.maximumSize = CGSize(width: 320, height: 180)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            return g
        }
    }

    func update(_ project: Project) {
        let live = Set(project.clips.map(\.id))
        for id in images.keys where !live.contains(id) { images[id] = nil; times[id] = nil }
        guard let generator else { return }
        for clip in project.clips {
            guard let start = project.resolvedSegments(of: clip).first?.start else { continue }
            // A little past the cut, so the frame isn't the pre-roll.
            let t = start + 0.5
            if let old = times[clip.id], abs(old - t) < 0.25 { continue }
            times[clip.id] = t
            let id = clip.id
            Task {
                guard let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                      times[id] == t else { return }
                images[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}
