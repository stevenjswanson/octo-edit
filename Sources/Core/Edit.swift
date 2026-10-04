import Foundation

public enum EditError: Error, Equatable, CustomStringConvertible {
    case invalidRange
    case overlapsClip(ClipID)
    case noSuchClip(ClipID)
    case outsideClip
    case wouldOmitEverything
    case zoomOnlyText
    case notSplittable

    public var description: String {
        switch self {
        case .invalidRange: "the word range is invalid"
        case .overlapsClip(let id): "the range overlaps clip \(id)"
        case .noSuchClip(let id): "no clip \(id)"
        case .outsideClip: "the range is not inside the clip"
        case .wouldOmitEverything: "omitting this would leave the clip empty"
        case .zoomOnlyText: "clip boundaries and omissions can't be placed in Zoom-only text (it isn't in the recording)"
        case .notSplittable: "the paragraph can't be split there"
        }
    }
}

extension Project {
    private func checkRange(_ r: ClosedRange<Int>) throws {
        guard r.lowerBound >= 0, r.upperBound < words.count else { throw EditError.invalidRange }
    }

    /// Whether word `i` belongs to a Zoom-only paragraph (text not in the recording).
    public func isZoomOnly(wordAt i: Int) -> Bool {
        paragraph(words[i].paragraph)?.zoomOnly ?? false
    }

    /// Clip edges, cut points and omitted words must all be in spoken text: the
    /// format can't put markers in a Zoom-only paragraph, and nothing there has timing.
    private func checkPlaceable(_ segments: [Segment]) throws {
        let ranges = segments.compactMap { indexRange(of: $0) }
        for r in ranges where isZoomOnly(wordAt: r.lowerBound) || isZoomOnly(wordAt: r.upperBound) {
            throw EditError.zoomOnlyText
        }
        for (a, b) in zip(ranges, ranges.dropFirst()) where a.upperBound + 1 < b.lowerBound {
            if ((a.upperBound + 1)..<b.lowerBound).contains(where: { isZoomOnly(wordAt: $0) }) { throw EditError.zoomOnlyText }
        }
    }

    private func clipIndex(_ id: ClipID) throws -> Int {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { throw EditError.noSuchClip(id) }
        return i
    }

    /// Rebuilds a clip's segments from a per-word kept mask over `range`,
    /// keeping explicit offsets on boundaries whose anchor word is unchanged.
    private func rebuiltSegments(_ clip: Clip, range: ClosedRange<Int>, kept: [Bool]) -> [Segment] {
        var inOffsets: [WordID: Seconds] = [:]
        var outOffsets: [WordID: Seconds] = [:]
        for s in clip.segments {
            if let o = s.inPoint.offset { inOffsets[s.inPoint.word] = o }
            if let o = s.outPoint.offset { outOffsets[s.outPoint.word] = o }
        }
        var segments: [Segment] = []
        var runStart: Int?
        for (k, i) in range.enumerated() {
            if kept[k] {
                if runStart == nil { runStart = i }
            }
            let runEnds = !kept[k] || i == range.upperBound
            if runEnds, let a = runStart {
                let b = kept[k] ? i : i - 1
                let inID = words[a].id, outID = words[b].id
                segments.append(Segment(inPoint: Boundary(word: inID, offset: inOffsets[inID]),
                                        outPoint: Boundary(word: outID, offset: outOffsets[outID])))
                runStart = nil
            }
        }
        return segments
    }

    private func keptMask(_ clip: Clip, over range: ClosedRange<Int>) -> [Bool] {
        var kept = Array(repeating: false, count: range.count)
        for seg in clip.segments {
            guard let r = indexRange(of: seg) else { continue }
            for i in r where range.contains(i) { kept[i - range.lowerBound] = true }
        }
        return kept
    }

    @discardableResult
    public mutating func makeClip(words r: ClosedRange<Int>, name: String? = nil) throws -> ClipID {
        try checkRange(r)
        if let other = clips.first(where: { indexRange(of: $0)?.overlaps(r) ?? false }) {
            throw EditError.overlapsClip(other.id)
        }
        let id = ClipID((clips.map(\.id.raw).max() ?? 0) + 1)
        let clip = Clip(id: id, name: name, segments: [
            Segment(inPoint: Boundary(word: words[r.lowerBound].id), outPoint: Boundary(word: words[r.upperBound].id)),
        ])
        try checkPlaceable(clip.segments)
        let insertAt = clips.firstIndex { (indexRange(of: $0)?.lowerBound ?? .max) > r.upperBound } ?? clips.count
        clips.insert(clip, at: insertAt)
        return id
    }

    public mutating func deleteClip(_ id: ClipID) throws {
        clips.remove(at: try clipIndex(id))
    }

    /// Omits words inside a clip, splitting segments as needed.
    public mutating func omit(words r: ClosedRange<Int>, in id: ClipID) throws {
        try checkRange(r)
        let ci = try clipIndex(id)
        guard let range = indexRange(of: clips[ci]), range.contains(r.lowerBound), range.contains(r.upperBound) else {
            throw EditError.outsideClip
        }
        var kept = keptMask(clips[ci], over: range)
        for i in r { kept[i - range.lowerBound] = false }
        guard kept.contains(true) else { throw EditError.wouldOmitEverything }
        let segments = rebuiltSegments(clips[ci], range: range, kept: kept)
        try checkPlaceable(segments)
        clips[ci].segments = segments
    }

    /// Restores previously omitted words inside a clip.
    public mutating func restore(words r: ClosedRange<Int>, in id: ClipID) throws {
        try checkRange(r)
        let ci = try clipIndex(id)
        guard let range = indexRange(of: clips[ci]), range.contains(r.lowerBound), range.contains(r.upperBound) else {
            throw EditError.outsideClip
        }
        var kept = keptMask(clips[ci], over: range)
        for i in r { kept[i - range.lowerBound] = true }
        let segments = rebuiltSegments(clips[ci], range: range, kept: kept)
        try checkPlaceable(segments)
        clips[ci].segments = segments
    }

    /// Grows (or shrinks) a clip so it spans exactly `r` plus its current extent if
    /// `r` only touches one side. Newly included words are kept.
    public mutating func extendClip(_ id: ClipID, toInclude r: ClosedRange<Int>) throws {
        try checkRange(r)
        let ci = try clipIndex(id)
        guard let range = indexRange(of: clips[ci]) else { throw EditError.invalidRange }
        let newRange = min(range.lowerBound, r.lowerBound)...max(range.upperBound, r.upperBound)
        if let other = clips.first(where: { $0.id != id && (indexRange(of: $0)?.overlaps(newRange) ?? false) }) {
            throw EditError.overlapsClip(other.id)
        }
        var kept = Array(repeating: true, count: newRange.count)
        let old = keptMask(clips[ci], over: range)
        for i in range { kept[i - newRange.lowerBound] = old[i - range.lowerBound] }
        let firstOffset = clips[ci].segments.first?.inPoint.offset
        let lastOffset = clips[ci].segments.last?.outPoint.offset
        var segments = rebuiltSegments(clips[ci], range: newRange, kept: kept)
        // The clip's outer offsets follow the clip edges.
        segments[0].inPoint.offset = firstOffset
        segments[segments.count - 1].outPoint.offset = lastOffset
        try checkPlaceable(segments)
        clips[ci].segments = segments
    }

    /// Moves a clip's start (`start: true`) or end to word `w`, trimming or extending
    /// the clip. Trimming past an omission drops it with the material it's in; newly
    /// included words are kept. The moved edge's explicit offset is cleared (it was
    /// measured from the old word); the other edge keeps its own.
    public mutating func moveClipEdge(_ id: ClipID, start: Bool, to w: Int) throws {
        let ci = try clipIndex(id)
        guard words.indices.contains(w), let range = indexRange(of: clips[ci]) else { throw EditError.invalidRange }
        let newRange: ClosedRange<Int>
        if start {
            guard w <= range.upperBound else { throw EditError.invalidRange }
            newRange = w...range.upperBound
        } else {
            guard w >= range.lowerBound else { throw EditError.invalidRange }
            newRange = range.lowerBound...w
        }
        if let other = clips.first(where: { $0.id != id && (indexRange(of: $0)?.overlaps(newRange) ?? false) }) {
            throw EditError.overlapsClip(other.id)
        }
        let old = keptMask(clips[ci], over: range)
        let kept = newRange.map { range.contains($0) ? old[$0 - range.lowerBound] : true }
        guard kept.contains(true) else { throw EditError.wouldOmitEverything }
        let firstOffset = start ? nil : clips[ci].segments.first?.inPoint.offset
        let lastOffset = start ? clips[ci].segments.last?.outPoint.offset : nil
        var segments = rebuiltSegments(clips[ci], range: newRange, kept: kept)
        segments[0].inPoint.offset = firstOffset
        segments[segments.count - 1].outPoint.offset = lastOffset
        try checkPlaceable(segments)
        clips[ci].segments = segments
    }

    /// Moves a segment's in- or out-point to another word inside the same clip span.
    public mutating func moveBoundary(clip id: ClipID, segment k: Int, inPoint: Bool, to wordIndex: Int) throws {
        let ci = try clipIndex(id)
        guard clips[ci].segments.indices.contains(k), words.indices.contains(wordIndex) else { throw EditError.invalidRange }
        var segs = clips[ci].segments
        let lower = k > 0 ? (indexRange(of: segs[k - 1])?.upperBound ?? -1) + 1 : 0
        let upper = k < segs.count - 1 ? (indexRange(of: segs[k + 1])?.lowerBound ?? words.count) - 1 : words.count - 1
        guard (lower...upper).contains(wordIndex) else { throw EditError.invalidRange }
        if inPoint { segs[k].inPoint.word = words[wordIndex].id } else { segs[k].outPoint.word = words[wordIndex].id }
        guard indexRange(of: segs[k]) != nil else { throw EditError.invalidRange }
        let candidate = Clip(id: id, segments: segs)
        if let r = indexRange(of: candidate),
           let other = clips.first(where: { $0.id != id && (indexRange(of: $0)?.overlaps(r) ?? false) }) {
            throw EditError.overlapsClip(other.id)
        }
        try checkPlaceable(segs)
        clips[ci].segments = segs
    }

    public mutating func setOffset(clip id: ClipID, segment k: Int, inPoint: Bool, _ offset: Seconds?) throws {
        let ci = try clipIndex(id)
        guard clips[ci].segments.indices.contains(k) else { throw EditError.invalidRange }
        if inPoint { clips[ci].segments[k].inPoint.offset = offset } else { clips[ci].segments[k].outPoint.offset = offset }
    }

    public mutating func setName(clip id: ClipID, _ name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        clips[try clipIndex(id)].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public mutating func setNotes(clip id: ClipID, _ notes: String) throws {
        clips[try clipIndex(id)].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setSuggestions(clip id: ClipID, _ suggestions: [String]) throws {
        clips[try clipIndex(id)].suggestions = suggestions
    }

    public mutating func setSpeaker(paragraph id: ParagraphID, _ speaker: String?) {
        guard let i = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        paragraphs[i].speaker = speaker
    }

    /// Splits a paragraph so that word `i` starts a new one (same speaker), inserted
    /// right after it. Zoom-only paragraphs can't be split. Returns the new paragraph.
    @discardableResult
    public mutating func splitParagraph(atWord i: Int) throws -> ParagraphID {
        guard words.indices.contains(i), i > 0, words[i - 1].paragraph == words[i].paragraph,
              let pi = paragraphs.firstIndex(where: { $0.id == words[i].paragraph }),
              !paragraphs[pi].zoomOnly else { throw EditError.notSplittable }
        let old = paragraphs[pi]
        let id = ParagraphID((paragraphs.map(\.id.raw).max() ?? 0) + 1)
        paragraphs.insert(Paragraph(id: id, speaker: old.speaker, zoomCue: old.zoomCue), at: pi + 1)
        var j = i
        while j < words.count, words[j].paragraph == old.id {
            words[j].paragraph = id
            j += 1
        }
        return id
    }

    /// Merges a paragraph into the one before it (its words move; the earlier speaker wins).
    public mutating func mergeWithPrevious(paragraph id: ParagraphID) {
        guard let i = paragraphs.firstIndex(where: { $0.id == id }), i > 0,
              !paragraphs[i].zoomOnly, !paragraphs[i - 1].zoomOnly else { return }
        let target = paragraphs[i - 1].id
        for w in words.indices where words[w].paragraph == id { words[w].paragraph = target }
        paragraphs.remove(at: i)
    }
}
