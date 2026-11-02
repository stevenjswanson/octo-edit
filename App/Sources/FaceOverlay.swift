import SwiftUI
import Core
import SpeakerFraming

/// Show faces: a dot in the speaker's colour on each face in the video pane, with the
/// speaker's name (grey and unnamed when the face isn't anyone's yet). Drawn over the
/// player, so it is never part of an export.
struct FaceOverlay: View {
    let model: DocumentModel
    let preview: PreviewModel

    var body: some View {
        GeometryReader { geo in
            if let labels = model.faceLabels, let t = time {
                // The part of the frame on screen: all of it, or the preview's 9:16 column.
                let column = model.activePane == .preview ? preview.column : nil
                let w = column?.width ?? 1
                let left = column.map { $0.x(at: t) - w / 2 } ?? 0
                let rect = fitted(aspect: labels.aspect * w, in: geo.size)
                ForEach(Array(labels.faces(at: t).enumerated()), id: \.offset) { _, face in
                    let nx = (face.box.centerX - left) / w
                    if nx >= 0, nx <= 1 {
                        marker(face.speaker)
                            .position(x: rect.minX + nx * rect.width, y: rect.minY + face.box.centerY * rect.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The playhead of the video on screen, as a source time.
    private var time: Double? {
        model.activePane == .source ? model.sourceTime : preview.position
    }

    private func marker(_ speaker: String?) -> some View {
        let color = speaker.map { Color(model.speakerColor($0)) } ?? .gray
        return VStack(spacing: 2) {
            Circle().fill(color).frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Text(speaker ?? "?")
                .font(.caption.bold()).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.85)))
                .fixedSize()
        }
        .shadow(radius: 2)
        .offset(y: 10)   // the dot, not the stack, sits on the face
    }

    /// Where a frame of this width ÷ height lands, fitted in `size` (the player letterboxes).
    private func fitted(aspect: Double, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
        let h = size.width / aspect
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    }
}
