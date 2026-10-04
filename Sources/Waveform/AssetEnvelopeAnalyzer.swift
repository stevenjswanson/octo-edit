import Foundation
import AVFoundation
import Core

/// Loudness envelope of a media file's first audio track, via AVAssetReader:
/// decoded to 16 kHz mono float and reduced to RMS per bucket.
public struct AssetEnvelopeAnalyzer: EnvelopeAnalyzer {
    public static let defaultBucketsPerSecond = 200.0

    public let bucketsPerSecond: Double
    let sampleRate = 16_000.0

    public init(bucketsPerSecond: Double = AssetEnvelopeAnalyzer.defaultBucketsPerSecond) {
        self.bucketsPerSecond = bucketsPerSecond
    }

    public enum AnalyzerError: Error, CustomStringConvertible {
        case noAudioTrack
        case readFailed(String)

        public var description: String {
            switch self {
            case .noAudioTrack: "the file has no audio track"
            case .readFailed(let m): "could not read audio: \(m)"
            }
        }
    }

    public func envelope(of media: URL) async throws -> Envelope {
        let asset = AVURLAsset(url: media)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AnalyzerError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw AnalyzerError.readFailed(reader.error?.localizedDescription ?? "unknown") }

        let perBucket = Int((sampleRate / bucketsPerSecond).rounded())
        var rms: [Float] = []
        var sumSquares: Double = 0
        var count = 0
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let n = length / MemoryLayout<Float>.size
            if samples.count < n { samples = [Float](repeating: 0, count: n) }
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress!)
            }
            for k in 0..<n {
                let v = Double(samples[k])
                sumSquares += v * v
                count += 1
                if count == perBucket {
                    rms.append(Float((sumSquares / Double(count)).squareRoot()))
                    sumSquares = 0
                    count = 0
                }
            }
        }
        if reader.status == .failed { throw AnalyzerError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        if count > 0 { rms.append(Float((sumSquares / Double(count)).squareRoot())) }
        return Envelope(bucketsPerSecond: bucketsPerSecond, rms: rms)
    }
}
