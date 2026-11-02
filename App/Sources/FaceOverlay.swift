import SwiftUI
import Core
import SpeakerFraming

/// Show faces: a circle in the speaker's colour around each face in the video pane,
/// with the speaker's name below (grey and unnamed when the face isn't anyone's yet). Whoever
/// has the floor (the speaker of the word at the playhead) is drawn bold; everyone else
/// faint. Drawn over the player, so it is never part of an export.
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
                let speaking = speaking
                ForEach(Array(labels.faces(at: t).enumerated()), id: \.offset) { _, face in
                    let nx = (face.box.centerX - left) / w
                    if nx >= 0, nx <= 1 {
                        marker(face.speaker, speaking: face.speaker != nil && face.speaker == speaking,
                               diameter: max(face.box.h * rect.height * 1.5, 16))
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

    /// The speaker of the word at the playhead.
    private var speaking: String? {
        guard let w = model.currentWord, w < model.project.words.count else { return nil }
        return model.project.paragraph(model.project.words[w].paragraph)?.speaker
    }

    /// A ring centred on the face, its name hanging below it; bold while they speak.
    private func marker(_ speaker: String?, speaking: Bool, diameter: Double) -> some View {
        let color = speaker.map { Color(model.speakerColor($0)) } ?? .gray
        return Circle().stroke(color, lineWidth: speaking ? 4 : 1.5)
            .frame(width: diameter, height: diameter)
            .overlay(alignment: .bottom) {
                Text(speaker ?? "?")
                    .font(speaking ? .callout.bold() : .caption)
                    .foregroundStyle(.white.opacity(speaking ? 1 : 0.8))
                    .padding(.horizontal, speaking ? 7 : 5).padding(.vertical, speaking ? 2 : 1)
                    .background(Capsule().fill(color.opacity(speaking ? 1 : 0.45)))
                    .fixedSize()
                    .offset(y: speaking ? 22 : 18)
            }
            .opacity(speaking ? 1 : 0.6)
            .shadow(color: speaking ? color.opacity(0.9) : .black.opacity(0.5), radius: speaking ? 5 : 2)
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
