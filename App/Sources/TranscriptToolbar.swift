import SwiftUI

/// Above the transcript: Cut / Edit Text mode, search, and Follow playhead.
struct TranscriptToolbar: View {
    @Bindable var model: DocumentModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: Binding(get: { model.textEditing }, set: { on in
                if on != model.textEditing { model.toggleTextEditing() }
            })) {
                Text("Cut").tag(false)
                Text("Edit Text").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.loadErrors)
            .help("Cut: mark clips and omissions. Edit Text: fix words (⇧⌘T); clips and timing are kept.")

            if model.textEditing {
                Text("Editing words — clips and timing are kept. Changes apply when you switch back to Cut.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                    .focused($searchFocused)
                    .onSubmit { model.findNext() }
                if !model.searchText.isEmpty {
                    Text(model.searchStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        .help("Previous match (⇧⌘G)")
                    Button { model.findNext() } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        .help("Next match (⌘G)")
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Toggle("Follow playhead", isOn: $model.followPlayhead)
                .toggleStyle(.checkbox)
                .help("Keep the playing word in view while a video plays")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
    }
}
