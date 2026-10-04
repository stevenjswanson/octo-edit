import SwiftUI
import Core

/// One card per clip in document order. Clicking selects the clip: the preview loads
/// it, the transcript scrolls to its start, and the source seeks there.
struct ClipShelf: View {
    let model: DocumentModel

    var body: some View {
        let project = model.project
        let slugs = project.slugs()
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if project.clips.isEmpty {
                        Text("No clips yet. Select words in the transcript and choose Clip ▸ New Clip from Selection (⌘K).")
                            .foregroundStyle(.secondary).padding(.horizontal)
                    }
                    ForEach(Array(project.clips.enumerated()), id: \.element.id) { n, clip in
                        card(n, clip, slug: slugs[clip.id] ?? "", duration: project.duration(of: clip),
                             selected: clip.id == model.selectedClip)
                            .id(clip.id)
                            .onTapGesture { model.select(clip: clip.id, reveal: true, seekSource: true) }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selectedClip) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Thumbnail on top, title and details underneath (narrow cards fit more clips).
    private func card(_ n: Int, _ clip: Clip, slug: String, duration: Double, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = model.thumbnails.images[clip.id] {
                        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        ClipPalette.color(n).opacity(0.3)
                    }
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(Self.duration(duration))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
            Text("\(n + 1)  \(clip.name ?? "Unnamed")").font(.caption.weight(.medium)).lineLimit(1)
            Text(slug).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 128)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7).fill(ClipPalette.color(n).opacity(selected ? 0.35 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? ClipPalette.color(n) : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

enum ClipPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red]
    static func color(_ n: Int) -> Color { colors[n % colors.count] }
    static func nsColor(_ n: Int) -> NSColor { NSColor(color(n)) }
}
