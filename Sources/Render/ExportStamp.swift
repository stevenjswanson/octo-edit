import CryptoKit
import Foundation
import Core

/// What an exported clip was made from, so a later look can tell whether the clip has
/// changed since: a hash of everything that goes into the files (its cuts, words and
/// speakers, name and notes, auto-levels, the crossfade and speaker fade, which video
/// it came from, and the output settings in `Output`: framing, codec, the face tracks
/// a 9:16 column follows, and the post-export program, if one made the file).
/// Resolution is left out: 4k and 720p files of a clip sit side by side, made from
/// the same clip.
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

    /// The settings, besides the clip itself, that change what an export looks like.
    public struct Output: Equatable, Sendable {
        public var framing: Framing
        /// nil = same as the input.
        public var codec: Codec?
        /// The program that made the file from the plain export (nil: a plain export).
        public var postExport: PostExport?
        /// The face tracks a 9:16 column follows (ignored for source framing).
        public var faces: FaceTracks?

        public init(framing: Framing, codec: Codec?, postExport: PostExport?, faces: FaceTracks?) {
            self.framing = framing
            self.codec = codec
            self.postExport = postExport
            self.faces = faces
        }

        /// Lines for the hash. Only face frames within the clip's span count, so finding
        /// faces elsewhere in the talk leaves other clips alone.
        func lines(span: ClosedRange<Seconds>?) -> [String] {
            var out = ["framing " + framing.rawValue, "codec " + (codec?.rawValue ?? "source"),
                       "post " + (postExport.map { ([$0.run] + $0.args).joined(separator: "\u{1f}") } ?? "-")]
            if framing == .portrait {
                guard let faces, let span else { return out + ["faces -"] }
                func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
                for fr in faces.frames where span.contains(fr.t) {
                    out.append(([f(fr.t)] + fr.faces.map { [$0.x, $0.y, $0.w, $0.h].map(f).joined(separator: ",") }).joined(separator: " "))
                }
            }
            return out
        }
    }

    public static func fingerprint(of clip: Clip, in p: Project, sourceIdentity: String, output: Output) -> String? {
        guard let range = p.indexRange(of: clip) else { return nil }
        var speakers: [ParagraphID: String] = [:]
        for para in p.paragraphs { speakers[para.id] = para.speaker ?? "" }
        func ms(_ t: Double) -> String { String(Int((t * 1000).rounded())) }
        var lines = ["v2", sourceIdentity, clip.name ?? "", clip.notes, clip.autoLevels ? "levels" : "",
                     ms(p.settings.crossfade), ms(p.settings.speakerFade)]
        let segments = p.resolvedSegments(of: clip)
        lines += segments.map { ms($0.start) + "-" + ms($0.end) }
        // A second either side: the column eases in from just outside the clip.
        let span = segments.first.flatMap { a in segments.last.map { (a.start - 1)...($0.end + 1) } }
        lines += output.lines(span: span)
        // Only a chosen still counts (so older stamps still match): it changes the card.
        if let t = clip.still { lines.append("still " + ms(t)) }
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

    public static func states(_ p: Project, exports: URL, sourceIdentity: String, output: Output) -> [ClipID: State] {
        var out: [ClipID: State] = [:]
        for clip in p.clips {
            guard let name = p.exportName(of: clip.id) else { continue }
            let folder = exports.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { out[clip.id] = .notExported; continue }
            let now = fingerprint(of: clip, in: p, sourceIdentity: sourceIdentity, output: output)
            out[clip.id] = now != nil && read(in: folder) == now ? .current : .changed
        }
        return out
    }
}
