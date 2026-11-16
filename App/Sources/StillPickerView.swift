import SwiftUI
import Core
import SpeakerFraming

/// The clip panel's title-card row: whether the still was picked automatically,
/// and the buttons that open the picker or go back to the automatic pick.
struct TitleStillRow: View {
    let model: DocumentModel
    let clipID: ClipID
    @Binding var picking: Bool

    var body: some View {
        let store = model.stills
        let clip = model.project.clip(clipID)
        let current = store.entries[clipID]?.current
        VStack(alignment: .leading, spacing: 3) {
            Text("Title card").font(.caption.weight(.semibold))
            if let current {
                Text((clip?.still == nil ? "Automatic · " : "Chosen · ") + StillTime.label(current.t))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let why = store.problem {
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.working.contains(clipID) {
                Text("Picking a still…").font(.caption).foregroundStyle(.secondary)
            } else if model.faces != nil {
                Text("No face found").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Choose…") { openStillPicker(model, clipID, $picking) }
                    .disabled(model.faces == nil)
                if clip?.still != nil {
                    Button("Automatic") { model.setStill(clipID, nil) }
                        .help("Go back to the automatic pick")
                }
            }
            .controlSize(.small)
        }
        .onAppear { model.refreshStill(clipID) }
        .onChange(of: clipID) { _, id in picking = false; model.refreshStill(id) }
        .onChange(of: model.revision) { _, _ in model.refreshStill(clipID) }
        .onChange(of: model.faces?.frames.count) { _, _ in model.refreshStill(clipID) }
        .onChange(of: store.entries[clipID] == nil) { _, gone in if gone { model.refreshStill(clipID) } }
    }
}

/// The title card's still at the side of the clip panel, as tall as the panel.
/// Clicking it opens the picker.
struct TitleStillImage: View {
    let model: DocumentModel
    let clipID: ClipID
    @Binding var picking: Bool

    var body: some View {
        let store = model.stills
        Button { openStillPicker(model, clipID, $picking) } label: {
            StillThumb(image: store.entries[clipID]?.image, loading: store.working.contains(clipID))
        }
        .buttonStyle(.plain)
        .help("Choose the title card's still")
        .popover(isPresented: $picking, arrowEdge: .leading) {
            StillPickerView(model: model, clipID: clipID, close: { picking = false })
        }
    }
}

@MainActor
private func openStillPicker(_ model: DocumentModel, _ clipID: ClipID, _ picking: Binding<Bool>) {
    guard model.faces != nil, model.canEdit else { return }
    model.loadStillOptions(clipID)
    picking.wrappedValue = true
}

/// A 9:16 (or the source's shape) thumbnail with a spinner while it loads.
struct StillThumb: View {
    let image: NSImage?
    var loading = false
    /// A fixed height, or nil to fill the height on offer.
    var height: CGFloat? = nil

    var body: some View {
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? 9.0 / 16.0
        let thumb = ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary)
            }
        }
        if let height {
            thumb.frame(width: height * aspect, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            thumb.aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

enum StillTime {
    /// `20:35.5` or `1:00:05.4`, for labels (transcript.md keeps milliseconds).
    static func label(_ t: Seconds) -> String {
        let tenths = Int((t * 10).rounded())
        let h = tenths / 36000, m = (tenths / 600) % 60, s = (tenths / 10) % 60, d = tenths % 10
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, d) : String(format: "%d:%02d.%d", m, s, d)
    }
}

/// The picker: the automatic pick, then candidates from the clip's opening, later in
/// the clip, and the whole talk, best first. Clicking one chooses it (undoable).
struct StillPickerView: View {
    let model: DocumentModel
    let clipID: ClipID
    let close: () -> Void

    var body: some View {
        let store = model.stills
        let clip = model.project.clip(clipID)
        let options = store.options[clipID]?.list ?? []
        let auto = store.entries[clipID]?.automatic
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Title card still").font(.headline)
                Spacer()
                if store.loadingOptions.contains(clipID) {
                    ProgressView().controlSize(.small)
                    Text("Scoring frames…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let auto {
                        section("Automatic", [Tile(t: auto.t, score: auto.score, image: store.images[Self.ms(auto.t)]
                                                   ?? store.entries[clipID]?.image, chosen: clip?.still == nil, automatic: true)])
                    }
                    if let t = clip?.still, !options.contains(where: { abs($0.t - t) < 0.0005 }) {
                        section("Chosen", [Tile(t: t, score: store.entries[clipID]?.chosen?.score,
                                                image: store.images[Self.ms(t)] ?? store.entries[clipID]?.image, chosen: true)])
                    }
                    if let main = clip.flatMap({ StillPicker.mainSpeaker(of: $0, in: model.project) }) {
                        Text(main).font(.title3.weight(.semibold)).padding(.top, 4)
                    }
                    ForEach([StillPicker.Candidate.Origin.opening, .clip, .talk], id: \.self) { origin in
                        let tiles = options.filter { $0.speaker == nil && $0.origin == origin }.map { tile($0, clip) }
                        if !tiles.isEmpty { section(Self.title(origin), tiles) }
                    }
                    ForEach(store.people[clipID] ?? [], id: \.self) { person in
                        let tiles = options.filter { $0.speaker == person }
                            .sorted { ($0.score?.total ?? 0) > ($1.score?.total ?? 0) }.map { tile($0, clip) }
                        if !tiles.isEmpty {
                            Divider()
                            Text(person).font(.title3.weight(.semibold))
                            section("Best frames (in this clip first, then the talk)", tiles)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            Text("Saved in transcript.md as still=… on the clip's marker. ⌘Z undoes a choice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 940, height: 780)
    }

    struct Tile: Identifiable {
        var t: Seconds
        var score: StillScore?
        var image: NSImage?
        var chosen: Bool
        var automatic = false
        var id: String { (automatic ? "a" : "") + String(Int((t * 1000).rounded())) }
    }

    private func tile(_ o: StillStore.Option, _ clip: Clip?) -> Tile {
        Tile(t: o.t, score: o.score, image: model.stills.images[o.id],
             chosen: clip?.still.map { abs($0 - o.t) < 0.0005 } ?? false)
    }

    static func ms(_ t: Seconds) -> Int { Int((t * 1000).rounded()) }

    static func title(_ o: StillPicker.Candidate.Origin) -> String {
        switch o {
        case .opening: "Opening (first \(Int(StillPicker.opening)) s)"
        case .clip: "Later in the clip"
        case .talk: "Elsewhere in the talk"
        }
    }

    @ViewBuilder private func section(_ title: String, _ tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 8) {
                ForEach(tiles) { tile in
                    Button {
                        model.setStill(clipID, tile.automatic ? nil : tile.t)
                        model.refreshStill(clipID)
                        close()
                    } label: {
                        VStack(spacing: 2) {
                            StillThumb(image: tile.image, loading: tile.image == nil, height: 280)
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .stroke(tile.chosen ? Color.accentColor : .clear, lineWidth: 3))
                            HStack(spacing: 3) {
                                Circle().fill(Self.color(tile.score)).frame(width: 6, height: 6)
                                Text(StillTime.label(tile.t)).font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(Self.describe(tile.score))
                }
            }
        }
    }

    /// Green for a good card, yellow for passable, red for poor.
    static func color(_ s: StillScore?) -> Color {
        guard let s else { return .gray }
        return s.total >= StillPicker.goodEnough ? .green : s.total >= StillPicker.goodEnough / 2 ? .yellow : .red
    }

    static func describe(_ s: StillScore?) -> String {
        guard let s else { return "Not scored" }
        return String(format: "Score %.2f — face quality %.2f, eyes %.2f, mouth closed %.2f", s.total, s.quality, s.eyes, s.mouth)
    }
}
