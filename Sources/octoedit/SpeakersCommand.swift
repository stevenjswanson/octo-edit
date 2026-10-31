import Foundation
import ArgumentParser
import Core
import Ingest
import Load
import Save
import Naming
import Diarize
import Render

struct SpeakersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers",
        abstract: "Find who speaks when and name the speakers.",
        discussion: """
        Listens to the video's voices, starts a new paragraph wherever the voice
        changes, and names each voice from the roster (front matter `speakers:`, or
        --speakers). Voices it can't name become Speaker 1, Speaker 2, …; rename them
        in transcript.md or the app. Every speaker name is reset, including names you
        fixed by hand. Clip and omission markers stay on their words.
        Takes about half a minute per hour of video.

        Prints turns shorter than a second: voice detection is least reliable there.

        EXAMPLE
          octoedit speakers seminar.octoedit --speakers "Mia Minnes, Kathy, Ori, Leena, Steve Swanson"
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Option(help: "The roster, comma-separated; replaces the one in transcript.md.")
    var speakers: String?

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        let transcript = pkg.appendingPathComponent("transcript.md").path
        if loaded.hasErrors {
            Console.issues(loaded.issues, file: transcript)
            Console.note("Fix transcript.md first.")
            throw ExitCode.failure
        }
        var p = loaded.project
        if let speakers { p.speakers = Roster.parse(speakers) }
        p.speakers.removeAll(where: Roster.isPlaceholder)
        let cues = p.zoom.flatMap { try? String(contentsOf: pkg.appendingPathComponent($0.file), encoding: .utf8) }
            .map(ZoomVTT.parse) ?? []

        Console.note("Every speaker name will be reset, including hand fixes.")
        let turns = try await FluidAudioDiarizer().diarize(audio: loaded.sourceURL) { Console.progress("Finding voices", $0) }
        let (namer, reason) = SpeakerNamers.preferred()
        if let reason { Console.note("Naming voices from textual cues only, because \(reason).") }
        let report = await SpeakerID.identify(&p, turns: turns, cues: cues, namer: namer)
        try PackageWriter.save(p, to: pkg)
        Console.report(report)
    }
}

enum Roster {
    /// "Mia Minnes, Kathy, Ori" → names, trimmed, blanks and repeats dropped.
    static func parse(_ s: String) -> [String] {
        var out: [String] = []
        for part in s.split(separator: ",") {
            let n = part.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty, !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// `Speaker 3`: a name a previous run made up, not a real one.
    static func isPlaceholder(_ name: String) -> Bool {
        let n = name.dropFirst("Speaker ".count)
        return name.hasPrefix("Speaker ") && !n.isEmpty && n.allSatisfy(\.isNumber)
    }
}

extension Console {
    static func report(_ r: SpeakerID.Report) {
        let voices = r.names.keys.sorted { (r.seconds[$0] ?? 0) > (r.seconds[$1] ?? 0) }
        note("Found \(voices.count) voices:")
        for v in voices {
            let mark = r.matched.contains(v) ? "" : "   (not recognised; rename it)"
            note("  \(r.names[v]!)  \(Captions.clock(r.seconds[v] ?? 0))\(mark)")
        }
        note("Paragraphs: \(r.paragraphsBefore) → \(r.paragraphsAfter); \(r.changedWords) words changed speaker.")
        if !r.shortTurns.isEmpty {
            note("Short turns to check (under a second):")
            for t in r.shortTurns.prefix(40) {
                note("  \(Captions.clock(t.start))  \(t.speaker ?? "?"): \(t.text)")
            }
            if r.shortTurns.count > 40 { note("  …and \(r.shortTurns.count - 40) more.") }
        }
    }
}
