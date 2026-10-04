import Foundation
import Core
import MarkupGrammar

/// Reads an `.octoedit` package.
public enum PackageReader {
    public struct Result: Sendable {
        public var project: Project
        public var envelope: Envelope?
        public var issues: [Issue]
        /// The input video, resolved against the package location.
        public var sourceURL: URL
        public var hasErrors: Bool { issues.contains { $0.severity == .error } }
    }

    public enum ReadError: Error, CustomStringConvertible {
        case missing(String)
        case words(String)

        public var description: String {
            switch self {
            case .missing(let f): "the package has no \(f)"
            case .words(let m): m
            }
        }
    }

    public static func load(_ package: URL) throws -> Result {
        let transcriptURL = package.appendingPathComponent(PackageLayout.transcript)
        let wordsURL = package.appendingPathComponent(PackageLayout.words)
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            throw ReadError.missing(PackageLayout.transcript)
        }
        guard let wordsText = try? String(contentsOf: wordsURL, encoding: .utf8) else {
            throw ReadError.missing(PackageLayout.words)
        }
        let timed: [TimedWord]
        do { timed = try WordsTSV.decode(wordsText) } catch { throw ReadError.words("\(error)") }
        let parsed = TranscriptReader.parse(text, timedWords: timed)
        let envelope = (try? Data(contentsOf: package.appendingPathComponent(PackageLayout.waveform))).flatMap(WaveformFile.decode)
        return Result(project: parsed.project, envelope: envelope, issues: parsed.issues,
                      sourceURL: resolveSource(parsed.project.source, package: package))
    }

    public static func resolveSource(_ source: String, package: URL) -> URL {
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        if source.hasPrefix("~") { return URL(fileURLWithPath: (source as NSString).expandingTildeInPath) }
        return URL(fileURLWithPath: source, relativeTo: package.standardizedFileURL.appendingPathComponent("x").deletingLastPathComponent()).standardizedFileURL
    }
}
