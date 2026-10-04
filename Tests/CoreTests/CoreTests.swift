import Testing
@testable import Core

/// Ten words, word i spoken from i to i+0.8 s, all in one paragraph.
func sampleProject(count: Int = 10) -> Project {
    let p = ParagraphID(1)
    let words = (0..<count).map { i in
        Word(id: WordID(i + 1), text: "w\(i)", start: Double(i), end: Double(i) + 0.8, paragraph: p)
    }
    return Project(source: "video.mp4", paragraphs: [Paragraph(id: p, speaker: "A")], words: words)
}

@Suite struct ResolveTests {
    @Test func defaultPadsApplyOnlyAtClipEdges() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 2...7)
        try p.omit(words: 4...5, in: c)
        let segs = p.resolvedSegments(of: p.clip(c)!)
        #expect(segs.count == 2)
        #expect(abs(segs[0].start - (2 - 0.12)) < 1e-9)   // pre-pad
        #expect(abs(segs[0].end - 3.8) < 1e-9)            // omit out: 0
        #expect(abs(segs[1].start - 6.0) < 1e-9)          // omit in: 0
        #expect(abs(segs[1].end - (7.8 + 0.18)) < 1e-9)   // post-pad
    }

    @Test func explicitOffsetsOverrideDefaults() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 2...7)
        try p.omit(words: 4...5, in: c)
        try p.setOffset(clip: c, segment: 0, inPoint: true, -0.3)
        try p.setOffset(clip: c, segment: 0, inPoint: false, 0.04)
        try p.setOffset(clip: c, segment: 1, inPoint: true, -0.06)
        let segs = p.resolvedSegments(of: p.clip(c)!)
        #expect(abs(segs[0].start - 1.7) < 1e-9)
        #expect(abs(segs[0].end - 3.84) < 1e-9)
        #expect(abs(segs[1].start - 5.94) < 1e-9)
    }

    @Test func untimedAnchorFallsBackToNearestTimedWord() throws {
        var p = sampleProject()
        p.words[2].start = nil; p.words[2].end = nil
        let c = try p.makeClip(words: 2...4)
        let segs = p.resolvedSegments(of: p.clip(c)!)
        #expect(abs(segs[0].start - (3 - 0.12)) < 1e-9)
    }

    @Test func clampsToZeroDurationAndPreviousSegment() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 0...9)
        try p.omit(words: 5...5, in: c)
        try p.setOffset(clip: c, segment: 0, inPoint: false, 2.0)   // runs past the next in-point
        let segs = p.resolvedSegments(of: p.clip(c)!, sourceDuration: 9.5)
        #expect(segs[0].start == 0)
        #expect(segs[1].start >= segs[0].end)
        #expect(segs.last!.end == 9.5)
    }
}

@Suite struct EditTests {
    @Test func clipsCannotOverlap() throws {
        var p = sampleProject()
        try p.makeClip(words: 2...4)
        #expect(throws: EditError.self) { try p.makeClip(words: 4...6) }
        try p.makeClip(words: 5...6)
        try p.makeClip(words: 0...1)
        #expect(p.clips.map { p.indexRange(of: $0)!.lowerBound } == [0, 2, 5])
    }

    @Test func omitSplitsAndRestoreMerges() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 1...8)
        try p.omit(words: 3...4, in: c)
        try p.omit(words: 6...6, in: c)
        #expect(p.clip(c)!.segments.count == 3)
        #expect(p.omittedRanges(of: p.clip(c)!) == [3...4, 6...6])
        try p.restore(words: 3...6, in: c)
        #expect(p.clip(c)!.segments.count == 1)
        #expect(p.keptWords(of: p.clip(c)!).count == 8)
    }

    @Test func omitKeepsOffsetsOnUnchangedBoundaries() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 1...8)
        try p.setOffset(clip: c, segment: 0, inPoint: true, -0.5)
        try p.setOffset(clip: c, segment: 0, inPoint: false, 0.3)
        try p.omit(words: 4...5, in: c)
        let segs = p.clip(c)!.segments
        #expect(segs[0].inPoint.offset == -0.5)
        #expect(segs[0].outPoint.offset == nil)
        #expect(segs[1].outPoint.offset == 0.3)
    }

    @Test func cannotOmitEverythingOrOutsideClip() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 2...4)
        #expect(throws: EditError.wouldOmitEverything) { try p.omit(words: 2...4, in: c) }
        #expect(throws: EditError.outsideClip) { try p.omit(words: 5...6, in: c) }
    }

    @Test func extendKeepsOmitsAndOuterOffsets() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 3...6)
        try p.omit(words: 4...4, in: c)
        try p.setOffset(clip: c, segment: 0, inPoint: true, -0.2)
        try p.extendClip(c, toInclude: 1...2)
        let clip = p.clip(c)!
        #expect(p.indexRange(of: clip) == 1...6)
        #expect(clip.segments.count == 2)
        #expect(clip.segments[0].inPoint.offset == -0.2)
        #expect(clip.segments[0].inPoint.word == p.words[1].id)
    }

    @Test func moveBoundaryRespectsNeighbours() throws {
        var p = sampleProject()
        let a = try p.makeClip(words: 0...2)
        let b = try p.makeClip(words: 5...7)
        try p.moveBoundary(clip: b, segment: 0, inPoint: true, to: 4)
        #expect(p.indexRange(of: p.clip(b)!) == 4...7)
        #expect(throws: EditError.self) { try p.moveBoundary(clip: b, segment: 0, inPoint: true, to: 2) }
        try p.moveBoundary(clip: a, segment: 0, inPoint: false, to: 3)
        #expect(p.indexRange(of: p.clip(a)!) == 0...3)
    }

    @Test func mergeParagraphs() {
        var p = sampleProject()
        p.paragraphs.append(Paragraph(id: ParagraphID(2), speaker: "B"))
        for i in 5..<10 { p.words[i].paragraph = ParagraphID(2) }
        p.mergeWithPrevious(paragraph: ParagraphID(2))
        #expect(p.paragraphs.count == 1)
        #expect(p.words.allSatisfy { $0.paragraph == ParagraphID(1) })
    }
}

@Suite struct SlugTests {
    @Test func slugify() {
        #expect(Core.slugify("Budget update for FY27") == "budget-update-for-fy27")
        #expect(Core.slugify("  Q&A: the new building!  ") == "q-a-the-new-building")
        #expect(Core.slugify("Café résumé") == "cafe-resume")
    }

    @Test func unnamedAndDuplicateSlugs() throws {
        var p = sampleProject()
        let a = try p.makeClip(words: 0...1, name: "Intro")
        let b = try p.makeClip(words: 2...3)
        let c = try p.makeClip(words: 4...5, name: "intro")
        let s = p.slugs()
        #expect(s[a] == "intro")
        #expect(s[b] == "clip-02")
        #expect(s[c] == "intro-2")
        #expect(p.validate().contains { $0.severity == .warning && $0.message.contains("intro") })
    }
}

@Suite struct ZoomOnlyAndSplitTests {
    /// Words 0–2 are a Zoom-only paragraph, 3–9 spoken.
    func project() -> Project {
        var p = sampleProject()
        p.paragraphs.insert(Paragraph(id: ParagraphID(9), speaker: "Z", zoomOnly: true, zoomStart: 0), at: 0)
        for i in 0..<3 { p.words[i].paragraph = ParagraphID(9); p.words[i].start = nil; p.words[i].end = nil }
        return p
    }

    @Test func boundariesCannotLandInZoomOnlyText() throws {
        var p = project()
        #expect(throws: EditError.zoomOnlyText) { try p.makeClip(words: 1...5) }
        let c = try p.makeClip(words: 3...6)
        #expect(throws: EditError.zoomOnlyText) { try p.extendClip(c, toInclude: 2...2) }
        #expect(throws: EditError.zoomOnlyText) { try p.moveBoundary(clip: c, segment: 0, inPoint: true, to: 0) }
        #expect(p.indexRange(of: p.clip(c)!) == 3...6)   // unchanged after failed edits
        #expect(p.validate().allSatisfy { $0.severity != .error })
    }

    @Test func validateFlagsHandBuiltViolations() {
        var p = project()
        p.clips = [Clip(id: ClipID(1), segments: [Segment(inPoint: Boundary(word: p.words[2].id), outPoint: Boundary(word: p.words[5].id))])]
        #expect(p.validate().contains { $0.severity == .error && $0.message.contains("Zoom-only") })
    }

    @Test func splitParagraph() throws {
        var p = project()
        let id = try p.splitParagraph(atWord: 6)
        #expect(p.paragraphs.map(\.id) == [ParagraphID(9), ParagraphID(1), id])
        #expect(p.words[5].paragraph == ParagraphID(1) && p.words[6].paragraph == id && p.words[9].paragraph == id)
        #expect(p.paragraph(id)?.speaker == "A")
        #expect(throws: EditError.notSplittable) { try p.splitParagraph(atWord: 6) }   // already first word
        #expect(throws: EditError.notSplittable) { try p.splitParagraph(atWord: 1) }   // Zoom-only
        p.mergeWithPrevious(paragraph: id)
        #expect(p.paragraphs.count == 2)
    }
}
