import SwiftUI
import Core

/// The boundary inspector popover: one cut of one clip — clip start or end, or either
/// edge of an omission — with its waveform, offset, nudges, snaps and a loop.
struct BoundaryInspector: View {
    let model: DocumentModel
    /// Closes the popover (its delegate then clears the model's inspected cut).
    let dismiss: () -> Void
    @State private var offsetText = ""
    @FocusState private var editingOffset: Bool

    var body: some View {
        if let b = model.inspected, let info = Info(model: model, b: b) {
            content(b, info)
                .padding(14)
                .frame(width: 520)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear {
                    offsetText = Self.ms(info.explicit)
                    if model.envelope == nil { model.analyzeWaveform() }
                }
                .onChange(of: info.explicit) { _, v in if !editingOffset { offsetText = Self.ms(v) } }
                .onChange(of: b) { _, _ in offsetText = Self.ms(Info(model: model, b: b)?.explicit) }
        } else {
            Text("No cut selected").padding(20)
        }
    }

    private struct Info {
        var title: String
        var clipName: String
        var anchorText: String
        var anchorTime: Double
        var cut: Double
        var explicit: Double?
        var effective: Double
        var defaultOffset: Double
        var position: String

        @MainActor init?(model: DocumentModel, b: BoundaryRef) {
            let p = model.project
            guard let clip = p.clip(b.clip), let role = p.role(of: b), let w = p.anchorWord(of: b),
                  let anchor = p.anchorTime(of: b), let cut = p.boundaryTime(of: b),
                  let offsets = model.offsets(of: b) else { return nil }
            let all = p.boundaries(of: clip)
            let omission = b.segment + (b.inPoint ? 0 : 1)
            title = switch role {
            case .clipStart: "Clip start"
            case .clipEnd: "Clip end"
            case .omissionStart: "Omission \(omission) · start of cut"
            case .omissionEnd: "Omission \(omission) · end of cut"
            }
            clipName = clip.name ?? p.slug(of: clip.id) ?? "clip"
            anchorText = p.words[w].text
            anchorTime = anchor
            self.cut = cut
            explicit = offsets.explicit
            effective = offsets.effective
            defaultOffset = switch role {
            case .clipStart: -p.settings.prePad
            case .clipEnd: p.settings.postPad
            default: 0
            }
            position = "\((all.firstIndex(of: b) ?? 0) + 1) of \(all.count)"
        }
    }

    @ViewBuilder private func content(_ b: BoundaryRef, _ info: Info) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title).font(.headline)
                    Text("“\(info.clipName)” · \(b.inPoint ? "before" : "after") “\(info.anchorText)”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(info.position).font(.caption).foregroundStyle(.secondary)
                Button { model.stepInspected(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous cut in this clip")
                Button { model.stepInspected(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next cut in this clip")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            waveform(b, info)

            HStack(spacing: 6) {
                Text("Offset")
                TextField("default", text: $offsetText)
                    .frame(width: 64).multilineTextAlignment(.trailing)
                    .focused($editingOffset)
                    .onSubmit { commitOffset(b) }
                Text("ms").foregroundStyle(.secondary)
                Text(info.explicit == nil ? "(default \(Self.ms(info.defaultOffset)))" : "default \(Self.ms(info.defaultOffset))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use Default") { model.setOffset(b, nil) }.disabled(info.explicit == nil)
            }

            HStack(spacing: 4) {
                Text("Nudge").frame(width: 50, alignment: .leading)
                nudge(b, "−1f", -1 / model.sourceFPS, .leftArrow, [.shift])
                nudge(b, "−10", -0.010, .leftArrow, [])
                nudge(b, "−1", -0.001, .leftArrow, [.option])
                nudge(b, "+1", 0.001, .rightArrow, [.option])
                nudge(b, "+10", 0.010, .rightArrow, [])
                nudge(b, "+1f", 1 / model.sourceFPS, .rightArrow, [.shift])
                Spacer()
                Text("ms · f = frame").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text("Snap").frame(width: 50, alignment: .leading)
                Button("To Silence") { model.snapToSilence(b) }.disabled(model.envelope == nil)
                Button("To Word Edge") { model.snapToWordEdge(b) }
                Button("To Frame") { model.snapToFrame(b) }
                Spacer()
                Toggle(isOn: Binding(get: { model.loopCut }, set: { model.setLoop($0) })) {
                    Label("Loop ±\(Int(DocumentModel.loopHalfWidth)) s", systemImage: model.loopCut ? "stop.fill" : "repeat")
                }
                .toggleStyle(.button)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play across the cut, over and over (Space). Click again to stop.")
            }
        }
    }

    @ViewBuilder private func waveform(_ b: BoundaryRef, _ info: Info) -> some View {
        if let env = model.envelope {
            WaveformView(envelope: env, project: model.project, boundary: b, cut: info.cut,
                         playhead: model.activePane == .preview ? model.preview.position : model.sourceTime,
                         defaultCut: info.anchorTime + info.defaultOffset, anchorTime: info.anchorTime,
                         color: ClipPalette.color(model.project.clips.firstIndex { $0.id == b.clip } ?? 0)) { t in
                model.setOffset(b, t - info.anchorTime)
            }
            .frame(height: 120)
        } else {
            HStack {
                Text("No waveform for this project yet.").foregroundStyle(.secondary)
                Spacer()
                if model.analyzingWaveform { ProgressView().controlSize(.small); Text("Analyzing…") }
                else { Button("Analyze Audio") { model.analyzeWaveform() } }
            }
            .frame(height: 120)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func nudge(_ b: BoundaryRef, _ label: String, _ seconds: Double,
                       _ key: KeyEquivalent, _ mods: EventModifiers) -> some View {
        Button(label) { model.nudge(b, by: seconds) }
            .keyboardShortcut(key, modifiers: mods)
            .monospacedDigit()
    }

    private func commitOffset(_ b: BoundaryRef) {
        let t = offsetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "ms", with: "")
            .replacingOccurrences(of: "−", with: "-")
        if t.isEmpty { model.setOffset(b, nil); return }
        guard let v = Double(t) else { NSSound.beep(); return }
        model.setOffset(b, v / 1000)
    }

    static func ms(_ s: Double?) -> String {
        guard let s else { return "" }
        let v = Int((s * 1000).rounded())
        return v > 0 ? "+\(v)" : "\(v)"
    }
}

/// ±1 s of loudness around a cut, with the words, the cut line, and where the
/// default pad would put it. The side that's cut out is greyed. Click or drag to
/// move the cut.
struct WaveformView: View {
    let envelope: Envelope
    let project: Project
    let boundary: BoundaryRef
    let cut: Double
    let playhead: Double?
    let defaultCut: Double
    let anchorTime: Double
    let color: Color
    let onSet: (Double) -> Void

    @State private var dragTime: Double?
    private let halfWidth = 1.0

    var body: some View {
        GeometryReader { geo in
            let lo = anchorTime - halfWidth, hi = anchorTime + halfWidth
            let x = { (t: Double) -> CGFloat in CGFloat((t - lo) / (hi - lo)) * geo.size.width }
            let shown = dragTime ?? cut
            Canvas { ctx, size in
                // Kept vs cut-out side.
                let cutX = x(shown)
                let removed = boundary.inPoint ? CGRect(x: 0, y: 0, width: cutX, height: size.height)
                                               : CGRect(x: cutX, y: 0, width: size.width - cutX, height: size.height)
                ctx.fill(Path(removed), with: .color(.secondary.opacity(0.12)))

                // Envelope bars, scaled to the loudest bucket in view.
                let a = max(envelope.bucket(at: lo), 0), z = min(envelope.bucket(at: hi), envelope.rms.count - 1)
                if z > a {
                    let peak = max(envelope.rms[a...z].max() ?? 1, 1e-6)
                    let mid = size.height * 0.58, amp = size.height * 0.36
                    var path = Path()
                    for i in a...z {
                        let t = envelope.time(ofBucket: i)
                        let h = CGFloat((Double(envelope.rms[i] / peak)).squareRoot()) * amp
                        path.addRect(CGRect(x: x(t), y: mid - h, width: max(size.width / CGFloat(z - a), 1), height: max(h * 2, 0.5)))
                    }
                    ctx.fill(path, with: .color(.primary.opacity(0.55)))
                }

                // Words: a faint span and the text at its start.
                for w in project.words where (w.end ?? -1) > lo && (w.start ?? .infinity) < hi {
                    guard let s = w.start, let e = w.end else { continue }
                    ctx.fill(Path(CGRect(x: x(s), y: 0, width: max(x(e) - x(s), 1), height: 16)),
                             with: .color(.accentColor.opacity(0.10)))
                    ctx.draw(Text(w.text).font(.caption2), at: CGPoint(x: x(s) + 2, y: 8), anchor: .leading)
                }

                // Where the default would put the cut (dashed), and the cut itself.
                var dflt = Path(); dflt.move(to: CGPoint(x: x(defaultCut), y: 18)); dflt.addLine(to: CGPoint(x: x(defaultCut), y: size.height))
                ctx.stroke(dflt, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var line = Path(); line.move(to: CGPoint(x: cutX, y: 16)); line.addLine(to: CGPoint(x: cutX, y: size.height))
                ctx.stroke(line, with: .color(color), lineWidth: 2.5)
                // The playhead of the video being played.
                if let p = playhead, p > lo, p < hi {
                    var ph = Path(); ph.move(to: CGPoint(x: x(p), y: 16)); ph.addLine(to: CGPoint(x: x(p), y: size.height))
                    ctx.stroke(ph, with: .color(.red), lineWidth: 1.5)
                }
                // Time readout relative to the anchor word's edge.
                let label = BoundaryInspector.ms(shown - anchorTime) + " ms"
                ctx.draw(Text(label).font(.caption2.monospacedDigit()).foregroundStyle(color),
                         at: CGPoint(x: min(max(cutX + 4, 4), size.width - 60), y: size.height - 8), anchor: .leading)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragTime = lo + Double(v.location.x / geo.size.width) * (hi - lo) }
                .onEnded { v in
                    let t = lo + Double(v.location.x / geo.size.width) * (hi - lo)
                    dragTime = nil
                    onSet(t)
                })
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
