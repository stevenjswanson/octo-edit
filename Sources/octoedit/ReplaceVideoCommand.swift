import Foundation
import ArgumentParser
import Core
import Ingest
import Load
import MarkupGrammar
import Save
import Transcribe
import Waveform
import Render
import SpeakerFraming

struct ReplaceVideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace-video",
        abstract: "Point a project at another video of the same recording (e.g. the high-resolution original).",
        discussion: """
        The new video may start earlier or later than the old one. It is transcribed
        (about 1½ minutes per hour), and the two transcriptions say how far apart the
        two videos' clocks are. transcript.md keeps its text, clips, speakers and
        notes; only `source:`, the Zoom offset and the paragraph times change.

        When the clocks stay the same distance apart throughout, the old word timings
        are kept and moved by that distance, so every cut lands where it did. When
        they drift (two separately recorded files), word times come from the new
        transcription instead, and every clip whose length changed by more than 0.1 s
        is listed: check its start and end.

        The old words.tsv is kept as cache/words.before-replace.tsv. cache/faces.tsv
        is removed, because it was scanned from the old video; --faces scans the new
        one and says how the speakers with a face changed.

        EXAMPLE
          octoedit replace-video --video seminar-4k.mov seminar.octoedit --faces
        """
    )

    @Option(name: .long, help: "The new input video.")
    var video: String

    @Flag(help: "Also find faces in the new video (as `octoedit faces`).")
    var faces = false

    @Flag(help: "Print the result as JSON on stdout.")
    var json = false

    @Argument(help: "The .octoedit package.")
    var package: String

    struct Report: Encodable {
        struct Video: Encodable { var path: String; var width: Int?; var height: Int? }
        struct ClipOut: Encodable { var slug: String; var name: String?; var before: Double; var after: Double; var changed: Bool }
        struct Faces: Encodable { var now: [String]; var gained: [String]; var lost: [String] }
        var before: Video
        var after: Video
        var zoomOffset: Double?
        /// Seconds the new video's clock is ahead of the old one's (new = old + offset).
        var offset: Double?
        /// True: old word timings kept and shifted. False: re-timed from the new transcription.
        var keptOldTimes: Bool
        var clips: [ClipOut]
        var faces: Faces?
    }

    func run() async throws {
        let pkg = URL(cliPath: package)
        let videoURL = URL(cliPath: video)
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoURL.path) else { throw ValidationError("no such video: \(videoURL.path)") }
        let before = try PackageReader.load(pkg)
        guard !before.hasErrors else {
            Console.issues(before.issues, file: pkg.appendingPathComponent(PackageLayout.transcript).path)
            throw ValidationError("fix the errors in transcript.md first")
        }
        let facesBefore = PackageReader.loadFaces(pkg).map { Self.matched($0, before.project) } ?? []
        let oldInfo = try? await SourceInfo.read(before.sourceURL)
        let newInfo = try await SourceInfo.read(videoURL)

        // The package's own copy of the Zoom transcript, so the new words read as the old ones did.
        var zoomURL = before.project.zoom.map { pkg.appendingPathComponent($0.file) }
        if let z = zoomURL, !fm.fileExists(atPath: z.path) {
            Console.note("The package has no \(z.lastPathComponent), so the Zoom offset is left as it was.")
            zoomURL = nil
        }
        let started = Date()
        let ingest = Ingest(transcriber: AppleSpeechTranscriber(), analyzer: AssetEnvelopeAnalyzer())
        let result = try await ingest.run(video: videoURL, zoom: zoomURL, settings: before.project.settings) { stage, fraction in
            Console.progress(stage.rawValue, fraction)
        }
        let oldWords = try PackageReader.loadWords(pkg)
        let retiming = ReplaceCheck.retiming(old: oldWords, new: result.words, oldEnvelope: before.envelope, newEnvelope: result.envelope)
        let project = ReplaceCheck.retarget(before.project, to: result.project, retiming: retiming)
        try PackageWriter.saveReplacingVideo(project, words: retiming.words, envelope: result.envelope, to: pkg)
        // Load re-times the text against the new words.tsv; saving that writes the paragraph times to match.
        try PackageWriter.save(try PackageReader.load(pkg).project, to: pkg)
        let after = try PackageReader.load(pkg)

        Console.note(String(format: "Replaced %@%@ with %@ (%d×%d) in %.0f s.", before.sourceURL.lastPathComponent,
                            oldInfo.map { " (\($0.width)×\($0.height))" } ?? "", videoURL.lastPathComponent,
                            newInfo.width, newInfo.height, Date().timeIntervalSince(started)))
        Console.note(retiming.summary)
        let changes = ReplaceCheck.clips(before: before.project, after: after.project, duration: newInfo.duration)
        let changed = changes.filter(\.changed)
        if changes.isEmpty {
            Console.note("No clips to check.")
        } else if changed.isEmpty {
            Console.note("All \(changes.count) clips kept their length.")
        } else {
            Console.note("\(changed.count) of \(changes.count) clips need a look:")
            for issue in ReplaceCheck.issues(changes) { Console.note("  " + issue.message) }
        }

        var faceChange: ReplaceCheck.FaceChange?
        if faces {
            let now = try await FacesCommand.build(pkg, source: videoURL, project: after.project)
            let change = ReplaceCheck.faces(before: facesBefore, after: now, speakers: after.project.speakersInOrder())
            if !facesBefore.isEmpty { Console.note(change.summary) }
            faceChange = change
        } else if !facesBefore.isEmpty {
            Console.note("Faces were found in the old video; run `octoedit faces` to find them in the new one.")
        }
        if json {
            JSONReport.emit(Report(
                before: .init(path: before.sourceURL.path, width: oldInfo?.width, height: oldInfo?.height),
                after: .init(path: videoURL.path, width: newInfo.width, height: newInfo.height),
                zoomOffset: after.project.zoom?.offset,
                offset: retiming.shift.map { ($0.offset * 1000).rounded() / 1000 }, keptOldTimes: retiming.keptOldTimes,
                clips: changes.map { .init(slug: $0.slug, name: $0.name, before: ($0.before * 10).rounded() / 10,
                                           after: ($0.after * 10).rounded() / 10, changed: $0.changed) },
                faces: faceChange.map { .init(now: $0.now, gained: $0.gained, lost: $0.lost) }))
        } else {
            print(pkg.path)
        }
    }

    /// Speakers who have a face in this face cache.
    static func matched(_ faces: FaceTracks, _ project: Project) -> Set<String> {
        Set(FaceLabels(faces: faces, project: project).tracks.compactMap(\.speaker))
    }
}
