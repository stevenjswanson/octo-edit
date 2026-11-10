import SwiftUI
import Core

/// Two versions of a project's clips side by side (OctoEdit's and the one on disk),
/// lined up by slug, with differences marked. Shown when transcript.md changes on disk.
struct ClipComparison: View {
    struct Side { var name: String; var duration: Double }
    struct Row: Identifiable {
        let id: String          // slug
        var here: Side?
        var disk: Side?
        /// Set to decide the ● directly, rather than by comparing the two sides.
        var marked: Bool?
        var differs: Bool {
            if let marked { return marked }
            guard let here, let disk else { return true }
            return here.name != disk.name || abs(here.duration - disk.duration) >= 0.05
        }
    }

    let rows: [Row]
    let diskProblem: String?
    var titles = ("In OctoEdit", "On disk")
    /// Replaces the line under the table.
    var summary: String?
    /// Called with a row's slug when it is clicked.
    var onSelect: ((String) -> Void)?

    /// Rows in reading order: OctoEdit's clips, with disk-only clips placed after the
    /// clip they follow on disk.
    static func rows(here: Project, disk: Project?) -> [Row] {
        func sides(_ p: Project) -> [(String, Side)] {
            let slugs = p.slugs()
            return p.clips.map { c in (slugs[c.id] ?? "", Side(name: c.name ?? slugs[c.id] ?? "Unnamed", duration: p.duration(of: c))) }
        }
        let a = sides(here)
        let b = disk.map(sides) ?? []
        let diskBySlug = Dictionary(b.map { ($0.0, $0.1) }, uniquingKeysWith: { x, _ in x })
        var rows = a.map { Row(id: $0.0, here: $0.1, disk: diskBySlug[$0.0]) }
        let hereSlugs = Set(a.map(\.0))
        var previous: String?
        for (slug, side) in b {
            if !hereSlugs.contains(slug) {
                let at = previous.flatMap { p in rows.firstIndex { $0.id == p } }.map { $0 + 1 } ?? 0
                rows.insert(Row(id: slug, here: nil, disk: side), at: at)
            }
            previous = slug
        }
        return rows
    }

    var body: some View {
        let changed = rows.filter(\.differs).count
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text(titles.0).font(.caption.weight(.semibold))
                    Text(titles.1).font(.caption.weight(.semibold))
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow {
                        Image(systemName: row.differs ? "circle.fill" : "circle")
                            .font(.system(size: 6))
                            .foregroundStyle(row.differs ? Color.orange : Color.secondary.opacity(0.4))
                        cell(row.here)
                        cell(row.disk)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(row.id) }
                }
            }
            .padding(8)
            }
            .frame(height: min(CGFloat(rows.count) * 22 + 44, 300))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            Text(summary ?? (rows.isEmpty ? "Neither version has clips."
                 : changed == 0 ? "The clips are the same; the text or other details differ."
                 : "\(changed) of \(rows.count) clip\(rows.count == 1 ? "" : "s") differ (marked ●)."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let diskProblem {
                Label(diskProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(width: 480)
    }

    @ViewBuilder private func cell(_ side: Side?) -> some View {
        if let side {
            HStack(spacing: 6) {
                Text(side.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(ClipShelf.duration(side.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(width: 200, alignment: .leading)
        } else {
            Text("—").foregroundStyle(.tertiary).frame(width: 200, alignment: .leading)
        }
    }
}
