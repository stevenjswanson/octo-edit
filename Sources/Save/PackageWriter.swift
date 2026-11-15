import Foundation
import Core
import MarkupGrammar

/// Writes a Project into an `.octoedit` package directory.
public enum PackageWriter {
    public struct Options: Sendable {
        /// Timed word list for words.tsv. Written only when given (ingest) or when the
        /// package has none: words.tsv is the record of what was spoken and when, and
        /// is never rewritten by ordinary saves (only by `saveReplacingVideo`).
        public var words: [TimedWord]?
        public var envelope: Envelope?
        /// Original Zoom transcript to copy into the package (first save only).
        public var zoomTranscript: URL?

        public init(words: [TimedWord]? = nil, envelope: Envelope? = nil, zoomTranscript: URL? = nil) {
            self.words = words
            self.envelope = envelope
            self.zoomTranscript = zoomTranscript
        }
    }

    public static func save(_ project: Project, to package: URL, options: Options = Options()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        var p = project
        p.source = storedSourcePath(p.source, package: package)

        try write(TranscriptWriter.write(p), to: package.appendingPathComponent(PackageLayout.transcript))

        let wordsURL = package.appendingPathComponent(PackageLayout.words)
        if let words = options.words {
            try write(WordsTSV.encode(words), to: wordsURL)
        } else if !fm.fileExists(atPath: wordsURL.path) {
            let timed = p.words.compactMap { w -> TimedWord? in
                guard let s = w.start, let e = w.end else { return nil }
                return TimedWord(text: w.text, start: s, end: e, confidence: w.confidence)
            }
            try write(WordsTSV.encode(timed), to: wordsURL)
        }

        if let src = options.zoomTranscript, let name = p.zoom?.file {
            let dest = package.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
        }
        if let env = options.envelope {
            try fm.createDirectory(at: package.appendingPathComponent(PackageLayout.cacheDir), withIntermediateDirectories: true)
            try WaveformFile.encode(env).write(to: package.appendingPathComponent(PackageLayout.waveform), options: .atomic)
        }
        let ignore = package.appendingPathComponent(PackageLayout.gitignore)
        if !fm.fileExists(atPath: ignore.path) { try write(PackageLayout.gitignoreContents, to: ignore) }
    }

    /// Writes only the waveform cache (e.g. rebuilt by the GUI when it was missing),
    /// leaving transcript.md and everything else alone.
    public static func saveWaveform(_ envelope: Envelope, to package: URL) throws {
        try FileManager.default.createDirectory(at: package.appendingPathComponent(PackageLayout.cacheDir),
                                                withIntermediateDirectories: true)
        try WaveformFile.encode(envelope).write(to: package.appendingPathComponent(PackageLayout.waveform), options: .atomic)
    }

    /// Writes only the face-track cache.
    public static func saveFaces(_ faces: FaceTracks, to package: URL) throws {
        try FileManager.default.createDirectory(at: package.appendingPathComponent(PackageLayout.cacheDir),
                                                withIntermediateDirectories: true)
        try write(FacesFile.encode(faces), to: package.appendingPathComponent(PackageLayout.faces))
    }

    /// Writes only the title-card still scores (cache/stills.tsv).
    public static func saveStillScores(_ scores: [StillScore], to package: URL) throws {
        try FileManager.default.createDirectory(at: package.appendingPathComponent(PackageLayout.cacheDir),
                                                withIntermediateDirectories: true)
        try write(StillsFile.encode(scores), to: package.appendingPathComponent(PackageLayout.stills))
    }

    /// Saves a project whose video was replaced: transcript.md, plus the new video's
    /// words.tsv and waveform. The old words.tsv is kept in the cache, and the face
    /// cache (scanned from the old video) is removed.
    public static func saveReplacingVideo(_ project: Project, words: [TimedWord], envelope: Envelope, to package: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: package.appendingPathComponent(PackageLayout.cacheDir), withIntermediateDirectories: true)
        let wordsURL = package.appendingPathComponent(PackageLayout.words)
        let backup = package.appendingPathComponent(PackageLayout.wordsBeforeReplace)
        if fm.fileExists(atPath: wordsURL.path) {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: wordsURL, to: backup)
        }
        try save(project, to: package, options: Options(words: words, envelope: envelope))
        for cache in [PackageLayout.faces, PackageLayout.stills] {
            let file = package.appendingPathComponent(cache)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }

    /// The source path as it should be written: relative to the package when the video
    /// lives beside the package (same parent folder tree), absolute otherwise.
    public static func storedSourcePath(_ source: String, package: URL) -> String {
        guard source.hasPrefix("/") else { return source }
        let video = URL(fileURLWithPath: source).standardizedFileURL.path
        let parent = package.standardizedFileURL.deletingLastPathComponent().path
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        guard video.hasPrefix(prefix) else { return source }
        return "../" + video.dropFirst(prefix.count)
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
