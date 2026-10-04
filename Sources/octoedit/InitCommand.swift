import Foundation
import ArgumentParser
import Core
import Ingest
import Save
import Transcribe
import Waveform

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a project from a video (and optionally its Zoom transcript).",
        discussion: """
        Transcribes the video's first audio track on this Mac (English), tightens word
        edges against the audio, and, with --zoom, takes speaker names and text from the
        Zoom transcript. Writes an un-annotated transcript.md into the package.
        """
    )

    @Option(name: .long, help: "The input video.")
    var video: String

    @Option(name: .long, help: "Zoom transcript (.vtt) of the same meeting.")
    var zoom: String?

    @Option(help: "Default lead-in before a clip's first word.")
    var pre: Milliseconds?

    @Option(help: "Default tail after a clip's last word.")
    var post: Milliseconds?

    @Option(help: "Audio crossfade at cut points.")
    var crossfade: Milliseconds?

    @Option(help: "Output codec (default: same as the input).")
    var codec: Codec?

    @Flag(help: "Replace an existing package.")
    var force = false

    @Argument(help: "The package to create, e.g. meeting.octoedit")
    var package: String

    func run() async throws {
        let videoURL = URL(cliPath: video)
        let zoomURL = zoom.map(URL.init(cliPath:))
        var pkg = URL(cliPath: package)
        if pkg.pathExtension != "octoedit" { pkg = pkg.appendingPathExtension("octoedit") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: videoURL.path) else { throw ValidationError("no such video: \(videoURL.path)") }
        if let z = zoomURL, !fm.fileExists(atPath: z.path) { throw ValidationError("no such transcript: \(z.path)") }
        if fm.fileExists(atPath: pkg.path) {
            guard force else { throw ValidationError("\(pkg.path) already exists (use --force to replace it)") }
            try fm.removeItem(at: pkg)
        }

        var settings = ProjectSettings()
        if let pre { settings.prePad = pre.seconds }
        if let post { settings.postPad = post.seconds }
        if let crossfade { settings.crossfade = crossfade.seconds }
        settings.codec = codec

        let started = Date()
        let ingest = Ingest(transcriber: AppleSpeechTranscriber(), analyzer: AssetEnvelopeAnalyzer())
        let result = try await ingest.run(video: videoURL, zoom: zoomURL, settings: settings) { stage, fraction in
            Console.progress(stage.rawValue, fraction)
        }
        // Ingest → Save, and nothing else.
        try PackageWriter.save(result.project, to: pkg,
                               options: .init(words: result.words, envelope: result.envelope, zoomTranscript: zoomURL))
        let p = result.project
        let speakers = Set(p.paragraphs.compactMap(\.speaker)).sorted()
        Console.note(String(format: "Transcribed %d words in %d paragraphs in %.0f s.", p.words.count, p.paragraphs.count,
                            Date().timeIntervalSince(started)))
        if !speakers.isEmpty { Console.note("Speakers: " + speakers.joined(separator: ", ")) }
        if let z = p.zoom { Console.note(String(format: "Zoom transcript runs %.2f s ahead of the video.", z.offset)) }
        Console.note("Mark clips in \(pkg.appendingPathComponent("transcript.md").path), then run `octoedit render`.")
        print(pkg.path)
    }
}
