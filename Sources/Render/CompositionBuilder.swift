import Foundation
import AVFoundation
import Core

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
    }

    public static func build(asset: AVURLAsset, segments: [ResolvedSegment], crossfade: Seconds) async throws -> Output {
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
        return Output(composition: comp, audioMix: mix, segmentStarts: starts, sourceRanges: used)
    }
}
