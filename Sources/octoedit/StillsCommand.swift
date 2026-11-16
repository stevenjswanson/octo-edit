import Foundation
import ArgumentParser
import Core
import Load
import Save
import MarkupGrammar
import Render
import FaceTrack
import SpeakerFraming

struct StillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stills",
        abstract: "Show or choose each clip's title-card still.",
        discussion: """
        A clip's title card (brand-clip's .titlecard.png) is drawn over one frame of its
        main speaker, the first to speak in it (or of anyone, when chosen).
        `still=hh:mm:ss.mmm` on the clip's marker chooses it, as a time in the source
        recording (anywhere in the talk):

          {clip "How has software engineering changed?" +645ms still=00:58:01.233}

        Without it the still is picked automatically: the best frame in the clip's first
        10 s of kept video (face large and sharp, eyes open, mouth closed, no motion),
        or the talk's best frame of that speaker when the opening has nothing close.
        Exports write the still as <clip>.still.jpg beside the timeline, and the
        timeline's `titlecard` says which frame it is.

        Needs cache/faces.tsv (`octoedit faces`). Candidate frames are scored once each
        with Vision and remembered in cache/stills.tsv.

        With no options, lists every clip's still. --clip SLUG lists that clip's
        candidates instead: its main speaker's, then each other speaker with a
        labelled face (their best frames in the clip, then in the talk). --set SLUG=TIME chooses one (TIME as hh:mm:ss.mmm, a
        candidate's number from --clip, or `auto` to go back to the automatic pick)
        and saves transcript.md. --images DIR writes each still as a JPEG there.

        EXAMPLES
          octoedit stills seminar.octoedit
          octoedit stills seminar.octoedit --clip lightning-round
          octoedit stills seminar.octoedit --set lightning-round=3
          octoedit stills seminar.octoedit --set lightning-round=00:58:01.233
          octoedit stills seminar.octoedit --set lightning-round=auto
        """
    )

    @Argument(help: "The .octoedit package.")
    var package: String

    @Option(help: "List the candidates of the clip with this slug.")
    var clip: String?

    @Option(name: .customLong("set"), help: "SLUG=TIME, SLUG=N (a candidate) or SLUG=auto.")
    var assignments: [String] = []

    @Option(help: "Write each listed still (or candidate) as a JPEG into this folder.")
    var images: String?

    @Flag(help: "Print JSON.")
    var json = false

    func run() async throws {
        let pkg = URL(cliPath: package)
        let loaded = try PackageReader.load(pkg)
        if loaded.hasErrors {
            Console.issues(loaded.issues, file: pkg.appendingPathComponent("transcript.md").path)
            throw ExitCode.failure
        }
        var p = loaded.project
        guard let faces = PackageReader.loadFaces(pkg) else { throw ValidationError("no cache/faces.tsv; run `octoedit faces` first") }
        let stills = TitleStills(video: loaded.sourceURL, faces: faces, project: p, scorer: VisionStillScorer(),
                                 scores: PackageReader.loadStillScores(pkg))
        let slugs = p.slugs()
        /// The clip's candidates: its main speaker's, then every other labelled speaker's.
        func allCandidates(_ c: Clip) async throws -> [(candidate: StillPicker.Candidate, score: StillScore?)] {
            var out = try await stills.candidates(for: c, in: p)
            let main = StillPicker.mainSpeaker(of: c, in: p)
            for person in StillPicker.speakers(for: c, in: p, labels: stills.labelsForPicker) where person != main {
                out += try await stills.candidates(of: person, for: c, in: p)
                    .filter { o in !out.contains { abs($0.candidate.t - o.candidate.t) < 0.0005 } }
            }
            return out
        }
        func find(_ slug: String) throws -> Clip {
            guard let c = p.clips.first(where: { slugs[$0.id] == slug }) else {
                throw ValidationError("no clip named \(slug); clips are: " + p.clips.compactMap { slugs[$0.id] }.joined(separator: ", "))
            }
            return c
        }

        if !assignments.isEmpty {
            for a in assignments {
                guard let eq = a.firstIndex(of: "=") else { throw ValidationError("--set wants SLUG=TIME, SLUG=N or SLUG=auto") }
                let c = try find(String(a[..<eq]))
                let value = a[a.index(after: eq)...]
                let t: Seconds?
                if value == "auto" { t = nil }
                else if let n = Int(value) {
                    let cs = try await allCandidates(c)
                    guard (1...cs.count).contains(n) else { throw ValidationError("\(slugs[c.id]!) has \(cs.count) candidates") }
                    t = cs[n - 1].candidate.t
                } else if let v = Grammar.parseTimestamp(value) { t = v }
                else { throw ValidationError("\(value): give hh:mm:ss.mmm, a candidate number, or auto") }
                try p.setStill(clip: c.id, t)
            }
            try PackageWriter.save(p, to: pkg)
        }

        let folder = images.map(URL.init(cliPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func image(_ name: String, _ t: Seconds, _ face: FaceBox?, _ clip: Clip) async throws -> String? {
            guard let folder else { return nil }
            let levels = clip.autoLevels ? try await StillImage.levels(source: loaded.sourceURL, segments: p.resolvedSegments(of: clip)) : nil
            let img = try await StillImage.render(source: loaded.sourceURL, at: t, faceX: face?.centerX,
                                                  framing: p.settings.framing, levels: levels)
            let file = folder.appendingPathComponent(name + ".jpg")
            try StillImage.writeJPEG(img, to: file)
            return file.path
        }
        func fmt(_ s: StillScore?) -> String {
            guard let s else { return "unscored" }
            return String(format: "score %.2f  (quality %.2f, eyes %.2f, mouth %.2f)", s.total, s.quality, s.eyes, s.mouth)
        }

        var rows: [[String: Any]] = []
        if let slug = clip {
            let c = try find(slug)
            let cs = try await allCandidates(c)
            let pick = try await stills.choice(for: c, in: p)
            let main = StillPicker.mainSpeaker(of: c, in: p)
            var heading: String?? = .none
            for (n, (cand, score)) in cs.enumerated() {
                if !json, heading != .some(cand.speaker) {
                    heading = .some(cand.speaker)
                    print("— " + (cand.speaker ?? main ?? "main speaker") + (cand.speaker == nil || cand.speaker == main ? " (main speaker)" : ""))
                }
                let chosen = pick.map { abs($0.t - cand.t) < 0.0005 } ?? false
                let file = try await image(String(format: "%@-%02d", slug, n + 1), cand.t, score?.face ?? cand.face, c)
                rows.append(["n": n + 1, "time": Grammar.preciseTimestamp(cand.t), "seconds": cand.t, "from": cand.origin.rawValue, "speaker": cand.speaker ?? NSNull(),
                             "coarse": cand.coarse, "score": score?.total ?? 0, "chosen": chosen, "image": file ?? NSNull()])
                if !json {
                    print(String(format: "%2d %@ %@  %-7@ coarse %.2f  %@%@", n + 1, chosen ? "*" : " ",
                                 Grammar.preciseTimestamp(cand.t), cand.origin.rawValue, cand.coarse, fmt(score), file.map { "  " + $0 } ?? ""))
                }
            }
            if !json, let pick, !cs.contains(where: { abs($0.candidate.t - pick.t) < 0.0005 }) {
                print("   * \(Grammar.preciseTimestamp(pick.t))  chosen  \(fmt(pick.score))")
            }
        } else {
            for c in p.clips {
                let slug = slugs[c.id]!
                let pick = try await stills.choice(for: c, in: p)
                let file = try await pick.asyncMap { try await image(p.exportName(of: c.id) ?? slug, $0.t, $0.face, c) } ?? nil
                rows.append(["slug": slug, "time": pick.map { Grammar.preciseTimestamp($0.t) } ?? NSNull(),
                             "seconds": pick?.t ?? NSNull(), "auto": pick?.automatic ?? true,
                             "score": pick?.score?.total ?? 0, "image": file ?? NSNull()])
                if !json {
                    let when = pick.map { Grammar.preciseTimestamp($0.t) + ($0.automatic ? "  auto  " : "  chosen") } ?? "no face found"
                    print(slug.padding(toLength: max(44, slug.count), withPad: " ", startingAt: 0) + " " + when
                          + (pick.map { "  " + fmt($0.score) } ?? "") + (file.map { "  " + $0 } ?? ""))
                }
            }
        }
        await Self.saveScores(stills, pkg)
        if json {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    /// Writes cache/stills.tsv if new frames were scored.
    static func saveScores(_ stills: TitleStills, _ pkg: URL) async {
        guard await stills.unsaved else { return }
        let scores = await Array(stills.scores.values)
        do {
            try PackageWriter.saveStillScores(scores, to: pkg)
            await stills.markSaved()
        } catch {
            Console.note("Couldn't save cache/stills.tsv: \(error)")
        }
    }
}

extension Optional {
    func asyncMap<U>(_ f: (Wrapped) async throws -> U) async rethrows -> U? {
        switch self {
        case .some(let w): try await f(w)
        case .none: nil
        }
    }
}
