import SwiftUI
import Core

/// One card per clip in document order; clicking seeks the source to the clip's start.
/// (Thumbnails and selection arrive in B2.)
struct ClipShelf: View {
    let model: DocumentModel

    var body: some View {
        let project = model.project
        let slugs = project.slugs()
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if project.clips.isEmpty {
                    Text("No clips yet. Mark them in transcript.md with {clip} … {/clip}.")
                        .foregroundStyle(.secondary).padding(.horizontal)
                }
                ForEach(Array(project.clips.enumerated()), id: \.element.id) { n, clip in
                    Button {
                        if let start = project.resolvedSegments(of: clip).first?.start { model.seek(to: start) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(n + 1)  \(clip.name ?? "Unnamed")").font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(slugs[clip.id] ?? "")  ·  \(Self.duration(project.duration(of: clip)))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 180, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(ClipPalette.color(n).opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
