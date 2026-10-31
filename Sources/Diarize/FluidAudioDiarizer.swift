import Foundation
import AVFoundation
import FluidAudio
import Core

/// Who speaks when, with FluidAudio's offline pipeline (pyannote segmentation,
/// WeSpeaker embeddings, VBx clustering) on this Mac. Its models (about 21 MB) are
/// downloaded once, on first use. Voice embeddings stay in memory and are never saved.
public struct FluidAudioDiarizer: Core.Diarizer {
    /// The clustering decides how many voices there are. The roster is no guide: it
    /// leaves out audience members, who would then be merged into the panelists.
    public init() {}

    public func diarize(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [VoiceTurn] {
        AppLogger.minimumLevel = .warning
        let config = OfflineDiarizerConfig.default
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        progress(0.05)
        let samples = try await Self.monoSamples(of: audio, sampleRate: Double(config.segmentation.sampleRate))
        try Task.checkCancellation()
        progress(0.2)
        let result = try await manager.process(audio: samples) { done, total in
            progress(0.2 + 0.8 * Double(done) / Double(max(total, 1)))
        }
        progress(1)
        return Self.turns(result.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) })
    }

    /// Turns sorted by start, with FluidAudio's speaker ids renamed S1, S2, … in order
    /// of first appearance.
    static func turns(_ segments: [(id: String, start: Double, end: Double)]) -> [VoiceTurn] {
        var labels: [String: String] = [:]
        return segments.sorted { $0.start < $1.start }.map { s in
            let v = labels[s.id] ?? { let l = "S\(labels.count + 1)"; labels[s.id] = l; return l }()
            return VoiceTurn(start: s.start, end: s.end, voice: v)
        }
    }

    /// The first audio track, mixed to mono and resampled.
    static func monoSamples(of url: URL, sampleRate: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw DiarizeError.noAudio(url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? DiarizeError.noAudio(url.lastPathComponent) }
        let duration = try await asset.load(.duration).seconds
        var samples: [Float] = []
        samples.reserveCapacity(Int(max(duration, 0) * sampleRate) + 1)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? DiarizeError.noAudio(url.lastPathComponent) }
        return samples
    }
}

public enum DiarizeError: Error, CustomStringConvertible {
    case noAudio(String)

    public var description: String {
        switch self {
        case .noAudio(let f): "\(f) has no audio track"
        }
    }
}
