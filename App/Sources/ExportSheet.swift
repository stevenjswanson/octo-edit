import AppKit
import SwiftUI
import Core

/// File ▸ Export Clips…: choose clips, codec and folder; watch them export.
struct ExportSheet: View {
    @Bindable var export: ExportModel
    let model: DocumentModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Clips").font(.title3.weight(.semibold))

            ScrollViewReader { proxy in
            List {
                ForEach($export.rows) { $row in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $row.include).labelsHidden().disabled(export.isExporting)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).lineLimit(1)
                            Text(row.slug + ".mp4").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        status(row)
                        Text(ClipShelf.duration(row.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    .id(row.id)
                }
            }
            .frame(minHeight: 180, idealHeight: 260)
            .onChange(of: export.currentRow) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            }

            HStack {
                Button("All") { for i in export.rows.indices { export.rows[i].include = true } }
                Button("None") { for i in export.rows.indices { export.rows[i].include = false } }
                Spacer()
                Text("\(export.includedCount) clip\(export.includedCount == 1 ? "" : "s"), \(ClipShelf.duration(export.totalDuration))")
                    .foregroundStyle(.secondary)
            }
            .disabled(export.isExporting)

            Form {
                Picker("Codec", selection: $export.codec) {
                    Text("Same as video" + (export.sourceCodec.map { " (\($0.rawValue.uppercased()))" } ?? "")).tag(Codec?.none)
                    ForEach(Codec.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag(Codec?.some($0)) }
                }
                .fixedSize()
                LabeledContent("Folder") {
                    HStack {
                        Text(export.destination?.path ?? "—").lineLimit(1).truncationMode(.middle)
                            .help(export.destination?.path ?? "")
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                LabeledContent("Make") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Individual clips", isOn: $export.individualClips)
                        HStack(spacing: 6) {
                            Toggle("Supercut — the checked clips joined in order", isOn: $export.supercut)
                            supercutStatus
                        }
                    }
                }
                Toggle("Show in Finder when done", isOn: $export.revealWhenDone)
            }
            .disabled(export.isExporting)

            if !export.sourceSummary.isEmpty {
                Text("Full resolution and frame rate of the video (\(export.sourceSummary)), hardware-encoded. Existing files with the same names are replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            footer
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private func status(_ row: ExportModel.Row) -> some View {
        switch row.state {
        case .waiting, .skipped: EmptyView()
        case .exporting: ProgressView(value: row.progress).frame(width: 110)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(m)
        }
    }

    @ViewBuilder private var supercutStatus: some View {
        switch export.supercutState {
        case .exporting: ProgressView(value: export.supercutProgress).frame(width: 80)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(m)
        default: EmptyView()
        }
    }

    @ViewBuilder private var footer: some View {
        if export.isExporting {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: export.overall)
                HStack {
                    Text(export.currentLabel).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int((export.overall * 100).rounded()))%").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack {
            switch export.phase {
            case .finished(let m): Text(m).foregroundStyle(.secondary)
            case .failed(let m): Label(m, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
            default: EmptyView()
            }
            Spacer()
            if export.isExporting {
                Button("Cancel", role: .cancel) { export.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                if case .finished = export.phase, let dest = export.destination {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Export") {
                    guard let source = model.sourceURL else { return }
                    let name = model.packageURL?.deletingPathExtension().lastPathComponent ?? ""
                    export.start(project: model.project, source: source, packageName: name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!export.canExport || model.sourceMissing || model.loadErrors)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = export.destination
        if panel.runModal() == .OK, let url = panel.url { export.destination = url }
    }
}
