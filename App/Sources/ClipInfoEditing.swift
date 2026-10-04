import AppKit
import Core
import Naming

/// The app-wide clip namer: Apple's on-device model when Apple Intelligence is on,
/// otherwise the first-sentence heuristic (a ClaudeNamer would be swapped in here).
@MainActor
enum AppServices {
    static let namer = Namers.preferred()
}

/// Names, notes and name suggestions for clips.
extension DocumentModel {
    func rename(_ id: ClipID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.clip(id)?.name ?? "" != trimmed else { return }
        perform("Rename Clip") { try $0.setName(clip: id, trimmed.isEmpty ? nil : trimmed) }
    }

    func setNotes(_ id: ClipID, _ notes: String) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.clip(id)?.notes != trimmed else { return }
        perform("Edit Notes") { try $0.setNotes(clip: id, trimmed) }
    }

    /// ✨: asks the namer for titles for one clip and stores them as its suggestions
    /// (undoable; saved in transcript.md's front matter like `octoedit name`).
    func suggestNames(for id: ClipID) {
        guard let clip = project.clip(id), !suggesting.contains(id) else { return }
        suggesting.insert(id)
        let context = ClipContext(clip: clip, in: project)
        let (namer, fallback) = AppServices.namer
        if let fallback, !warnedAboutNamer {
            warnedAboutNamer = true
            flash("Using simple names: \(fallback)")
        }
        Task {
            defer { suggesting.remove(id) }
            do {
                let list = try await namer.suggest(for: context)
                let cleaned = Self.cleanSuggestions(list)
                guard !cleaned.isEmpty else { flash("No suggestions for this clip."); return }
                perform("Suggest Names") { try $0.setSuggestions(clip: id, cleaned) }
            } catch {
                flash("Couldn’t suggest names: \(error)")
            }
        }
    }

    /// Clip ▸ Name Unnamed Clips: suggests for every unnamed clip and names each from
    /// its top suggestion — one undo step for the lot.
    func nameUnnamedClips() {
        let unnamed = project.clips.filter { $0.name == nil }
        guard !unnamed.isEmpty else { flash("Every clip already has a name."); return }
        let contexts = unnamed.map { ($0.id, ClipContext(clip: $0, in: project)) }
        let (namer, fallback) = AppServices.namer
        flash("Naming \(unnamed.count) clip\(unnamed.count == 1 ? "" : "s")…" + (fallback.map { " (simple names: \($0))" } ?? ""))
        suggesting.formUnion(unnamed.map(\.id))
        Task {
            var results: [(ClipID, [String])] = []
            for (id, context) in contexts {
                if let list = try? await namer.suggest(for: context) { results.append((id, Self.cleanSuggestions(list))) }
                suggesting.remove(id)
            }
            perform("Name Clips") { p in
                for (id, list) in results where !list.isEmpty {
                    try p.setSuggestions(clip: id, list)
                    if p.clip(id)?.name == nil { try p.setName(clip: id, list[0]) }
                }
            }
            flash("Named \(results.filter { !$0.1.isEmpty }.count) clip\(results.count == 1 ? "" : "s").")
        }
    }

    static func cleanSuggestions(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Export

    func showExport(onlySelected: Bool = false) {
        exporter.prepare(project: project, package: packageURL, source: sourceURL,
                         selected: selectedClip, onlySelected: onlySelected)
        showingExport = true
    }
}
