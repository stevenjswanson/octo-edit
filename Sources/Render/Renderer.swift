import Foundation
import AVFoundation
import Core

/// Renders a project's clips and their sidecars.
public struct Renderer {
    public struct Options: Sendable {
        public var codec: Codec?
        public var preview = false

        public init(codec: Codec? = nil, preview: Bool = false) {
            self.codec = codec
            self.preview = preview
        }
    }

    public struct Rendered: Sendable {
        public var slug: String
        public var name: String?
        public var file: URL
        public var duration: Seconds
    }

    public let project: Project
    public let source: URL
    public let info: SourceInfo

    public init(project: Project, source: URL) async throws {
        guard FileManager.default.fileExists(atPath: source.path) else { throw RenderError.missingSource(source.path) }
        self.project = project
        self.source = source
        self.info = try await SourceInfo.read(source)
    }

    /// Renders one clip to `<directory>/<slug>.mp4` plus `<slug>.vtt`, or for previews
    /// to `<directory>/<slug>.preview.mp4`.
    public func render(_ clip: Clip, into directory: URL, options: Options,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Rendered {
        let slug = project.slug(of: clip.id)!
        let segments = project.resolvedSegments(of: clip, sourceDuration: info.duration)
        guard !segments.isEmpty else { throw RenderError.emptyClip(slug) }
        let built = try await CompositionBuilder.build(asset: AVURLAsset(url: source), segments: segments,
                                                       crossfade: project.settings.crossfade)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(slug + (options.preview ? ".preview.mp4" : ".mp4"))
        let quality: ClipExporter.Quality = options.preview ? .preview : .full(options.codec ?? project.settings.codec ?? info.codec)
        try await ClipExporter.export(built, info: info, quality: quality, to: file, progress: progress)
        if !options.preview {
            let vtt = Captions.webVTT(for: clip, in: project, sourceRanges: built.sourceRanges, clipStarts: built.segmentStarts)
            try vtt.write(to: directory.appendingPathComponent(slug).appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
        }
        let duration = built.sourceRanges.reduce(0) { $0 + $1.duration }
        return Rendered(slug: slug, name: clip.name, file: file, duration: duration)
    }

    /// The clips joined end to end, in the order given, as one file (`<slug>.mp4` +
    /// `<slug>.vtt`, or `<slug>.preview.mp4`). Joins between clips get the same audio
    /// crossfade as omissions.
    public func renderSupercut(_ clips: [Clip], slug: String, into directory: URL, options: Options,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Rendered {
        let perClip = clips.map { project.resolvedSegments(of: $0, sourceDuration: info.duration) }
        let segments = perClip.flatMap { $0 }
        guard !segments.isEmpty else { throw RenderError.emptyClip(slug) }
        let built = try await CompositionBuilder.build(asset: AVURLAsset(url: source), segments: segments,
                                                       crossfade: project.settings.crossfade)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(slug + (options.preview ? ".preview.mp4" : ".mp4"))
        let quality: ClipExporter.Quality = options.preview ? .preview : .full(options.codec ?? project.settings.codec ?? info.codec)
        try await ClipExporter.export(built, info: info, quality: quality, to: file, progress: progress)
        if !options.preview {
            let vtt = Captions.webVTT(supercut: clips, in: project, segmentCounts: perClip.map(\.count),
                                      sourceRanges: built.sourceRanges, clipStarts: built.segmentStarts)
            try vtt.write(to: directory.appendingPathComponent(slug).appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
        }
        let duration = built.sourceRanges.reduce(0) { $0 + $1.duration }
        return Rendered(slug: slug, name: "Supercut (\(clips.count) clips)", file: file, duration: duration)
    }

    /// `<base>-supercut`, made distinct from every clip's slug.
    public func supercutSlug(base: String) -> String {
        let taken = Set(project.slugs().values)
        var slug = slugify(base).isEmpty ? "supercut" : slugify(base) + "-supercut"
        while taken.contains(slug) { slug += "-all" }
        return slug
    }

    /// `notes.md` listing the exported clips, with their notes as footnotes.
    public func notesFile(for rendered: [Rendered]) -> String {
        var lines = ["# Exported clips", ""]
        var notes: [String] = []
        for r in rendered {
            let clip = project.clip(withSlug: r.slug)
            let hasNote = !(clip?.notes.isEmpty ?? true)
            let label = r.name ?? r.slug
            lines.append("- [\(r.file.lastPathComponent)](\(r.file.lastPathComponent)) — \(label) — \(Captions.clock(r.duration))"
                         + (hasNote ? "[^\(r.slug)]" : ""))
            if hasNote, let text = clip?.notes {
                let ls = text.components(separatedBy: "\n")
                notes.append("[^\(r.slug)]: " + ls[0] + ls.dropFirst().map { $0.isEmpty ? "\n" : "\n    " + $0 }.joined())
            }
        }
        if !notes.isEmpty { lines += [""] + notes.joined(separator: "\n\n").components(separatedBy: "\n") }
        return lines.joined(separator: "\n") + "\n"
    }
}
