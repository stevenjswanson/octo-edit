import AppKit
import SwiftUI
import Core
import Render

/// File ▸ Export Clips…: choose clips and folder; watch them export. The codec is the
/// project's (front matter), else the same as the input video.
struct ExportSheet: View {
    @Bindable var export: ExportModel
    let model: DocumentModel
    let close: () -> Void
    @State private var editingPostExport = false
    @State private var shownOutput: String?

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
                            Text("\(row.slug)-\(export.label)\(model.project.settings.framing == .portrait ? "-9x16" : "").mp4").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                Picker("Resolution", selection: $export.resolution) {
                    Text("Full" + (export.sourceInfo.map { " (\(Renderer.resolutionLabel(.full, info: $0)), \($0.width)×\($0.height))" } ?? ""))
                        .tag(Renderer.Resolution.full)
                    Text("720p (1280×720)").tag(Renderer.Resolution.hd720)
                }
                .pickerStyle(.radioGroup)
                Picker("Framing", selection: Binding(get: { model.project.settings.framing }, set: { model.setFraming($0) })) {
                    Text("As recorded").tag(Framing.source)
                    Text("9:16, following the speaker").tag(Framing.portrait)
                }
                .pickerStyle(.radioGroup)
                .disabled(!model.canEdit)
                if model.project.settings.framing == .portrait && model.faces == nil {
                    Text(model.findingFaces == nil ? "No face tracks yet: the column stays centred. Find Faces in the Speakers panel."
                                                   : "Finding faces… exports made now keep the column centred.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                exportHook
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
                            Toggle("Supercut — the checked clips joined in order, with YouTube chapters", isOn: $export.supercut)
                            supercutStatus
                        }
                    }
                }
                Toggle("Show in Finder when done", isOn: $export.revealWhenDone)
            }
            .disabled(export.isExporting)

            if !export.sourceSummary.isEmpty {
                Text("Source: \(export.sourceSummary). Same frame rate, hardware-encoded; 720p is H.264. Files are named with the resolution, so 4k and 720p exports sit side by side; files with the same name are replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            footer
        }
        .padding(20)
        .frame(width: 560)
        .sheet(isPresented: $editingPostExport) {
            PostExportEditor(command: model.project.settings.postExport, package: model.packageURL) { edited in
                model.setPostExport(edited)
                editingPostExport = false
            } cancel: { editingPostExport = false }
        }
        .sheet(item: Binding(get: { shownOutput.map(OutputText.init) }, set: { shownOutput = $0?.text })) { out in
            VStack(alignment: .leading, spacing: 10) {
                Text("\(model.project.settings.postExport?.name ?? "Post-export") output").font(.headline)
                ScrollView {
                    Text(out.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200, idealHeight: 320)
                HStack { Spacer(); Button("Close") { shownOutput = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(16)
            .frame(width: 620)
        }
    }

    /// Export hook: the project's post-export program (front matter `post-export:`),
    /// e.g. brand-clip, so what lands in the folder is its result. The row looks the
    /// same with or without one; Configure Export Hook… is where it's set up.
    @ViewBuilder private var exportHook: some View {
        LabeledContent("Export hook") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let pe = model.project.settings.postExport {
                        Toggle("Run \(pe.name) on each clip", isOn: $export.runPostExport)
                            .help(([pe.run] + pe.args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Configure Export Hook…") { editingPostExport = true }
                        .disabled(!model.canEdit || model.packageURL == nil)
                }
                if let pe = model.project.settings.postExport,
                   let problem = model.packageURL.flatMap({ PostExportRunner.problem(pe, package: $0) }) {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private func status(_ row: ExportModel.Row) -> some View {
        switch row.state {
        case .waiting, .skipped: EmptyView()
        case .exporting: ProgressView(value: row.progress).frame(width: 110)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary).help("Exported; waiting for \(postExportName)")
        case .finishing: finishingStatus
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): failedStatus(m, output: row.output)
        }
    }

    @ViewBuilder private var supercutStatus: some View {
        switch export.supercutState {
        case .exporting: ProgressView(value: export.supercutProgress).frame(width: 80)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary).help("Joined; waiting for \(postExportName)")
        case .finishing: finishingStatus
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): failedStatus(m, output: export.supercutOutput)
        default: EmptyView()
        }
    }

    private var postExportName: String { model.project.settings.postExport?.name ?? "the post-export program" }

    private var finishingStatus: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text(postExportName).font(.caption).foregroundStyle(.secondary)
        }
        .help(export.postExportLine)
    }

    @ViewBuilder private func failedStatus(_ message: String, output: String?) -> some View {
        if let output, !output.isEmpty {
            Button { shownOutput = output } label: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(message + " — click for its output")
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(message)
        }
    }

    @ViewBuilder private var footer: some View {
        if export.isExporting {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: export.overall)
                HStack {
                    Text(export.postExportLine.isEmpty ? export.currentLabel : "\(postExportName): \(export.postExportLine)")
                        .lineLimit(1).truncationMode(.middle)
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
                    export.start(project: model.project, source: source, packageName: name, faces: model.faces,
                                 stills: model.titleStillsForExport(project: model.project, source: source))
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

/// Shelf ▸ Re-export: just a progress bar while one clip exports with the options
/// already set. Closes itself when the export succeeds; stays up to show a failure.
struct ReexportSheet: View {
    let export: ExportModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(export.currentLabel.isEmpty ? "Re-export" : export.currentLabel)
                .font(.headline).lineLimit(1).truncationMode(.middle)
            switch export.phase {
            case .failed(let m):
                Label(m, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
            case .finished(let m):
                Text(m).foregroundStyle(.secondary)
            default:
                ProgressView(value: export.overall)
                Text(export.destination?.path ?? "").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                if export.isExporting {
                    Button("Cancel", role: .cancel) { export.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: export.phase) { _, phase in
            if case .finished(let m) = phase, m.hasPrefix("Exported") { close() }
        }
    }
}

/// Text for the output sheet (`.sheet(item:)` needs Identifiable).
private struct OutputText: Identifiable {
    let text: String
    var id: String { text }
}

/// Export sheet ▸ Configure Export Hook…: the program run on each exported clip, and
/// its arguments. Opens the same way whether or not a hook is set.
struct PostExportEditor: View {
    @State private var run: String
    @State private var args: String
    private let existing: Bool
    let package: URL?
    let save: (PostExport?) -> Void
    let cancel: () -> Void

    init(command: PostExport?, package: URL?, save: @escaping (PostExport?) -> Void, cancel: @escaping () -> Void) {
        _run = State(initialValue: command?.run ?? "")
        _args = State(initialValue: PostExport.joinArguments(command?.args ?? PostExport.defaultArgs))
        existing = command != nil
        self.package = package
        self.save = save
        self.cancel = cancel
    }

    private var edited: PostExport {
        PostExport(run: run.trimmingCharacters(in: .whitespaces), args: PostExport.splitArguments(args))
    }

    /// What's wrong with the program as typed, if anything (nothing to check while empty).
    private var problem: String? {
        guard !edited.run.isEmpty else { return nil }
        guard let package else { return nil }
        return PostExportRunner.problem(edited, package: package)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a program to run on each exported clip (for example brand-clip)."
        if !edited.run.isEmpty, let package {
            panel.directoryURL = PostExportRunner.executable(edited, package: package).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // ~/… keeps the project usable from another account with the same layout.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        run = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configure Export Hook").font(.headline)
            Text("A program run on each exported clip, such as brand-clip. OctoEdit exports the clip, "
                 + "hands it to the program, and saves what the program writes in its place.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent("Program") {
                    HStack {
                        TextField("", text: $run, prompt: Text("none")).font(.system(.body, design: .monospaced)).labelsHidden()
                        Button("Choose…", action: choose)
                    }
                }
                LabeledContent("Arguments") {
                    HStack {
                        TextField("", text: $args).font(.system(.body, design: .monospaced)).labelsHidden()
                        Button("Default") { args = PostExport.joinArguments(PostExport.defaultArgs) }
                            .disabled(PostExport.splitArguments(args) == PostExport.defaultArgs)
                    }
                }
            }
            Text("Run in the project folder, without a shell. In the arguments, {timeline} and {video} are "
                 + "the plain export's files, {output} is the file to write (required), and {exports} is the "
                 + "export folder. Quote arguments that contain spaces.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if !edited.run.isEmpty && !edited.writesOutput {
                Label("The arguments need {output}.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if existing {
                    Button("Remove Hook") { save(nil) }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(edited.run.isEmpty ? nil : edited) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!edited.run.isEmpty && !edited.writesOutput)
            }
        }
        .padding(16)
        .frame(width: 580)
    }
}
