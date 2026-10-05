import SwiftUI
import Core

/// Under the clip preview: the selected clip's name (with ✨ suggestions), the file it
/// will export to, and its notes. Edits commit on Return / leaving the field, each as
/// one undoable change.
struct ClipInfoPanel: View {
    let model: DocumentModel
    let clipID: ClipID

    @State private var name = ""
    @State private var notes = ""
    @FocusState private var focus: Field?
    private enum Field { case name, notes }

    var body: some View {
        let clip = model.project.clip(clipID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Clip name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onSubmit { commitName() }
                if model.suggesting.contains(clipID) {
                    ProgressView().controlSize(.small).frame(width: 28)
                } else {
                    Button { model.suggestNames(for: clipID) } label: { Image(systemName: "sparkles") }
                        .help("Suggest names (⌥⌘N)")
                        .disabled(!model.canEdit)
                }
                if let suggestions = clip?.suggestions, !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) {
                                name = s
                                model.rename(clipID, to: s)
                            }
                        }
                    } label: { Text("Suggestions") }
                    .fixedSize()
                    .disabled(!model.canEdit)
                }
            }
            Text("File: \(model.project.slug(of: clipID) ?? "")" + ".mp4")
                .font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.callout)
                    .focused($focus, equals: .notes)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                if notes.isEmpty && focus != .notes {
                    Text("Notes (saved with the project; exported as the clip's .md file)")
                        .font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 64)
        }
        .disabled(!model.canEdit)
        .padding(.horizontal, 10).padding(.bottom, 8)
        .onAppear(perform: load)
        .onChange(of: clipID) { old, _ in
            commit(old)
            load()
        }
        .onChange(of: clip?.name) { _, _ in if focus != .name { load() } }
        .onChange(of: clip?.notes) { _, _ in if focus != .notes { load() } }
        .onChange(of: focus) { old, _ in
            if old == .name { commitName() }
            if old == .notes { model.setNotes(clipID, notes) }
        }
        .onDisappear { commit(clipID) }
        .onChange(of: model.renameRequest) { _, _ in focus = .name }
    }

    private func load() {
        let clip = model.project.clip(clipID)
        name = clip?.name ?? ""
        notes = clip?.notes ?? ""
    }

    private func commitName() { model.rename(clipID, to: name) }

    /// Saves pending edits for `id` (e.g. when the selection moves to another clip).
    private func commit(_ id: ClipID) {
        guard model.project.clip(id) != nil else { return }
        if (model.project.clip(id)?.name ?? "") != name.trimmingCharacters(in: .whitespacesAndNewlines) {
            model.rename(id, to: name)
        }
        if model.project.clip(id)?.notes != notes.trimmingCharacters(in: .whitespacesAndNewlines) {
            model.setNotes(id, notes)
        }
    }
}
