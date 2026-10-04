import Foundation
import Core
import MarkupGrammar

/// Writes a Project into an `.octoedit` package directory.
public enum PackageWriter {
    public struct Options: Sendable {
        /// Timed word list for words.tsv. Written only when given (ingest) or when the
        /// package has none: words.tsv is the record of what was spoken and when, and
        /// is never rewritten by ordinary saves.
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
