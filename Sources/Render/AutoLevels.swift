import Foundation
import AVFoundation
import CoreImage
import Core

/// Auto-levels for a clip: Core Image's own auto-enhance (as in Photos: a tone curve,
/// face-aware skin-tone balance, vibrance, and shadow lift), measured on frames
/// spread through the clip and averaged, then applied unchanged to every frame — so
/// it never flickers or pumps the way per-frame correction does.
public struct AutoLevels: Equatable, Sendable {
    public struct Filter: Equatable, Sendable {
        public var name: String
        public var numbers: [String: Double]
        public var vectors: [String: [Double]]
    }

    public var filters: [Filter]

    public static let identity = AutoLevels(filters: [])

    /// The average of each frame's suggestions; a filter suggested for fewer than half
    /// the frames is left out.
    public init(frames: [[Filter]]) {
        var order: [String] = []
        var byName: [String: [Filter]] = [:]
        for f in frames.flatMap({ $0 }) {
            if byName[f.name] == nil { order.append(f.name) }
            byName[f.name, default: []].append(f)
        }
        filters = order.compactMap { name in
            let all = byName[name]!
            guard all.count * 2 >= frames.count, let first = all.first else { return nil }
            var avg = Filter(name: name, numbers: [:], vectors: [:])
            for k in first.numbers.keys {
                let v = all.compactMap { $0.numbers[k] }
                avg.numbers[k] = v.reduce(0, +) / Double(v.count)
            }
            for (k, v0) in first.vectors {
                let v = all.compactMap { $0.vectors[k] }.filter { $0.count == v0.count }
                avg.vectors[k] = v0.indices.map { i in v.reduce(0) { $0 + $1[i] } / Double(v.count) }
            }
            return avg
        }
    }

    public init(filters: [Filter]) {
        self.filters = filters
    }

    /// What Core Image suggests for one frame.
    static func suggested(for image: CIImage) -> [Filter] {
        image.autoAdjustmentFilters(options: [.redEye: false]).map { f in
            var out = Filter(name: f.name, numbers: [:], vectors: [:])
            for k in f.inputKeys where k != kCIInputImageKey {
                switch f.value(forKey: k) {
                case let n as NSNumber: out.numbers[k] = n.doubleValue
                case let v as CIVector: out.vectors[k] = (0..<v.count).map { Double(v.value(at: $0)) }
                default: break
                }
            }
            return out
        }
    }

    func apply(_ image: CIImage) -> CIImage {
        var out = image
        for f in filters {
            var params: [String: Any] = f.numbers.mapValues { NSNumber(value: $0) }
            for (k, v) in f.vectors { params[k] = CIVector(values: v.map { CGFloat($0) }, count: v.count) }
            out = out.applyingFilter(f.name, parameters: params)
        }
        return out.cropped(to: image.extent)
    }

    // MARK: Measuring

    /// Frames looked at per clip, spread evenly over its kept material.
    static let samples = 8

    /// Measures the levels of `segments` of `asset`. Results are cached per source
    /// and segment list, so rebuilding a preview doesn't measure again.
    public static func measure(_ asset: AVURLAsset, segments: [ResolvedSegment]) async throws -> AutoLevels {
        let key = asset.url.path + segments.map { "|\($0.start)-\($0.end)" }.joined()
        if let hit = cache.get(key) { return hit }
        let total = segments.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return .identity }
        // Evenly spaced times through the kept material, as source times.
        var times: [CMTime] = []
        for k in 0..<samples {
            var t = (Double(k) + 0.5) / Double(samples) * total
            for s in segments {
                if t < s.duration { times.append(CMTime(seconds: s.start + t, preferredTimescale: 600)); break }
                t -= s.duration
            }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let slack = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        var frames: [[Filter]] = []
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            frames.append(suggested(for: CIImage(cgImage: image)))
        }
        let levels = AutoLevels(frames: frames)
        cache.set(key, levels)
        return levels
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: AutoLevels] = [:]
        func get(_ key: String) -> AutoLevels? { lock.withLock { entries[key] } }
        func set(_ key: String, _ value: AutoLevels) { lock.withLock { entries[key] = value } }
    }

    private static let cache = Cache()
}
