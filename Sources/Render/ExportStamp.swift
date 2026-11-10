import CryptoKit
import Foundation
import Core

/// What an exported clip was made from, so a later look can tell whether the clip has
/// changed since: a hash of everything that goes into the files (its cuts, words and
/// speakers, name and notes, auto-levels, the crossfade and speaker fade, and which
/// video it came from). Resolution, framing and codec are left out: they choose which
/// file is made, not what the clip is.
///
/// Each clip export writes it to `<exports>/C03-budget/.octoedit-stamp`, one line.
public enum ExportStamp {
    public static let fileName = ".octoedit-stamp"

    /// The input video, as far as a stamp cares: its file name and size. Replacing the
    /// video (even with one of the same name) changes it, so every clip reads as changed.
    public static func sourceIdentity(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return url.lastPathComponent + " " + (size.map(String.init) ?? "?")
    }

    public static func fingerprint(of clip: Clip, in p: Project, sourceIdentity: String) -> String? {
        guard let range = p.indexRange(of: clip) else { return nil }
        var speakers: [ParagraphID: String] = [:]
        for para in p.paragraphs { speakers[para.id] = para.speaker ?? "" }
        func ms(_ t: Double) -> String { String(Int((t * 1000).rounded())) }
        var lines = ["v1", sourceIdentity, clip.name ?? "", clip.notes, clip.autoLevels ? "levels" : "",
                     ms(p.settings.crossfade), ms(p.settings.speakerFade)]
        lines += p.resolvedSegments(of: clip).map { ms($0.start) + "-" + ms($0.end) }
        lines += range.map { i in
            let w = p.words[i]
            return [w.text, speakers[w.paragraph] ?? "", w.start.map(ms) ?? "", w.end.map(ms) ?? ""].joined(separator: "\t")
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The stamp in an export folder, if there is one.
    public static func read(in folder: URL) -> String? {
        (try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ stamp: String, in folder: URL) throws {
        try (stamp + "\n").write(to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    /// How each clip's export in `exports` compares with the clip now.
    public enum State: Equatable, Sendable {
        /// Exported, and nothing has changed since.
        case current
        /// Exported before, but the clip has changed (or the export predates stamps).
        case changed
        /// Nothing exported under the clip's current name.
        case notExported
    }

    public static func states(_ p: Project, exports: URL, sourceIdentity: String) -> [ClipID: State] {
        var out: [ClipID: State] = [:]
        for clip in p.clips {
            guard let name = p.exportName(of: clip.id) else { continue }
            let folder = exports.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { out[clip.id] = .notExported; continue }
            let now = fingerprint(of: clip, in: p, sourceIdentity: sourceIdentity)
            out[clip.id] = now != nil && read(in: folder) == now ? .current : .changed
        }
        return out
    }
}
