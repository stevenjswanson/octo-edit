import Foundation
import AVFoundation
import CoreImage
import Core
import SpeakerFraming

/// Turns a clip's source-time segments into a composition: hard video cuts on frame
/// boundaries, and audio that overlaps by `crossfade` at each join with opposing
/// volume ramps (segments alternate between two audio tracks so they can overlap).
/// The same composition drives preview and export, so they cannot diverge. Frames
/// pass through Core Image when they need work: the 9:16 column (dipping through
/// black when it moves to a new speaker) and auto-levels.
public struct CompositionBuilder {
    public struct Output {
        public let composition: AVMutableComposition
        public let audioMix: AVMutableAudioMix?
        /// Where each segment starts on the clip's own timeline.
        public let segmentStarts: [Seconds]
        /// The frame-snapped source ranges actually used.
        public let sourceRanges: [ResolvedSegment]
        /// The 9:16 crop and auto-levels, when asked for (nil: the frames as they came in).
        public let videoComposition: AVVideoComposition?
        /// Whether `videoComposition` crops to a 9:16 column (a size no export preset has).
        public let cropped: Bool
    }

    /// With `column`, each frame is cropped to a full-height 9:16 column that follows
    /// it, scaled to `outputHeight` when given (e.g. 1280 for a 720p export). `levels`,
    /// one per segment (nil: none), adjusts tones and colours. `speakerFade` is the
    /// length of a column's dip to a new speaker (half out, half in; 0 cuts).
    public static func build(asset: AVURLAsset, segments: [ResolvedSegment], crossfade: Seconds,
                             column: ColumnPath? = nil, speakerFade: Seconds = ProjectSettings.defaultSpeakerFade,
                             levels: [AutoLevels?] = [], outputHeight: Int? = nil) async throws -> Output {
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
        var usedLevels: [AutoLevels?] = []
        let snapped = segments.enumerated().map { (snap($1.start), snap($1.end), $0 < levels.count ? levels[$0] : nil) }
            .filter { $0.1 > $0.0 }
        for (k, (start, end, level)) in snapped.enumerated() {
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
            usedLevels.append(level)
            cursor = cursor + range.duration
        }
        var mix: AVMutableAudioMix?
        if !params.isEmpty {
            mix = AVMutableAudioMix()
            mix!.inputParameters = params
        }
        var video: AVVideoComposition?
        let crops = column.map { $0.width < 0.999 } ?? false
        if crops || usedLevels.contains(where: { $0 != nil }) {
            let size = try await vTrack.load(.naturalSize).applying(transform)
            video = try await filtered(comp, column: crops ? column : nil, speakerFade: speakerFade, levels: usedLevels,
                                       frame: CGSize(width: abs(size.width), height: abs(size.height)),
                                       starts: starts, ranges: used, fps: rate, outputHeight: outputHeight)
        }
        return Output(composition: comp, audioMix: mix, segmentStarts: starts, sourceRanges: used,
                      videoComposition: video, cropped: crops)
    }

    /// Each frame through Core Image: its segment's levels, then (with a column) a
    /// column-sized crop that holds between keys and changes at each key, with a dip
    /// through black around the keys that move to a new speaker.
    static func filtered(_ comp: AVMutableComposition, column: ColumnPath?, speakerFade: Seconds, levels: [AutoLevels?], frame: CGSize,
                         starts: [Seconds], ranges: [ResolvedSegment], fps: Double,
                         outputHeight: Int?) async throws -> AVVideoComposition {
        let even = { (v: Double) in CGFloat(max(2, Int((v / 2).rounded()) * 2)) }
        let columnWidth = Double(frame.width) * (column?.width ?? 1)
        let scale = column == nil ? 1 : outputHeight.map { Double($0) / Double(frame.height) } ?? 1
        let render = CGSize(width: even(columnWidth * scale), height: even(Double(frame.height) * scale))
        // Clip times of the dips: keys inside a segment (a key at a segment's start is
        // a join, which cuts).
        var dips: [Seconds] = []
        let half = speakerFade / 2
        if let column, half > 0 {
            for (k, r) in ranges.enumerated() {
                for key in column.keys where key.dips && key.t > r.start && key.t < r.end {
                    dips.append(key.t - r.start + starts[k])
                }
            }
        }
        let video = try await AVMutableVideoComposition.videoComposition(with: comp) { request in
            let t = request.compositionTime.seconds
            let k = max((starts.lastIndex { $0 <= t + 1e-6 }) ?? 0, 0)
            var image = request.sourceImage
            if k < levels.count, let l = levels[k] { image = l.apply(image) }
            if let column {
                let e = image.extent
                let x = column.x(at: ranges[k].start + (t - starts[k]))
                let left = e.minX + x * e.width - columnWidth / 2
                image = image.cropped(to: CGRect(x: left, y: e.minY, width: columnWidth, height: e.height))
                    .transformed(by: CGAffineTransform(translationX: -left, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let d = dips.map({ abs($0 - t) }).min(), d < half {
                    let f = d / half
                    image = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
                    ])
                }
                image = image.cropped(to: CGRect(origin: .zero, size: render))
            }
            request.finish(with: image, context: nil)
        }
        video.renderSize = render
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 1)))
        return video
    }
}
