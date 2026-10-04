import SwiftUI
import Core

/// The project window: source video and clip preview on top, transcript in the
/// middle, clip shelf at the bottom.
struct DocumentView: View {
    let model: DocumentModel
    let document: ProjectDocument

    var body: some View {
        VSplitView {
            HSplitView {
                SourcePane(model: model, locate: document.locateSource)
                    .frame(minWidth: 420, idealWidth: 820)
                ClipPreviewPlaceholder()
                    .frame(minWidth: 300, idealWidth: 520)
            }
            .frame(minHeight: 240, idealHeight: 420)

            VStack(spacing: 0) {
                if !model.issues.isEmpty { IssuesBanner(issues: model.issues) }
                TranscriptView(project: model.project, revision: model.revision,
                               currentWord: model.currentWord, followPlayhead: model.isPlaying,
                               onClickWord: model.seek(toWord:))
            }
            .frame(minHeight: 200, idealHeight: 380)

            ClipShelf(model: model)
                .frame(minHeight: 70, idealHeight: 90, maxHeight: 140)
        }
    }
}

struct SourcePane: View {
    let model: DocumentModel
    let locate: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if model.sourceMissing {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Can’t find the input video").font(.headline)
                    Text(model.sourceURL?.path ?? "").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).multilineTextAlignment(.center)
                    Button("Locate…", action: locate)
                }
                .padding()
                .foregroundStyle(.white)
            } else {
                PlayerView(player: model.player)
            }
        }
    }
}

/// Filled in by B2 (clip preview playing the Render composition).
struct ClipPreviewPlaceholder: View {
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            Text("Clip preview").foregroundStyle(.secondary)
        }
    }
}

struct IssuesBanner: View {
    let issues: [Issue]
    @State private var expanded = false

    var body: some View {
        let errors = issues.filter { $0.severity == .error }
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Image(systemName: errors.isEmpty ? "exclamationmark.triangle" : "xmark.octagon")
                    Text(summary(errors: errors.count, warnings: issues.count - errors.count))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((errors + issues.filter { $0.severity == .warning }).enumerated()), id: \.offset) { _, issue in
                            Text(issue.description).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(errors.isEmpty ? Color.yellow.opacity(0.18) : Color.red.opacity(0.18))
    }

    private func summary(errors: Int, warnings: Int) -> String {
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s") in transcript.md — fix them in your editor; rendering is disabled") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
