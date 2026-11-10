import SwiftUI
import Core
import Ingest

/// File ▸ Replace Video…: what the sheet shows while the new video is transcribed,
/// and afterwards. Mirrors `octoedit replace-video`; the steps are in ProjectDocument.
enum ReplaceVideoState: Equatable {
    case running(stage: String, fraction: Double)
    case done(ReplaceVideoResult)
    case failed(String)
}

struct ReplaceVideoResult: Equatable {
    /// "talk-proxy.mp4 1280×720"
    var before: String
    var after: String
    /// How far apart the two videos' clocks are, and whether the old word timings were kept.
    var shift: String?
    var changes: [ReplaceCheck.ClipChange]
}

extension DocumentModel {
    /// After the package was reloaded against the new video: mark the clips whose
    /// length changed, so they stay findable once the sheet is closed.
    func videoReplaced(_ changes: [ReplaceCheck.ClipChange]) {
        needsReview = Dictionary(uniqueKeysWithValues: changes.compactMap { c in c.reason.map { (c.clip, "Since Replace Video: " + $0) } })
    }

    /// Faces were found again after a Replace Video: say how the speakers with a face
    /// changed, and (for 9:16 projects) mark the clips of speakers who lost theirs.
    func reportFaceChange() {
        guard let before = facesBeforeReplace else { return }
        facesBeforeReplace = nil
        let after = Set(faceLabels?.tracks.compactMap(\.speaker) ?? [])
        let change = ReplaceCheck.faces(before: before, after: after, speakers: project.speakersInOrder())
        var note = change.summary
        if !change.lost.isEmpty, project.settings.framing == .portrait {
            var marked = 0
            for speaker in change.lost {
                for id in project.clips(withSpeaker: speaker) where needsReview[id] == nil {
                    needsReview[id] = "Since Replace Video: no face found for \(speaker), so 9:16 can’t follow them"
                    marked += 1
                }
            }
            if marked > 0 { note += " 9:16 clips where they speak are marked." }
        }
        replaceNote = note
    }
}

struct ReplaceVideoSheet: View {
    let model: DocumentModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.replacing {
            case .running(let stage, let fraction):
                Text("Replacing the video").font(.headline)
                Text("Transcribing the new video so your clips can be found in it. About 1½ minutes per hour of video.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: fraction) { Text(stage + "…").font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                }
            case .done(let result):
                Text("Video replaced").font(.headline)
                Text("\(result.before)  →  \(result.after)").font(.callout).textSelection(.enabled)
                if let shift = result.shift { Text(shift).font(.callout).foregroundStyle(.secondary) }
                comparison(result.changes)
                if model.findingFaces != nil {
                    Label("Finding faces in the new video in the background…", systemImage: "face.dashed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("This can’t be undone. The old word timings are in cache/words.before-replace.tsv.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { model.replacing = nil }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Text("Couldn’t replace the video").font(.headline)
                Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Nothing was changed.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { model.replacing = nil }.keyboardShortcut(.defaultAction)
                }
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder private func comparison(_ changes: [ReplaceCheck.ClipChange]) -> some View {
        let changed = changes.filter(\.changed).count
        let rows = changes.map { c in
            let name = c.name ?? c.slug
            return ClipComparison.Row(id: c.slug, here: .init(name: name, duration: c.before),
                                      disk: .init(name: c.reason == nil ? name : c.outside ? "partly outside the new video" : "check start and end", duration: c.after),
                                      marked: c.changed)
        }
        ClipComparison(rows: rows, diskProblem: nil, titles: ("Before", "After"),
                       summary: changes.isEmpty ? "The project has no clips yet."
                           : changed == 0 ? "All \(changes.count) clips kept their length."
                           : "\(changed) of \(changes.count) clips need a look (marked ●; they stay marked in the clip shelf until played). Click one to go to it.",
                       onSelect: { slug in
                           if let c = changes.first(where: { $0.slug == slug }) { model.shelfClick(c.clip, shift: false) }
                       })
    }
}

/// How the speakers' faces changed after a Replace Video; stays until dismissed.
struct ReplaceNoteBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "face.smiling")
            Text(text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.blue.opacity(0.12))
    }
}
