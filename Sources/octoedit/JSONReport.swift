import Foundation
import Core
import Load
import Render

/// The `--json` output of `octoedit render`: one object on stdout.
enum JSONReport {
    struct Check: Encodable {
        var valid: Bool
        var transcript: String
        /// Set when the package couldn't be read at all.
        var error: String?
        var issues: [IssueOut]
        var clips: [ClipOut]
    }

    struct IssueOut: Encodable {
        var severity: String
        var line: Int?
        var message: String
    }

    struct ClipOut: Encodable {
        var index: Int
        var name: String?
        var slug: String
        /// Seconds of video the clip will produce.
        var duration: Double
        var segments: Int
        var omissions: Int
        /// Where the clip starts and ends in the source video, in seconds.
        var sourceStart: Double?
        var sourceEnd: Double?
        /// The first and last few words kept, to confirm the markers landed where intended.
        var firstWords: String
        var lastWords: String
    }

    struct Export: Encodable {
        var folder: String?
        var files: [FileOut]
    }

    struct FileOut: Encodable {
        var slug: String
        var name: String?
        var video: String
        var captions: String?
        var notes: String?
        var duration: Double
    }

    static func check(_ loaded: PackageReader.Result, transcript: String, only: [String]) -> Check {
        let p = loaded.project
        let slugs = p.slugs()
        let issues = (loaded.issues.filter { $0.severity == .error } + loaded.issues.filter { $0.severity == .warning })
            .map { IssueOut(severity: $0.severity.rawValue, line: $0.line, message: $0.message) }
        let clips = p.clips.enumerated().compactMap { n, c -> ClipOut? in
            let slug = slugs[c.id] ?? ""
            guard only.isEmpty || only.contains(slug) else { return nil }
            return clipOut(p, c, index: n, slug: slug)
        }
        return Check(valid: !loaded.hasErrors, transcript: transcript, error: nil, issues: issues, clips: clips)
    }

    /// One clip's summary; `index` is its 0-based position in the project.
    static func clipOut(_ p: Project, _ c: Clip, index: Int, slug: String) -> ClipOut {
        let kept = p.keptWords(of: c).map(\.text)
        let segs = p.resolvedSegments(of: c)
        return ClipOut(index: index + 1, name: c.name, slug: slug, duration: round(p.duration(of: c)),
                       segments: c.segments.count, omissions: p.omittedRanges(of: c).count,
                       sourceStart: segs.first.map { round($0.start) }, sourceEnd: segs.last.map { round($0.end) },
                       firstWords: kept.prefix(8).joined(separator: " "),
                       lastWords: kept.suffix(8).joined(separator: " "))
    }

    static func export(_ rendered: [Renderer.Rendered], folder: URL) -> Export {
        let fm = FileManager.default
        func sidecar(_ video: URL, _ ext: String) -> String? {
            let u = video.deletingPathExtension().appendingPathExtension(ext)
            return fm.fileExists(atPath: u.path) ? u.path : nil
        }
        return Export(folder: folder.path, files: rendered.map {
            FileOut(slug: $0.slug, name: $0.name, video: $0.file.path, captions: sidecar($0.file, "vtt"),
                    notes: sidecar($0.file, "md"), duration: round($0.duration))
        })
    }

    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
    }

    /// Seconds to 0.1 s.
    private static func round(_ t: Double) -> Double { (t * 10).rounded() / 10 }
}
