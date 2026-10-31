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

        EXAMPLE
          octoedit faces seminar.octoedit
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        try await Self.build(pkg, source: loaded.sourceURL, project: loaded.project)
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
