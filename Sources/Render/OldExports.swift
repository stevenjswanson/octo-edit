import Foundation
import Core

/// Export folders left behind when a clip was renamed or renumbered: the clip now
/// exports to `C03-new-name/`, but `C03-old-name/` (or `C02-…/`) is still there.
///
/// A folder counts as a clip's old export when its name isn't any clip's export name
/// now and the `.timeline.json` inside covers mostly the same stretch of the recording
/// as the clip. Clips never overlap, so the recording, not the name, says which
/// clip a folder was. Supercut folders (several clips in one timeline) are never
/// matched.
public enum OldExports {
    public struct Match: Equatable, Sendable {
        public var clip: ClipID
        public var folder: URL
    }

    /// Old export folders in `exports` for the clips in `clips` (by default every clip).
    public static func find(_ p: Project, in exports: URL, clips only: Set<ClipID>? = nil) -> [Match] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: exports.path) else { return [] }
        let current = Set(p.clips.compactMap { p.exportName(of: $0.id) })
        let spans: [(ClipID, ClosedRange<Seconds>)] = p.clips.compactMap { c in
            guard only?.contains(c.id) ?? true else { return nil }
            let segs = p.resolvedSegments(of: c)
            guard let a = segs.first?.start, let b = segs.last?.end, b > a else { return nil }
            return (c.id, a...b)
        }
        var out: [Match] = []
        for name in names.sorted() where !current.contains(name) && isClipFolderName(name) {
            let folder = exports.appendingPathComponent(name, isDirectory: true)
            guard let span = recordedSpan(of: folder) else { continue }
            // Mostly the same stretch: the overlap is at least half the shorter of the two.
            let best = spans.map { id, s -> (ClipID, Double) in
                let overlap = min(s.upperBound, span.upperBound) - max(s.lowerBound, span.lowerBound)
                let shorter = min(s.upperBound - s.lowerBound, span.upperBound - span.lowerBound)
                return (id, shorter > 0 ? overlap / shorter : 0)
            }.max { $0.1 < $1.1 }
            if let (id, share) = best, share >= 0.5 { out.append(Match(clip: id, folder: folder)) }
        }
        return out
    }

    /// `C03-something`: a clip export folder's name (numbered by place in the video).
    static func isClipFolderName(_ name: String) -> Bool {
        guard name.first == "C", let dash = name.firstIndex(of: "-") else { return false }
        let digits = name[name.index(after: name.startIndex)..<dash]
        return digits.count >= 2 && digits.allSatisfy(\.isNumber) && name.index(after: dash) < name.endIndex
    }

    /// The source-time stretch a single-clip export folder covers, from any of its
    /// `.timeline.json` files (every resolution and shape covers the same stretch).
    static func recordedSpan(of folder: URL) -> ClosedRange<Seconds>? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        for file in files.sorted() where file.hasSuffix(".timeline.json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                  let t = try? JSONDecoder().decode(Timeline.self, from: data),
                  t.clips.count == 1,
                  let a = t.segments.map(\.sourceStart).min(), let b = t.segments.map(\.sourceEnd).max(), b > a
            else { continue }
            return a...b
        }
        return nil
    }
}
