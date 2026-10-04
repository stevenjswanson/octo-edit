import AppKit
import Core
import Save
import Waveform

/// Boundary inspector actions (B3): choose a cut, move it by an offset from its
/// anchor word, snap it, and hear it.
extension DocumentModel {
    /// Seconds played on each side of a cut while looping.
    static let loopHalfWidth = 1.0

    /// Opens the inspector on a cut, pausing both videos. Stepping to another cut with
    /// ‹ › (`play`) scrolls it into view and plays across it.
    func inspect(_ b: BoundaryRef, play: Bool = false) {
        selectedClipForInspection(b.clip)
        inspected = b
        inspectRequest += 1
        focus(.preview)
        if play {
            if let w = project.anchorWord(of: b) { revealWord(w) }
            playCut()   // once, or looping if the loop is on
        } else {
            player.pause()
            preview.cancelExcerpt()
            preview.player.pause()
        }
    }

    private func selectedClipForInspection(_ id: ClipID) {
        if selectedClip != id { select(clip: id) }
    }

    /// The marker's boundary: a start marker is the clip's first in-point, an end
    /// marker its last out-point.
    func boundary(for marker: MarkerRef) -> BoundaryRef? {
        guard let clip = project.clip(marker.clip) else { return nil }
        return BoundaryRef(clip: clip.id, segment: marker.inPoint ? 0 : clip.segments.count - 1, inPoint: marker.inPoint)
    }

    /// ⌘B: the cut nearest the caret (or selection), in the clip it's in or the selected clip.
    func inspectNearest(word: Int? = nil) {
        guard let w = word ?? selection?.lowerBound ?? caretWord ?? currentWord else {
            flash("Put the caret in a clip first."); return
        }
        guard let clip = project.clip(containingWordAt: w) ?? selectedClip.flatMap({ project.clip($0) }) else {
            flash("Put the caret in a clip first."); return
        }
        let all = project.boundaries(of: clip)
        guard let best = all.min(by: { distance($0, w) < distance($1, w) }) else { return }
        inspect(best)
    }

    private func distance(_ b: BoundaryRef, _ w: Int) -> Int {
        guard let a = project.anchorWord(of: b) else { return .max }
        // An in-point sits before its word, an out-point after: bias ties accordingly.
        return abs(a - w) * 2 + (b.inPoint ? (w < a ? 0 : 1) : (w > a ? 0 : 1))
    }

    /// ◀ ▶ in the inspector: the previous or next cut of the same clip.
    func stepInspected(_ delta: Int) {
        guard let b = inspected, let clip = project.clip(b.clip) else { return }
        let all = project.boundaries(of: clip)
        guard let i = all.firstIndex(of: b), all.indices.contains(i + delta) else { NSSound.beep(); return }
        inspect(all[i + delta], play: true)
    }

    /// Closing the inspector always stops what it started: the loop is turned off, any
    /// excerpt or loop (playing, restarting, or queued behind a rebuild) is stopped.
    func closeInspector() {
        let wasOpen = inspected != nil || loopCut
        inspected = nil
        loopCut = false
        queuePreviewCueClear()
        if wasOpen { preview.stopExcerpts() }
    }

    // MARK: Offsets

    /// The offset as written (nil = the default for its role) and as applied.
    func offsets(of b: BoundaryRef) -> (explicit: Double?, effective: Double)? {
        guard let clip = project.clip(b.clip), clip.segments.indices.contains(b.segment) else { return nil }
        let seg = clip.segments[b.segment]
        return (b.inPoint ? seg.inPoint.offset : seg.outPoint.offset,
                project.effectiveOffset(of: clip, segment: b.segment, inPoint: b.inPoint))
    }

    /// Sets an explicit offset (seconds, rounded to whole ms) or nil for the default.
    func setOffset(_ b: BoundaryRef, _ offset: Double?) {
        let rounded = offset.map { ($0 * 1000).rounded() / 1000 }
        selectedClipForInspection(b.clip)
        queueCue(for: b, offset: rounded)
        if !perform("Adjust Cut", { try $0.setOffset(clip: b.clip, segment: b.segment, inPoint: b.inPoint, rounded) }) {
            refreshPreviewNow()
        }
    }

    func nudge(_ b: BoundaryRef, by seconds: Double) {
        guard let o = offsets(of: b) else { return }
        setOffset(b, o.effective + seconds)
    }

    func snapToSilence(_ b: BoundaryRef) {
        guard let env = envelope else { flash("Analyze the audio first."); return }
        guard let o = project.silenceOffset(of: b, envelope: env) else { flash("No gap next to this word."); return }
        setOffset(b, o)
    }

    func snapToWordEdge(_ b: BoundaryRef) { setOffset(b, 0) }

    func snapToFrame(_ b: BoundaryRef) {
        guard let o = project.frameSnappedOffset(of: b, fps: sourceFPS) else { return }
        setOffset(b, o)
    }

    /// What to play after a cut moves: the loop if it's on, else auto preview of that cut.
    private func queueCue(for b: BoundaryRef, offset: Double?) {
        guard let anchor = project.anchorTime(of: b), let clip = project.clip(b.clip) else { return }
        let t = anchor + (offset ?? project.effectiveOffset(of: clip, segment: b.segment, inPoint: b.inPoint))
        if loopCut {
            queuePreviewCue(.loop(around: t, half: Self.loopHalfWidth))
            return
        }
        switch project.role(of: b) {
        case .clipStart: queuePreviewCue(.start)
        case .clipEnd: queuePreviewCue(.end)
        default: queuePreviewCue(.around(from: t, to: t))
        }
    }

    // MARK: Loop

    /// The Loop button is the inspector's play control: on plays ±1 s across the cut
    /// over and over (and follows nudges); off stops.
    func setLoop(_ on: Bool) {
        loopCut = on
        if on { focus(.preview); replayCut() } else { preview.stopExcerpts() }
    }

    /// Starts (or restarts) the loop across the inspected cut.
    func replayCut() {
        guard let b = inspected, let t = project.boundaryTime(of: b) else { return }
        preview.play(.loop(around: t, half: Self.loopHalfWidth))
    }

    /// Plays ±1 s across the inspected cut — looping if the loop is on. Applied once
    /// the clip's preview is ready (selecting a different clip rebuilds it first).
    func playCut() {
        guard let b = inspected, let t = project.boundaryTime(of: b) else { return }
        focus(.preview)
        let cue: PreviewModel.Cue = loopCut ? .loop(around: t, half: Self.loopHalfWidth) : .once(around: t, half: Self.loopHalfWidth)
        if preview.clipID == b.clip, !preview.building { preview.play(cue) } else { preview.playWhenReady(cue) }
    }



    // MARK: Waveform cache

    /// Rebuilds the loudness envelope from the input video and caches it in the package.
    func analyzeWaveform() {
        guard let url = sourceURL, !sourceMissing, !analyzingWaveform else { return }
        analyzingWaveform = true
        let package = packageURL
        Task {
            do {
                let env = try await AssetEnvelopeAnalyzer().envelope(of: url)
                envelope = env
                if let package { try? PackageWriter.saveWaveform(env, to: package) }
            } catch {
                flash("Couldn’t analyze the audio: \(error)")
            }
            analyzingWaveform = false
        }
    }
}
