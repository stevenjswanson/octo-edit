import Foundation
import AVFoundation
import Core

/// Renders a project's clips and their sidecars.
public struct Renderer {
    public enum Resolution: String, Sendable, CaseIterable {
        /// The input video's own size.
        case full
        /// 1280×720 H.264.
        case hd720
    }

    public struct Options: Sendable {
        public var codec: Codec?
        public var preview = false
        public var resolution: Resolution = .full

        public init(codec: Codec? = nil, preview: Bool = false, resolution: Resolution = .full) {
            self.codec = codec
            self.preview = preview
            self.resolution = resolution
        }
    }

    /// The resolution label in exported file names: `4k`, `8k`, `720p`, else the
    /// short side in lines (`1080p`, also for portrait video).
    public func resolutionLabel(_ r: Resolution) -> String { Self.resolutionLabel(r, info: info) }

    public static func resolutionLabel(_ r: Resolution, info: SourceInfo) -> String {
        if r == .hd720 { return "720p" }
        switch min(info.width, info.height) {
        case 2160: return "4k"
        case 4320: return "8k"
        case let lines: return "\(lines)p"
        }
    }

    /// `<slug>-4k` (or `-720p`, …), the base name of an export's .mp4 and .vtt;
    /// previews are `<slug>.preview`.
    public func baseName(_ slug: String, _ options: Options) -> String {
        options.preview ? slug + ".preview" : slug + "-" + resolutionLabel(options.resolution)
    }

    private func quality(_ options: Options) -> ClipExporter.Quality {
        if options.preview { return .preview }
        if options.resolution == .hd720 { return .hd720 }
        return .full(options.codec ?? project.settings.codec ?? info.codec)
    }

    public struct Rendered: Sendable {
        public var slug: String
        public var name: String?
        public var file: URL
        public var duration: Seconds
        /// The clips in this file, in order (one, or several for a supercut).
        public var clips: [ClipID] = []
        /// The captions written beside it (nil for previews).
        public var captions: String?

        public init(slug: String, name: String?, file: URL, duration: Seconds, clips: [ClipID] = [], captions: String? = nil) {
            self.slug = slug
            self.name = name
            self.file = file
            self.duration = duration
            self.clips = clips
            self.captions = captions
        }
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

    /// Renders one clip to `<directory>/<slug>-4k.mp4` plus `<slug>-4k.vtt` captions and
    /// `<slug>-4k.md` notes (the label follows the output resolution), or for previews
    /// just `<slug>.preview.mp4`.
    public func render(_ clip: Clip, into directory: URL, options: Options,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Rendered {
        let slug = project.slug(of: clip.id)!
        let segments = project.resolvedSegments(of: clip, sourceDuration: info.duration)
        guard !segments.isEmpty else { throw RenderError.emptyClip(slug) }
        let built = try await CompositionBuilder.build(asset: AVURLAsset(url: source), segments: segments,
                                                       crossfade: project.settings.crossfade)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(baseName(slug, options) + ".mp4")
        let quality = quality(options)
        try await ClipExporter.export(built, info: info, quality: quality, to: file, progress: progress)
        var vtt: String?
        if !options.preview {
            vtt = Captions.webVTT(for: clip, in: project, sourceRanges: built.sourceRanges, clipStarts: built.segmentStarts)
            try vtt!.write(to: directory.appendingPathComponent(baseName(slug, options) + ".vtt"), atomically: true, encoding: .utf8)
            try ExportNotes.clip(clip, in: project)
                .write(to: directory.appendingPathComponent(baseName(slug, options) + ".md"), atomically: true, encoding: .utf8)
        }
        let duration = built.sourceRanges.reduce(0) { $0 + $1.duration }
        return Rendered(slug: slug, name: clip.name, file: file, duration: duration, clips: [clip.id], captions: vtt)
    }

    /// A supercut made by joining clips already exported with the same options — no
    /// re-encoding, so it takes seconds. Captions are the clips' own, shifted into
    /// place; chapters come from the files' real lengths. Joins are hard cuts (clip
    /// edges sit in their padding, so they're normally silent).
    public func joinSupercut(_ parts: [Rendered], slug: String, into directory: URL, options: Options,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Rendered {
        guard !parts.isEmpty else { throw RenderError.emptyClip(slug) }
        let file = directory.appendingPathComponent(baseName(slug, options) + ".mp4")
        let starts = try await ClipExporter.join(parts.map(\.file), to: file, progress: progress)
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        let clips = parts.flatMap(\.clips).compactMap { project.clip($0) }
        var vtt: String?
        if !options.preview {
            vtt = Captions.concatenate(zip(parts, starts).map { ($0.captions ?? "WEBVTT\n", $1) })
            try vtt!.write(to: directory.appendingPathComponent(baseName(slug, options) + ".vtt"), atomically: true, encoding: .utf8)
            try ExportNotes.supercut(clips, starts: starts, in: project)
                .write(to: directory.appendingPathComponent(baseName(slug, options) + ".md"), atomically: true, encoding: .utf8)
        }
        return Rendered(slug: slug, name: "Supercut (\(clips.count) clips)", file: file, duration: duration,
                        clips: clips.map(\.id), captions: vtt)
    }

    /// The clips joined end to end, in the order given, encoded as one file from the
    /// source (`<slug>-4k.mp4` with `.vtt` and `.md`, or `<slug>.preview.mp4`). Used when
    /// the clips weren't exported in the same run; otherwise `joinSupercut` is far faster.
    /// Joins between clips get the same audio crossfade as omissions.
    public func renderSupercut(_ clips: [Clip], slug: String, into directory: URL, options: Options,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Rendered {
        let perClip = clips.map { project.resolvedSegments(of: $0, sourceDuration: info.duration) }
        let segments = perClip.flatMap { $0 }
        guard !segments.isEmpty else { throw RenderError.emptyClip(slug) }
        let built = try await CompositionBuilder.build(asset: AVURLAsset(url: source), segments: segments,
                                                       crossfade: project.settings.crossfade)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(baseName(slug, options) + ".mp4")
        let quality = quality(options)
        try await ClipExporter.export(built, info: info, quality: quality, to: file, progress: progress)
        var vtt: String?
        if !options.preview {
            vtt = Captions.webVTT(supercut: clips, in: project, segmentCounts: perClip.map(\.count),
                                  sourceRanges: built.sourceRanges, clipStarts: built.segmentStarts)
            try vtt!.write(to: directory.appendingPathComponent(baseName(slug, options) + ".vtt"), atomically: true, encoding: .utf8)
            // Each clip starts where its first segment landed.
            var starts: [Seconds] = [], k = 0
            for n in perClip.map(\.count) {
                starts.append(k < built.segmentStarts.count ? built.segmentStarts[k] : built.segmentStarts.last ?? 0)
                k += n
            }
            try ExportNotes.supercut(clips, starts: starts, in: project)
                .write(to: directory.appendingPathComponent(baseName(slug, options) + ".md"), atomically: true, encoding: .utf8)
        }
        let duration = built.sourceRanges.reduce(0) { $0 + $1.duration }
        return Rendered(slug: slug, name: "Supercut (\(clips.count) clips)", file: file, duration: duration,
                        clips: clips.map(\.id), captions: vtt)
    }

    /// `<base>-supercut`, made distinct from every clip's slug.
    public func supercutSlug(base: String) -> String {
        let taken = Set(project.slugs().values)
        var slug = slugify(base).isEmpty ? "supercut" : slugify(base) + "-supercut"
        while taken.contains(slug) { slug += "-all" }
        return slug
    }
}
