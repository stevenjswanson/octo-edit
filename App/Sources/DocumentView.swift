import SwiftUI
import Core

/// The project window: the video pane on top, transcript in the middle, clip shelf
/// at the bottom.
struct DocumentView: View {
    let model: DocumentModel
    let document: ProjectDocument

    var body: some View {
        VSplitView {
            VideoPane(model: model, preview: model.preview, locate: document.locateSource)
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
        .sheet(isPresented: Binding(get: { model.identifyRequest }, set: { model.identifyRequest = $0 })) {
            IdentifySpeakersSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.showingExport }, set: { model.showingExport = $0 })) {
            ExportSheet(export: model.exporter, model: model, close: { model.showingExport = false })
        }
    }
}

/// The video pane, with the selected clip's name, notes and Auto preview beside it.
/// The video is the selected clip exactly as it will export (omissions cut,
/// crossfades in), or the recording itself after a click outside every clip. Both
/// players stay alive so switching is instant.
struct VideoPane: View {
    let model: DocumentModel
    let preview: PreviewModel
    let locate: () -> Void
    @Bindable private var settings = PlaybackSettings.shared

    var body: some View {
        HSplitView {
            video
                .frame(minWidth: 420)
            VStack(alignment: .leading, spacing: 0) {
                if let id = model.selectedClip, model.project.clip(id) != nil {
                    ClipInfoPanel(model: model, clipID: id)
                } else {
                    Text("Select a clip to name it and add notes.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Toggle("Auto preview", isOn: $settings.autoPreview)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("After an edit, play the spot that changed (⇧⌘P)")
                    Toggle("9:16 preview", isOn: $settings.portraitPreview)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("Play clips cropped to a 9:16 column that follows the speaker, as a 9:16 export looks")
                        .onChange(of: settings.portraitPreview) { model.refreshPreviewNow() }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
                SpeakerFadeSlider(model: model)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var video: some View {
        let showingSource = model.activePane == .source
        return VStack(spacing: 0) {
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
                        .opacity(showingSource ? 1 : 0)
                        .allowsHitTesting(showingSource)
                    Group {
                        if let message = preview.message {
                            Text(message).foregroundStyle(.secondary)
                        } else {
                            PlayerView(player: preview.player, onFocus: { model.focus(.preview) })
                                .overlay(alignment: .topTrailing) { SpeedBadge(watcher: model.previewSpeed) }
                        }
                    }
                    .opacity(showingSource ? 0 : 1)
                    .allowsHitTesting(!showingSource)
                    if settings.showFaces {
                        FaceOverlay(model: model, preview: preview)
                    }
                    if preview.building && !showingSource {
                        ProgressView().controlSize(.small).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
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

/// 9:16: how long the column takes to move to a new speaker, fading to black and back
/// (0 cuts). A project setting, saved as `speakerFade` and used by exports; the
/// preview rebuilds when the slider is let go.
struct SpeakerFadeSlider: View {
    let model: DocumentModel
    @State private var value: Double?

    var body: some View {
        let shown = value ?? model.project.settings.speakerFade
        HStack(spacing: 6) {
            Text("Speaker fade").font(.caption)
            Slider(value: Binding(get: { shown }, set: { value = $0 }), in: 0...1, step: 0.05) { editing in
                if !editing, let v = value {
                    model.setSpeakerFade(v)
                    value = nil
                }
            }
            .controlSize(.small)
            Text(shown == 0 ? "cut" : String(format: "%.2f s", shown))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .disabled(!model.canEdit)
        .help("9:16: how long a move to a new speaker takes, fading to black and back in. Saved with the project; exports use it.")
    }
}
