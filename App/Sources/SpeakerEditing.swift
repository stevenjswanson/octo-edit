import AppKit
import AVFoundation
import SwiftUI
import Core
import Ingest
import Load
import Save
import Naming
import Diarize
import FaceTrack
import SpeakerFraming

/// Speaker colours follow first-appearance order (the Speakers panel's order).
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red]
    static func color(_ n: Int) -> Color { colors[n % colors.count] }
    static func nsColor(_ n: Int) -> NSColor { NSColor(color(n)) }
}

/// The roster and who says what: every change is a Core operation with its own undo.
extension DocumentModel {
    /// The roster in first-appearance order (the panel order).
    var speakerOrder: [String] { project.speakersInOrder() }

    func speakerColor(_ name: String) -> NSColor {
        SpeakerPalette.nsColor(speakerOrder.firstIndex(of: name) ?? 0)
    }

    /// Seconds of timed speech per speaker.
    var speakingTime: [String: Double] {
        let speakerOf = Dictionary(uniqueKeysWithValues: project.paragraphs.map { ($0.id, $0.speaker) })
        var out: [String: Double] = [:]
        for w in project.words {
            guard let s = w.start, let e = w.end, let name = speakerOf[w.paragraph] ?? nil else { continue }
            out[name, default: 0] += e - s
        }
        return out
    }

    func setSpeaker(of pid: ParagraphID, to name: String?) {
        perform("Set Speaker") { $0.setSpeaker(paragraph: pid, name) }
    }

    /// Gives the selected words to a speaker, splitting paragraphs at the selection's edges.
    func assignSelection(to name: String?) {
        guard let s = selection else {
            flash("Select the words to give to a speaker.")
            NSSound.beep()
            return
        }
        perform("Assign to Speaker") { try $0.assignSpeaker(words: s, name) }
    }

    func addSpeaker(_ name: String) {
        perform("Add Speaker") { $0.addSpeaker(name) }
    }

    /// Renames everywhere; renaming onto an existing name merges the two.
    func renameSpeaker(_ old: String, to new: String) {
        let merging = project.speakers.contains(new.trimmingCharacters(in: .whitespaces)) && new != old
        perform(merging ? "Merge Speakers" : "Rename Speaker") { $0.renameSpeaker(old, to: new) }
    }

    func removeSpeaker(_ name: String) {
        perform("Remove Speaker") { try $0.removeSpeaker(name) }
    }

    /// Asks for a name, then calls `then` with it (trimmed, non-empty).
    func askForSpeakerName(title: String, initial: String = "", button: String, in window: NSWindow?,
                           then: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let done: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if response == .alertFirstButtonReturn, !name.isEmpty { then(name) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// Identify Speakers…: finds who speaks when and names voices from `roster`,
    /// resetting every speaker name (one undo step). Mirrors `octoedit speakers`.
    func identifySpeakers(roster: [String]) {
        guard canEdit, identifyingSpeakers == nil, let url = sourceURL, !sourceMissing else { return }
        identifyingSpeakers = 0
        let cues = project.zoom.flatMap { z in packageURL.flatMap { try? String(contentsOf: $0.appendingPathComponent(z.file), encoding: .utf8) } }
            .map(ZoomVTT.parse) ?? []
        Task {
            defer { identifyingSpeakers = nil }
            do {
                let turns = try await FluidAudioDiarizer().diarize(audio: url) { f in
                    Task { @MainActor in if self.identifyingSpeakers != nil { self.identifyingSpeakers = f } }
                }
                var p = project
                p.speakers = roster
                let (namer, _) = SpeakerNamers.preferred()
                let report = await SpeakerID.identify(&p, turns: turns, cues: cues, namer: namer)
                let result = p
                perform("Identify Speakers") { $0 = result }
                let unnamed = report.names.count - report.matched.count
                flash("Found \(report.names.count) voices" + (unnamed > 0 ? "; \(unnamed) not recognised — rename them in Speakers." : ".")
                      + (report.shortTurns.isEmpty ? "" : " \(report.shortTurns.count) short turns are worth checking."))
            } catch {
                flash("Couldn’t identify speakers: \(error)")
            }
        }
    }
}

/// Speakers panel: one row per roster name in order of first appearance, with colour,
/// editable name (renames everywhere), speaking time, Merge into… and Remove.
struct SpeakersPanel: View {
    @Bindable var model: DocumentModel
    @State private var portraits = SpeakerPortraits()

    var body: some View {
        let order = model.speakerOrder
        let time = model.speakingTime
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers").font(.headline)
            if order.isEmpty {
                Text("No speakers yet. Add names, then Identify Speakers… to find who speaks when.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 280, alignment: .leading)
            }
            ForEach(Array(order.enumerated()), id: \.element) { n, name in
                SpeakerRow(model: model, index: n, name: name, seconds: time[name] ?? 0, others: order.filter { $0 != name },
                           portrait: portraits.images[name])
            }
            Divider()
            HStack {
                Button("Add Speaker…") {
                    model.askForSpeakerName(title: "New speaker", button: "Add", in: NSApp.keyWindow) { model.addSpeaker($0) }
                }
                Spacer()
                Button("Identify Speakers…") { model.identifyRequest = true; model.showingSpeakers = false }
                    .disabled(model.identifyingSpeakers != nil || model.sourceMissing)
            }
            if let f = model.findingFaces {
                HStack { ProgressView(value: f).frame(width: 80); Text("Finding faces…").font(.caption).foregroundStyle(.secondary) }
            } else if model.faces == nil {
                Button("Find Faces") { model.findFaces() }.disabled(model.sourceMissing)
                    .help("Scan the video for faces: speaker portraits here, and 9:16 framing that follows the speaker")
            }
            Text("To give words to a speaker, select them and right-click.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 320)
        .disabled(!model.canEdit)
        .task(id: model.revision + (model.faces == nil ? 0 : 1_000_000)) {
            portraits.update(model.faceLabels, source: model.sourceURL)
        }
    }
}

private struct SpeakerRow: View {
    let model: DocumentModel
    let index: Int
    let name: String
    let seconds: Double
    let others: [String]
    let portrait: NSImage?
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(index < 9 ? "⌥\(index + 1)" : "").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
            Circle().fill(SpeakerPalette.color(index)).frame(width: 10, height: 10)
            Group {
                if let portrait { Image(nsImage: portrait).resizable() } else { Image(systemName: "person.crop.square").resizable().foregroundStyle(.tertiary) }
            }
            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .frame(width: 150)
            Text(Self.clock(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Menu {
                Section("Merge into") {
                    ForEach(others, id: \.self) { other in
                        Button(other) { model.renameSpeaker(name, to: other) }
                    }
                }
                Button("Remove", role: .destructive) { model.removeSpeaker(name) }
                    .disabled(seconds > 0 || model.project.paragraphs.contains { $0.speaker == name })
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .onAppear { text = name }
        .onChange(of: name) { _, new in text = new }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { text = name } else if t != name { model.renameSpeaker(name, to: t) }
    }

    static func clock(_ s: Double) -> String {
        let m = Int(s) / 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, Int(s) % 60) : String(format: "%d:%02d", m, Int(s) % 60)
    }
}

/// Identify Speakers… sheet: confirm the roster, warn that names are reset.
struct IdentifySpeakersSheet: View {
    @Bindable var model: DocumentModel
    @State private var roster = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Identify Speakers").font(.headline)
            Text("Finds who speaks when from the voices, starts a paragraph at every voice change, and names voices from these names. Voices that can’t be named become Speaker 1, 2, … Every speaker name is reset, including your fixes (⌘Z undoes it). Clips stay as they are.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Names, comma-separated", text: $roster)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.identifyRequest = false }.keyboardShortcut(.cancelAction)
                Button("Identify") {
                    model.identifyRequest = false
                    model.identifySpeakers(roster: Roster.parse(roster))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            roster = model.project.speakers.filter { !Roster.isPlaceholder($0) }.joined(separator: ", ")
        }
    }
}

// MARK: Faces

extension DocumentModel {
    /// Reads cache/faces.tsv off the main thread; when it's missing and the project has
    /// speakers, finds faces in the background (about a third of the video's length).
    func loadFaces() {
        guard let package = packageURL else { return }
        Task.detached(priority: .utility) {
            let loaded = PackageReader.loadFaces(package)
            await MainActor.run {
                if let loaded { self.faces = loaded; self.refreshPreviewNow() } else if !self.project.speakersInOrder().isEmpty { self.findFaces() }
            }
        }
    }

    func findFaces() {
        guard findingFaces == nil, let url = sourceURL, !sourceMissing, let package = packageURL else { return }
        findingFaces = 0
        Task {
            defer { findingFaces = nil }
            do {
                let found = try await VisionFaceScanner().scan(video: url) { f in
                    Task { @MainActor in if self.findingFaces != nil { self.findingFaces = f } }
                }
                faces = found
                try? PackageWriter.saveFaces(found, to: package)
                refreshPreviewNow()
            } catch {
                flash("Couldn’t find faces: \(error)")
            }
        }
    }

    func setFraming(_ framing: Framing) {
        perform("Framing") { $0.settings.framing = framing }
    }

    /// Which face is whose, from the current paragraph speakers; recomputed only when
    /// the faces or the speakers' words change.
    var faceLabels: FaceLabels? {
        guard let faces else { return nil }
        var h = Hasher()
        h.combine(faces.frames.count)
        for p in project.paragraphs { h.combine(p.id.raw); h.combine(p.speaker) }
        h.combine(project.words.count)
        let key = h.finalize()
        if let cached = labelsCache, cached.key == key { return cached.labels }
        let labels = FaceLabels(faces: faces, project: project)
        labelsCache = (key, labels)
        return labels
    }
}

/// One face per speaker for the Speakers panel, cut from the video in memory.
@MainActor @Observable
final class SpeakerPortraits {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested: [String: Double] = [:]

    func update(_ labels: FaceLabels?, source: URL?) {
        guard let labels, let source else { return }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (name, sample) in labels.portraits() {
            if requested[name] == sample.t { continue }
            requested[name] = sample.t
            Task {
                guard let cg = try? await generator.image(at: CMTime(seconds: sample.t, preferredTimescale: 600)).image,
                      requested[name] == sample.t else { return }
                let b = sample.box
                // A square around the face, a bit larger than the face itself.
                let side = b.h * Double(cg.height) * 1.8
                let rect = CGRect(x: b.centerX * Double(cg.width) - side / 2, y: b.centerY * Double(cg.height) - side / 2,
                                  width: side, height: side).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                guard let crop = cg.cropping(to: rect) else { return }
                images[name] = NSImage(cgImage: crop, size: NSSize(width: 32, height: 32))
            }
        }
    }
}
