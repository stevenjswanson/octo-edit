import Foundation
import ArgumentParser
import Core
import Load
import Save
import FaceTrack
import SpeakerFraming

struct FacesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "faces",
        abstract: "Find faces through the video, for 9:16 framing.",
        discussion: """
        Writes cache/faces.tsv: face boxes and mouth shape about ten times a second,
        no face fingerprints. Framing works out whose face is whose from the
        transcript's speakers, so fixing a speaker name also fixes the framing.
        Takes about a third of the video's length for 4K. The app builds this in the
        background when it's missing.

        --explain SLUG prints how one clip's 9:16 column follows its speakers: each
        speaker turn, whose faces are where in each shot, and each move of the column.

        EXAMPLES
          octoedit faces seminar.octoedit
          octoedit faces seminar.octoedit --explain lightning-round
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Option(help: "Explain the 9:16 framing of the clip with this slug (uses the existing cache/faces.tsv).")
    var explain: String?

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        if let explain {
            try Self.explain(explain, pkg, project: loaded.project)
            return
        }
        try await Self.build(pkg, source: loaded.sourceURL, project: loaded.project)
    }

    static func explain(_ slug: String, _ pkg: URL, project p: Project) throws {
        guard let id = p.slugs().first(where: { $0.value == slug })?.key, let clip = p.clip(id) else {
            throw ValidationError("no clip with slug \(slug)")
        }
        guard let faces = PackageReader.loadFaces(pkg) else { throw ValidationError("no cache/faces.tsv; run octoedit faces first") }
        let labels = FaceLabels(faces: faces, project: p)
        let timeline = SpeechTimeline(p)
        let segs = p.resolvedSegments(of: clip).map { ($0.start, $0.end) }
        let column = ColumnPath(segments: segs, timeline: timeline, labels: labels, aspect: labels.aspect)
        func clock(_ t: Double) -> String { String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        var offset = 0.0
        for (start, end) in segs {
            print("segment \(clock(start))–\(clock(end))  (clip \(clock(offset)))")
            var shot = -1
            var events: [(Double, String)] = []
            for turn in timeline.turns(from: start, to: end) {
                events.append((turn.start, String(format: "  speaks %-10@ %.1f s", turn.speaker as NSString, turn.end - turn.start)))
            }
            for key in column.keys where key.t >= start && key.t < end {
                let who = labels.faces(at: key.t).min { abs($0.box.centerX - key.x) < abs($1.box.centerX - key.x) }
                events.append((key.t, String(format: "  COLUMN → x %.2f%@ (nearest face: %@)", key.x, key.dips ? " dip" : "",
                                             (who?.speaker ?? "?") as NSString)))
            }
            for t in stride(from: start, to: end, by: 0.5) where labels.shot(at: t) != shot {
                shot = labels.shot(at: t)
                let fs = labels.faces(at: t).sorted { $0.box.centerX < $1.box.centerX }
                    .map { String(format: "%@@%.2f", ($0.speaker ?? "?") as NSString, $0.box.centerX) }
                events.append((t, "  shot \(shot): " + (fs.isEmpty ? "no faces" : fs.joined(separator: " "))))
            }
            for (t, line) in events.sorted(by: { $0.0 < $1.0 }) { print(clock(t - start + offset) + line) }
            offset += end - start
        }
    }

    /// Scans the video, writes the cache, and says how many faces could be matched to speakers.
    static func build(_ pkg: URL, source: URL, project: Project) async throws {
        let started = Date()
        let faces = try await VisionFaceScanner().scan(video: source) { Console.progress("Finding faces", $0) }
        try PackageWriter.saveFaces(faces, to: pkg)
        let labels = FaceLabels(faces: faces, project: project)
        let found = Set(labels.tracks.compactMap(\.speaker))
        Console.note(String(format: "Scanned %d frames in %.0f s: %d shots.", faces.frames.count,
                            Date().timeIntervalSince(started), labels.shotStarts.count))
        let speakers = project.speakersInOrder()
        if !speakers.isEmpty {
            let missing = speakers.filter { !found.contains($0) }
            Console.note("Faces matched to speakers: " + (found.isEmpty ? "none" : speakers.filter(found.contains).joined(separator: ", "))
                         + (missing.isEmpty ? "" : "; no face for " + missing.joined(separator: ", ")))
        }
    }
}
