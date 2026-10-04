import Foundation

public enum EditError: Error, Equatable, CustomStringConvertible {
    case invalidRange
    case overlapsClip(ClipID)
    case noSuchClip(ClipID)
    case outsideClip
    case wouldOmitEverything

    public var description: String {
        switch self {
        case .invalidRange: "the word range is invalid"
        case .overlapsClip(let id): "the range overlaps clip \(id)"
        case .noSuchClip(let id): "no clip \(id)"
        case .outsideClip: "the range is not inside the clip"
        case .wouldOmitEverything: "omitting this would leave the clip empty"
        }
    }
}

extension Project {
    private func checkRange(_ r: ClosedRange<Int>) throws {
        guard r.lowerBound >= 0, r.upperBound < words.count else { throw EditError.invalidRange }
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
        clips[ci].segments = rebuiltSegments(clips[ci], range: range, kept: kept)
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
        clips[ci].segments = rebuiltSegments(clips[ci], range: range, kept: kept)
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
        clips[ci].segments = rebuiltSegments(clips[ci], range: newRange, kept: kept)
        // The clip's outer offsets follow the clip edges.
        clips[ci].segments[0].inPoint.offset = firstOffset
        clips[ci].segments[clips[ci].segments.count - 1].outPoint.offset = lastOffset
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

    /// Merges a paragraph into the one before it (its words move; the earlier speaker wins).
    public mutating func mergeWithPrevious(paragraph id: ParagraphID) {
        guard let i = paragraphs.firstIndex(where: { $0.id == id }), i > 0,
              !paragraphs[i].zoomOnly, !paragraphs[i - 1].zoomOnly else { return }
        let target = paragraphs[i - 1].id
        for w in words.indices where words[w].paragraph == id { words[w].paragraph = target }
        paragraphs.remove(at: i)
    }
}
