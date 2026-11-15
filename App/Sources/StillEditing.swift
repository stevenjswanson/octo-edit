import AppKit
import Observation
import Core
import Load
import Save
import FaceTrack
import SpeakerFraming
import Render

/// The title-card still of each clip, for the clip panel: the automatic pick, the
/// chosen one (`still=`), thumbnails, and the picker's candidates. Worked out in the
/// background from cache/faces.tsv; frame scores are remembered in cache/stills.tsv.
@MainActor @Observable
final class StillStore {
    struct Entry {
        /// What it was worked out from (clip, speakers, faces); a change means redo.
        var key: Int
        var automatic: TitleStills.Choice?
        /// The `still=` frame, when the clip has one.
        var chosen: TitleStills.Choice?
        var image: NSImage?
        var current: TitleStills.Choice? { chosen ?? automatic }
    }

    struct Option: Identifiable {
        var t: Seconds
        var origin: StillPicker.Candidate.Origin
        var score: StillScore?
        var face: FaceBox?
        var id: Int { Int((t * 1000).rounded()) }
    }

    private(set) var entries: [ClipID: Entry] = [:]
    /// Clips being worked out.
    private(set) var working: Set<ClipID> = []
    /// The picker's candidates per clip, with the key they were made for.
    private(set) var options: [ClipID: (key: Int, list: [Option])] = [:]
    private(set) var loadingOptions: Set<ClipID> = []
    /// Picker thumbnails by source time in milliseconds.
    private(set) var images: [Int: NSImage] = [:]
    /// Why there is no still (no faces yet, say), for the panel.
    private(set) var problem: String?

    /// Frame scores so far (nil until read from the cache).
    @ObservationIgnored var scores: [StillScore]?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    func reset() {
        entries = [:]; options = [:]; images = [:]; working = []; loadingOptions = []; latest = [:]
        scores = nil; problem = nil
    }

    // MARK: Inputs from the model

    struct Inputs {
        var project: Project
        var clip: Clip
        var source: URL
        var package: URL?
        var faces: FaceTracks
        var labels: FaceLabels?
        var key: Int
    }

    private func stills(_ i: Inputs) -> TitleStills {
        if scores == nil { scores = i.package.map(PackageReader.loadStillScores) ?? [] }
        return TitleStills(video: i.source, faces: i.faces, project: i.project, scorer: VisionStillScorer(),
                           scores: scores ?? [], labels: i.labels)
    }

    /// Takes in scores a TitleStills worked out, and saves the cache soon after.
    func absorb(_ s: TitleStills, package: URL?) async {
        guard await s.unsaved else { return }
        var merged = Dictionary((scores ?? []).map { (Int(($0.t * 1000).rounded()), $0) }, uniquingKeysWith: { a, _ in a })
        for (k, v) in await s.scores { merged[k] = v }
        scores = Array(merged.values)
        guard let package else { return }
        saveTask?.cancel()
        let snapshot = scores ?? []
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? PackageWriter.saveStillScores(snapshot, to: package)
        }
    }

    func noFaces(_ why: String) { problem = why }

    /// The key of the newest refresh asked for, per clip; an older one that finishes
    /// late is thrown away.
    @ObservationIgnored private var latest: [ClipID: Int] = [:]

    /// Works out the clip's still (and its thumbnail) unless it is already up to date.
    /// A newer request supersedes one still running.
    func refresh(_ i: Inputs) {
        problem = nil
        let id = i.clip.id
        guard entries[id]?.key != i.key, latest[id] != i.key else { return }
        latest[id] = i.key
        working.insert(id)
        // Show the picker's thumbnail of the new frame at once, until the full one is drawn.
        if let t = i.clip.still ?? entries[id]?.automatic?.t, let quick = images[Int((t * 1000).rounded())] {
            entries[id]?.image = quick
        }
        let s = stills(i)
        Task {
            defer { if latest[id] == i.key { working.remove(id); latest[id] = nil } }
            do {
                let auto = try await s.automaticChoice(for: i.clip, in: i.project)
                let chosen = i.clip.still == nil ? nil : try await s.choice(for: i.clip, in: i.project)
                var entry = Entry(key: i.key, automatic: auto, chosen: chosen)
                if let c = entry.current {
                    let levels = i.clip.autoLevels
                        ? try? await StillImage.levels(source: i.source, segments: i.project.resolvedSegments(of: i.clip)) : nil
                    if let cg = try? await StillImage.render(source: i.source, at: c.t, faceX: c.face?.centerX,
                                                             framing: i.project.settings.framing, levels: levels, maxHeight: 960) {
                        entry.image = NSImage(cgImage: cg, size: .zero)
                    }
                }
                await absorb(s, package: i.package)
                guard latest[id] == i.key else { return }   // the clip changed meanwhile
                entries[id] = entry
            } catch {
                if latest[id] == i.key { problem = "Couldn't pick a still: \(error.localizedDescription)" }
            }
        }
    }

    /// Scores the clip's candidates for the picker, then draws their thumbnails.
    func loadOptions(_ i: Inputs) {
        let id = i.clip.id
        guard options[id]?.key != i.key, !loadingOptions.contains(id) else { return }
        loadingOptions.insert(id)
        let s = stills(i)
        Task {
            defer { loadingOptions.remove(id) }
            guard let found = try? await s.candidates(for: i.clip, in: i.project) else { return }
            let list = found.map { Option(t: $0.candidate.t, origin: $0.candidate.origin, score: $0.score,
                                          face: $0.score?.face ?? $0.candidate.face) }
            options[id] = (i.key, list)
            await absorb(s, package: i.package)
            var wanted = list
            // A chosen still that isn't a candidate gets a thumbnail too.
            if let c = i.clip.still, !list.contains(where: { abs($0.t - c) < 0.0005 }), let e = entries[id]?.chosen {
                wanted.append(Option(t: c, origin: .talk, score: e.score, face: e.face))
            }
            for o in wanted where images[o.id] == nil {
                guard let cg = try? await StillImage.render(source: i.source, at: o.t, faceX: o.face?.centerX,
                                                            framing: i.project.settings.framing, levels: nil, maxHeight: 640)
                else { continue }
                images[o.id] = NSImage(cgImage: cg, size: .zero)
            }
        }
    }
}

extension DocumentModel {
    /// What a clip's still depends on, for telling when to work it out again.
    func stillKey(_ clip: Clip) -> Int {
        var h = Hasher()
        h.combine(clip.still)
        h.combine(clip.autoLevels)
        for s in project.resolvedSegments(of: clip) { h.combine(s.start); h.combine(s.end) }
        h.combine(faces?.frames.count)
        h.combine(project.settings.framing.rawValue)
        for p in project.paragraphs { h.combine(p.speaker) }
        return h.finalize()
    }

    private func stillInputs(_ id: ClipID) -> StillStore.Inputs? {
        guard let clip = project.clip(id), let source = sourceURL, !sourceMissing else { return nil }
        guard let faces else {
            stills.noFaces(findingFaces != nil ? "Finding faces…" : "Needs faces (Find Faces) to pick a still.")
            return nil
        }
        return StillStore.Inputs(project: project, clip: clip, source: source, package: packageURL, faces: faces,
                                 labels: faceLabels, key: stillKey(clip))
    }

    /// Works out the clip's still for the panel, if it isn't already.
    func refreshStill(_ id: ClipID) {
        if let i = stillInputs(id) { stills.refresh(i) }
    }

    /// Fills the picker for the clip.
    func loadStillOptions(_ id: ClipID) {
        if let i = stillInputs(id) { stills.loadOptions(i) }
    }

    /// Chooses the clip's title-card still (a source time), or nil for the automatic pick.
    func setStill(_ id: ClipID, _ t: Seconds?) {
        guard let clip = project.clip(id) else { return }
        if let t, let c = clip.still, abs(c - t) < 0.0005 { return }
        if t == nil, clip.still == nil { return }
        perform(t == nil ? "Use Automatic Still" : "Choose Still") { try $0.setStill(clip: id, t) }
    }

    /// A title-card picker for exports: the project's faces and the stills worked out so far.
    func titleStillsForExport(project p: Project, source: URL) -> TitleStills? {
        guard let faces else { return nil }
        if stills.scores == nil { stills.scores = packageURL.map(PackageReader.loadStillScores) ?? [] }
        return TitleStills(video: source, faces: faces, project: p, scorer: VisionStillScorer(),
                           scores: stills.scores ?? [], labels: faceLabels)
    }
}
