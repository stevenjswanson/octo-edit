import Foundation
import AVFoundation
import Core
import SpeakerFraming

/// Turns a clip's source-time segments into a composition: hard video cuts on frame
/// boundaries, and audio that overlaps by `crossfade` at each join with opposing
/// volume ramps (segments alternate between two audio tracks so they can overlap).
/// The same composition drives preview and export, so they cannot diverge.
public struct CompositionBuilder {
    public struct Output {
        public let composition: AVMutableComposition
        public let audioMix: AVMutableAudioMix?
        /// Where each segment starts on the clip's own timeline.
        public let segmentStarts: [Seconds]
        /// The frame-snapped source ranges actually used.
        public let sourceRanges: [ResolvedSegment]
        /// The 9:16 crop, when framing asks for one (nil: the frame as it came in).
        public let videoComposition: AVVideoComposition?
    }

    /// With `column`, each frame is cropped to a full-height 9:16 column that follows
    /// it, scaled to `outputHeight` when given (e.g. 1280 for a 720p export).
    public static func build(asset: AVURLAsset, segments: [ResolvedSegment], crossfade: Seconds,
                             column: ColumnPath? = nil, outputHeight: Int? = nil) async throws -> Output {
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (fps, timescale, transform) = try await (vTrack.load(.nominalFrameRate), vTrack.load(.naturalTimeScale),
                                                     vTrack.load(.preferredTransform))
        let duration = try await asset.load(.duration)
        let rate = Double(fps > 0 ? fps : 30)
        let ts = timescale > 0 ? timescale : 600

        /// Nearest frame boundary on the source's own timescale.
        func snap(_ t: Seconds) -> CMTime {
            let frame = (t * rate).rounded()
            return CMTimeMinimum(CMTime(value: CMTimeValue((frame / rate * Double(ts)).rounded()), timescale: ts), duration)
        }

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.exportFailed("could not create a video track")
        }
        cv.preferredTransform = transform
        var audioTracks: [AVMutableCompositionTrack] = []
        var params: [AVMutableAudioMixInputParameters] = []
        if aTrack != nil {
            for _ in 0..<2 {
                guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                audioTracks.append(t)
                let p = AVMutableAudioMixInputParameters(track: t)
                // An explicit starting level: without it, the first ramp on a track whose
                // audio begins at that ramp is ignored and the track enters at full volume
                // (an audible click at the first join).
                p.setVolume(audioTracks.count == 1 ? 1 : 0, at: .zero)
                params.append(p)
            }
        }

        let half = CMTime(seconds: crossfade / 2, preferredTimescale: 48_000)
        let fade = half + half
        var cursor = CMTime.zero
        var starts: [Seconds] = []
        var used: [ResolvedSegment] = []
        let snapped = segments.map { (snap($0.start), snap($0.end)) }.filter { $0.1 > $0.0 }
        for (k, (start, end)) in snapped.enumerated() {
            let range = CMTimeRange(start: start, end: end)
            try cv.insertTimeRange(range, of: vTrack, at: cursor)
            if let aTrack, audioTracks.count == 2 {
                let first = k == 0, last = k == snapped.count - 1
                let pre = first || crossfade <= 0 ? .zero : CMTimeMinimum(half, start)
                let post = last || crossfade <= 0 ? .zero : CMTimeMinimum(half, duration - end)
                let track = audioTracks[k % 2]
                try track.insertTimeRange(CMTimeRange(start: start - pre, end: end + post), of: aTrack, at: cursor - pre)
                if !first, crossfade > 0 {
                    params[k % 2].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                                timeRange: CMTimeRange(start: cursor - half, duration: fade))
                }
                if !last, crossfade > 0 {
                    params[k % 2].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                                timeRange: CMTimeRange(start: cursor + range.duration - half, duration: fade))
                }
            }
            starts.append(cursor.seconds)
            used.append(ResolvedSegment(start: start.seconds, end: end.seconds))
            cursor = cursor + range.duration
        }
        var mix: AVMutableAudioMix?
        if !params.isEmpty {
            mix = AVMutableAudioMix()
            mix!.inputParameters = params
        }
        var video: AVVideoComposition?
        if let column, column.width < 0.999 {
            let size = try await vTrack.load(.naturalSize).applying(transform)
            video = crop(comp, track: cv, column: column, transform: transform,
                         frame: CGSize(width: abs(size.width), height: abs(size.height)),
                         starts: starts, ranges: used, fps: rate, outputHeight: outputHeight)
        }
        return Output(composition: comp, audioMix: mix, segmentStarts: starts, sourceRanges: used, videoComposition: video)
    }

    /// A video composition that moves the frame left so the column lands in a
    /// column-sized render area: constant between keys, cutting at each key.
    static func crop(_ comp: AVMutableComposition, track: AVMutableCompositionTrack, column: ColumnPath,
                     transform: CGAffineTransform, frame: CGSize, starts: [Seconds], ranges: [ResolvedSegment],
                     fps: Double, outputHeight: Int?) -> AVVideoComposition {
        let even = { (v: Double) in CGFloat(max(2, Int((v / 2).rounded()) * 2)) }
        let columnWidth = Double(frame.width) * column.width
        let scale = outputHeight.map { Double($0) / Double(frame.height) } ?? 1
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        func placed(_ x: Double) -> CGAffineTransform {
            let left = x * Double(frame.width) - columnWidth / 2
            return transform.concatenating(CGAffineTransform(translationX: -left, y: 0))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        }
        let ts: CMTimeScale = 600
        for (k, r) in ranges.enumerated() {
            let offset = starts[k] - r.start
            let at = { (t: Seconds) in CMTime(seconds: t + offset, preferredTimescale: ts) }
            layer.setTransform(placed(column.x(at: r.start)), at: at(r.start))
            for key in column.keys where key.t > r.start && key.t < r.end {
                layer.setTransform(placed(key.x), at: at(key.t))
            }
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.layerInstructions = [layer]
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: even(columnWidth * scale), height: even(Double(frame.height) * scale))
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
        video.instructions = [instruction]
        return video
    }
}
