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
                    .focusOutline(model.activePane == .source)
                    .frame(minWidth: 420, idealWidth: 820)
                ClipPreviewPane(model: model, preview: model.preview, focus: { model.focus(.preview) })
                    .focusOutline(model.activePane == .preview)
                    .frame(minWidth: 300, idealWidth: 520)
            }
            .frame(minHeight: 240, idealHeight: 420)

            VStack(spacing: 0) {
                TranscriptToolbar(model: model)
                Divider()
                if !model.issues.isEmpty { IssuesBanner(issues: model.issues) }
                TranscriptView(model: model, revision: model.revision, selectedClip: model.selectedClip,
                               currentWord: model.currentWord, followPlayhead: model.anyPlaying && model.followPlayhead,
                               reveal: model.reveal, inspected: model.inspected,
                               inspectRequest: model.inspectRequest, textEditing: model.textEditing,
                               searchText: model.searchText, searchStep: model.searchStep.id)
                    .overlay(alignment: .bottom) {
                        if let toast = model.toast {
                            Text(toast.text)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 12)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: model.toast?.id)
            }
            .frame(minHeight: 200, idealHeight: 380)

            ClipShelf(model: model)
                .frame(minHeight: 120, idealHeight: 128, maxHeight: 160)
        }
        .sheet(isPresented: Binding(get: { model.showingExport }, set: { model.showingExport = $0 })) {
            ExportSheet(export: model.exporter, model: model, close: { model.showingExport = false })
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
                PlayerView(player: model.player, onFocus: { model.focus(.source) })
                    .overlay(alignment: .topTrailing) { SpeedBadge(watcher: model.sourceSpeed) }
            }
        }
    }
}

/// Plays the selected clip exactly as it will export (omissions cut, crossfades in).
struct ClipPreviewPane: View {
    let model: DocumentModel
    let preview: PreviewModel
    let focus: () -> Void
    @Bindable private var settings = PlaybackSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(preview.title.isEmpty ? "Clip preview" : preview.title)
                    .font(.headline).lineLimit(1)
                Spacer()
                Toggle("Auto preview", isOn: $settings.autoPreview)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("After an edit, play the spot that changed (⇧⌘P)")
                if preview.building { ProgressView().controlSize(.small) }
                if preview.duration > 0 {
                    Text(ClipShelf.duration(preview.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ZStack {
                Color.black
                if let message = preview.message {
                    Text(message).foregroundStyle(.secondary)
                } else {
                    PlayerView(player: preview.player, onFocus: focus)
                        .overlay(alignment: .topTrailing) { SpeedBadge(watcher: model.previewSpeed) }
                }
            }
            SegmentStrip(segments: preview.segments, duration: preview.duration)
                .frame(height: 8)
                .padding(.horizontal, 10).padding(.vertical, 6)
            if let id = model.selectedClip, model.project.clip(id) != nil {
                ClipInfoPanel(model: model, clipID: id)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

extension View {
    /// The video pane Space controls gets an accent outline.
    func focusOutline(_ on: Bool) -> some View {
        overlay(Rectangle().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
    }
}

/// The kept segments of the previewed clip, end to end; the gaps mark the joins.
struct SegmentStrip: View {
    let segments: [(start: Double, duration: Double)]
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = segments.count > 1 ? 3 : 0
            let usable = max(geo.size.width - gap * CGFloat(max(segments.count - 1, 0)), 0)
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7))
                        .frame(width: duration > 0 ? usable * s.duration / duration : 0)
                }
            }
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
