import Foundation
import Core

/// The Markdown notes written beside exported files.
public enum ExportNotes {
    /// `# Title`, then the clip's notes (if any).
    public static func clip(_ clip: Clip, in project: Project) -> String {
        var out = "# \(title(clip, project))\n"
        if !clip.notes.isEmpty { out += "\n" + clip.notes + "\n" }
        return out
    }

    /// The supercut: a YouTube chapter list (paste it into the video description),
    /// then each clip's title and notes.
    public static func supercut(_ clips: [Clip], starts: [Seconds], in project: Project) -> String {
        var out = "# Supercut\n\n## Chapters\n\n"
        out += chapters(clips.map { title($0, project) }, starts: starts) + "\n"
        for clip in clips {
            out += "\n## \(title(clip, project))\n"
            if !clip.notes.isEmpty { out += "\n" + clip.notes + "\n" }
        }
        return out
    }

    /// YouTube chapter lines: `0:00 Title`, one per clip. The first is always 0:00;
    /// times are whole seconds, `m:ss` or `h:mm:ss` once the video passes an hour.
    public static func chapters(_ titles: [String], starts: [Seconds]) -> String {
        let hours = (starts.last ?? 0) >= 3600
        return zip(titles, starts).enumerated().map { n, pair in
            let t = n == 0 ? 0 : Int(pair.1)   // floor: never later than the clip's start
            let stamp = hours ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                              : String(format: "%d:%02d", t / 60, t % 60)
            return "\(stamp) \(pair.0)"
        }.joined(separator: "\n")
    }

    static func title(_ clip: Clip, _ project: Project) -> String {
        clip.name ?? project.slug(of: clip.id) ?? "Clip"
    }
}
