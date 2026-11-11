import Foundation

public enum EditError: Error, Equatable, CustomStringConvertible {
    case invalidRange
    case overlapsClip(ClipID)
    case noSuchClip(ClipID)
    case outsideClip
    case wouldOmitEverything
    case zoomOnlyText
    case notSplittable
    case emptyParagraph
    case notConsecutive
    case differentSpeakers
    case speakerInUse(String)

    public var description: String {
        switch self {
        case .invalidRange: "the word range is invalid"
        case .overlapsClip(let id): "the range overlaps clip \(id)"
        case .noSuchClip(let id): "no clip \(id)"
        case .outsideClip: "the range is not inside the clip"
        case .wouldOmitEverything: "omitting this would leave the clip empty"
        case .zoomOnlyText: "clip boundaries and omissions can't be placed in Zoom-only text (it isn't in the recording)"
        case .notSplittable: "the paragraph can't be split there"
        case .notConsecutive: "only consecutive clips (with no other clip between them) can be merged"
        case .emptyParagraph: "a paragraph can't be left empty (omit its words instead)"
        case .differentSpeakers: "paragraphs with different speakers can't be merged (assign the words to a speaker instead)"
        case .speakerInUse(let name): "\(name) still has paragraphs; assign them to someone else first"
        }
    }
}

extension Project {
    func checkRange(_ r: ClosedRange<Int>) throws {
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

    /// A clip's word range and explicit edge offsets, as `layOut` takes them.
    private struct Span {
        var clip: Clip
        var range: ClosedRange<Int>
        var start: Seconds?
        var end: Seconds?
    }

    /// The clips as spans, in document order.
    private func spans() throws -> [Span] {
        try clips.map { c in
            guard let r = indexRange(of: c) else { throw EditError.invalidRange }
            return Span(clip: c, range: r, start: c.segments.first?.inPoint.offset, end: c.segments.last?.outPoint.offset)
        }
    }

    /// Rebuilds every clip's segments, and the omissions outside clips, from `map`.
    /// `spans` are the clips in document order, not overlapping. A clip that would start
    /// or end on omitted words shrinks to its first and last kept words (those words stay
    /// omitted, outside it); a clip edge keeps its explicit offset only where it didn't move.
    private mutating func layOut(_ spans: [Span], _ map: OmissionMap) throws {
        var laid: [Clip] = []
        var covered = Array(repeating: false, count: words.count)
        for s in spans {
            guard let lo = s.range.first(where: { !map.omitted[$0] }),
                  let hi = s.range.last(where: { !map.omitted[$0] }) else { throw EditError.wouldOmitEverything }
            var segments: [Segment] = []
            var i = lo
            while i <= hi {
                var j = i
                while j < hi, !map.omitted[j + 1] { j += 1 }
                let inOffset = i == lo ? (lo == s.range.lowerBound ? s.start : nil) : map.resumeOffset[i - 1]
                let outOffset = j == hi ? (hi == s.range.upperBound ? s.end : nil) : map.cutOffset[j + 1]
                segments.append(Segment(inPoint: Boundary(word: words[i].id, offset: inOffset),
                                        outPoint: Boundary(word: words[j].id, offset: outOffset)))
                i = j + 1
                while i <= hi, map.omitted[i] { i += 1 }
            }
            try checkPlaceable(segments)
            var clip = s.clip
            clip.segments = segments
            laid.append(clip)
            for k in lo...hi { covered[k] = true }
        }
        // A run never straddles a clip edge (clips start and end on kept words).
        omissions = map.runs().filter { !covered[$0.lowerBound] }.map {
            Omission(first: words[$0.lowerBound].id, last: words[$0.upperBound].id,
                     cutOffset: map.cutOffset[$0.lowerBound], resumeOffset: map.resumeOffset[$0.upperBound])
        }
        clips = laid
    }

    /// Makes a clip of words `r`. Words in `r` that were omitted stay omitted; if `r`
    /// starts or ends with omitted words, the clip starts or ends at the nearest kept word.
    @discardableResult
    public mutating func makeClip(words r: ClosedRange<Int>, name: String? = nil) throws -> ClipID {
        try checkRange(r)
        if let other = clips.first(where: { indexRange(of: $0)?.overlaps(r) ?? false }) {
            throw EditError.overlapsClip(other.id)
        }
        let id = ClipID((clips.map(\.id.raw).max() ?? 0) + 1)
        var all = try spans()
        let at = all.firstIndex { $0.range.lowerBound > r.upperBound } ?? all.count
        all.insert(Span(clip: Clip(id: id, name: name, segments: []), range: r), at: at)
        try layOut(all, omissionMap())
        return id
    }

    /// Merges two or more consecutive clips (no other clip between them) into one that
    /// runs from the first clip's start to the last clip's end. The stretches between
    /// them become omissions (clips that touch simply join); omissions inside the clips
    /// are kept. Every explicit offset is kept too: a clip's adjusted end becomes the
    /// start of the omission after it, and the next clip's adjusted start becomes that
    /// omission's end. The merged clip takes the first clip's name (or the first name any
    /// of them has) and all their notes. Returns the merged clip's id (the first clip's).
    @discardableResult
    public mutating func mergeClips(_ ids: [ClipID]) throws -> ClipID {
        let indices = try Set(ids).map { try clipIndex($0) }.sorted()
        guard indices.count >= 2 else { throw EditError.invalidRange }
        guard indices.last! - indices.first! == indices.count - 1 else { throw EditError.notConsecutive }
        var all = try spans()
        let parts = indices.map { all[$0] }
        var map = omissionMap()
        for (a, b) in zip(parts, parts.dropFirst()) where a.range.upperBound + 1 < b.range.lowerBound {
            let gap = (a.range.upperBound + 1)...(b.range.lowerBound - 1)
            for i in gap { map.omitted[i] = true }
            if let o = a.end { map.cutOffset[gap.lowerBound] = o }
            if let o = b.start { map.resumeOffset[gap.upperBound] = o }
        }
        var merged = parts[0].clip
        merged.name = parts.lazy.compactMap(\.clip.name).first
        merged.notes = parts.map(\.clip.notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
        merged.suggestions = []
        all.replaceSubrange(indices.first!...indices.last!, with: [
            Span(clip: merged, range: parts.first!.range.lowerBound...parts.last!.range.upperBound,
                 start: parts.first!.start, end: parts.last!.end),
        ])
        try layOut(all, map)
        return merged.id
    }

    /// Splits a clip in two so the second starts at word `w` (the first ends at the last
    /// kept word before it). Each part keeps its own omissions and their offsets; an
    /// omission that `w` falls inside or next to ends up between the two clips. The
    /// original start and end keep their offsets; the two new edges get the default
    /// pads. The first part keeps the name, notes and suggestions; the second is unnamed.
    /// Both keep the clip's auto-levels setting.
    /// Returns the second clip's id.
    @discardableResult
    public mutating func splitClip(_ id: ClipID, atWord w: Int) throws -> ClipID {
        let ci = try clipIndex(id)
        var all = try spans()
        let s = all[ci]
        guard w > s.range.lowerBound, w <= s.range.upperBound else { throw EditError.invalidRange }
        let newID = ClipID((clips.map(\.id.raw).max() ?? 0) + 1)
        all[ci] = Span(clip: s.clip, range: s.range.lowerBound...(w - 1), start: s.start, end: nil)
        all.insert(Span(clip: Clip(id: newID, segments: [], autoLevels: s.clip.autoLevels), range: w...s.range.upperBound, start: nil, end: s.end), at: ci + 1)
        try layOut(all, omissionMap())
        return newID
    }

    /// Deletes a clip. Its words stay in the transcript, and its omissions stay omitted.
    public mutating func deleteClip(_ id: ClipID) throws {
        let ci = try clipIndex(id)
        let map = omissionMap()
        var all = try spans()
        all.remove(at: ci)
        try layOut(all, map)
    }

    /// Omits words wherever they are. Inside a clip they are cut out of it (omitting a
    /// clip's first or last words shrinks the clip); outside every clip they stay
    /// omitted, so a clip later made over them leaves them out.
    public mutating func omit(words r: ClosedRange<Int>) throws {
        try checkRange(r)
        if r.contains(where: { isZoomOnly(wordAt: $0) }) { throw EditError.zoomOnlyText }
        var map = omissionMap()
        for i in r { map.omitted[i] = true }
        try layOut(try spans(), map)
    }

    /// Puts omitted words back, inside clips or outside them.
    public mutating func restore(words r: ClosedRange<Int>) throws {
        try checkRange(r)
        var map = omissionMap()
        for i in r { map.omitted[i] = false }
        try layOut(try spans(), map)
    }

    private func checkInside(_ r: ClosedRange<Int>, _ id: ClipID) throws {
        try checkRange(r)
        guard let range = indexRange(of: clips[try clipIndex(id)]), range.contains(r.lowerBound), range.contains(r.upperBound) else {
            throw EditError.outsideClip
        }
    }

    /// Omits words that must lie inside clip `id`.
    public mutating func omit(words r: ClosedRange<Int>, in id: ClipID) throws {
        try checkInside(r, id)
        try omit(words: r)
    }

    /// Restores words that must lie inside clip `id`.
    public mutating func restore(words r: ClosedRange<Int>, in id: ClipID) throws {
        try checkInside(r, id)
        try restore(words: r)
    }

    /// Grows (or shrinks) a clip so it spans exactly `r` plus its current extent if
    /// `r` only touches one side. Newly included words keep their omissions.
    public mutating func extendClip(_ id: ClipID, toInclude r: ClosedRange<Int>) throws {
        try checkRange(r)
        let ci = try clipIndex(id)
        var all = try spans()
        let range = all[ci].range
        let newRange = min(range.lowerBound, r.lowerBound)...max(range.upperBound, r.upperBound)
        if let other = clips.first(where: { $0.id != id && (indexRange(of: $0)?.overlaps(newRange) ?? false) }) {
            throw EditError.overlapsClip(other.id)
        }
        // The clip's outer offsets follow the clip edges.
        all[ci].range = newRange
        try layOut(all, omissionMap())
    }

    /// Moves a clip's start (`start: true`) or end to word `w`, trimming or extending
    /// the clip. Omissions in the trimmed or newly included words stay as they are.
    /// The moved edge's explicit offset is cleared (it was measured from the old word);
    /// the other edge keeps its own.
    public mutating func moveClipEdge(_ id: ClipID, start: Bool, to w: Int) throws {
        let ci = try clipIndex(id)
        guard words.indices.contains(w) else { throw EditError.invalidRange }
        var all = try spans()
        let range = all[ci].range
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
        all[ci].range = newRange
        if start { all[ci].start = nil } else { all[ci].end = nil }
        try layOut(all, omissionMap())
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
        var p = self
        p.clips[ci].segments = segs
        try p.layOut(try p.spans(), p.omissionMap())
        self = p
    }

    /// Re-derives the clips' segments and the outside omissions from the current state,
    /// merging touching omissions and dropping outside omissions a clip now covers.
    public mutating func normalizeOmissions() throws {
        try layOut(try spans(), omissionMap())
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

    public mutating func setAutoLevels(clip id: ClipID, _ on: Bool) throws {
        clips[try clipIndex(id)].autoLevels = on
    }

    public mutating func setNotes(clip id: ClipID, _ notes: String) throws {
        clips[try clipIndex(id)].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setSuggestions(clip id: ClipID, _ suggestions: [String]) throws {
        clips[try clipIndex(id)].suggestions = suggestions
    }

    /// Sets one paragraph's speaker (nil or blank = none), adding a new name to the roster.
    public mutating func setSpeaker(paragraph id: ParagraphID, _ speaker: String?) {
        guard let i = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        paragraphs[i].speaker = Self.speakerName(speaker)
        addSpeaker(speaker)
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

    /// Merges a paragraph into the one before it (its words move). Every paragraph has
    /// one speaker, so paragraphs with different speakers can't be merged.
    public mutating func mergeWithPrevious(paragraph id: ParagraphID) throws {
        guard let i = paragraphs.firstIndex(where: { $0.id == id }), i > 0,
              !paragraphs[i].zoomOnly, !paragraphs[i - 1].zoomOnly else { return }
        guard paragraphs[i].speaker == paragraphs[i - 1].speaker else { throw EditError.differentSpeakers }
        let target = paragraphs[i - 1].id
        for w in words.indices where words[w].paragraph == id { words[w].paragraph = target }
        paragraphs.remove(at: i)
    }
}
