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

    @Test func mergeParagraphs() throws {
        var p = sampleProject()
        p.paragraphs.append(Paragraph(id: ParagraphID(2), speaker: "B"))
        for i in 5..<10 { p.words[i].paragraph = ParagraphID(2) }
        #expect(throws: EditError.differentSpeakers) { try p.mergeWithPrevious(paragraph: ParagraphID(2)) }
        #expect(p.paragraphs.count == 2)
        p.setSpeaker(paragraph: ParagraphID(2), "A")
        try p.mergeWithPrevious(paragraph: ParagraphID(2))
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
        try p.mergeWithPrevious(paragraph: id)
        #expect(p.paragraphs.count == 2)
    }
}

@Suite struct BoundaryTests {
    /// Three words with gaps: "one" 1.0–1.4, "two" 2.0–2.4, "three" 3.0–3.4.
    func project() throws -> (Project, ClipID) {
        let words = [("one", 1.0, 1.4), ("two", 2.0, 2.4), ("three", 3.0, 3.4)].enumerated().map { i, w in
            Word(id: WordID(i), text: w.0, start: w.1, end: w.2, paragraph: ParagraphID(0))
        }
        var p = Project(source: "x.mp4", paragraphs: [Paragraph(id: ParagraphID(0))], words: words)
        let id = try p.makeClip(words: 0...2)
        try p.omit(words: 1...1, in: id)
        return (p, id)
    }

    @Test func rolesAnchorsAndTimes() throws {
        let (p, id) = try project()
        let b = p.boundaries(of: p.clip(id)!)
        #expect(b.map { p.role(of: $0) } == [.clipStart, .omissionStart, .omissionEnd, .clipEnd])
        #expect(b.map { p.anchorWord(of: $0) } == [0, 0, 2, 2])
        #expect(p.boundaryTime(of: b[0])! == 1.0 - p.settings.prePad)
        #expect(p.boundaryTime(of: b[1])! == 1.4)
        #expect(p.boundaryTime(of: b[3])! == 3.4 + p.settings.postPad)
    }

    @Test func silenceSnapFindsTheQuietMiddle() throws {
        let (p, id) = try project()
        // Loud everywhere except 1.6–1.8 s.
        var rms = [Float](repeating: 0.5, count: 800)
        for i in 320..<360 { rms[i] = 0.001 }
        let env = Envelope(bucketsPerSecond: 200, rms: rms)
        let out = BoundaryRef(clip: id, segment: 0, inPoint: false)   // after "one", gap 1.4–1.9
        let offset = try #require(p.silenceOffset(of: out, envelope: env))
        #expect(abs(1.4 + offset - 1.7) < 0.02)
    }

    @Test func frameSnap() throws {
        let (p, id) = try project()
        let start = BoundaryRef(clip: id, segment: 0, inPoint: true)   // 1.0 - 0.12 = 0.88
        let offset = try #require(p.frameSnappedOffset(of: start, fps: 30))
        #expect(abs((1.0 + offset) * 30 - ((1.0 + offset) * 30).rounded()) < 0.03)
        #expect(abs(1.0 + offset - 0.88) <= 1.0 / 60 + 0.001)
    }
}

@Suite struct ClipEdgeTests {
    /// Words 0…11, one per second; clip 1…10 with 4…5 omitted and offsets on both edges.
    func project() throws -> (Project, ClipID) {
        let words = (0..<12).map { Word(id: WordID($0), text: "w\($0)", start: Double($0), end: Double($0) + 0.8, paragraph: ParagraphID(0)) }
        var p = Project(source: "x", paragraphs: [Paragraph(id: ParagraphID(0))], words: words)
        let id = try p.makeClip(words: 1...10)
        try p.omit(words: 4...5, in: id)
        try p.setOffset(clip: id, segment: 0, inPoint: true, -0.3)
        try p.setOffset(clip: id, segment: 1, inPoint: false, 0.4)
        return (p, id)
    }

    @Test func endMovedBeforeAnOmissionDropsIt() throws {
        var (p, id) = try project()
        try p.moveClipEdge(id, start: false, to: 3)
        let c = p.clip(id)!
        #expect(c.segments.count == 1)
        #expect(p.indexRange(of: c) == 1...3)
        #expect(c.segments[0].inPoint.offset == -0.3)   // the start kept its offset
        #expect(c.segments[0].outPoint.offset == nil)   // the moved end's was cleared
    }

    @Test func startMovedPastAnOmissionDropsIt() throws {
        var (p, id) = try project()
        try p.moveClipEdge(id, start: true, to: 7)
        let c = p.clip(id)!
        #expect(c.segments.count == 1)
        #expect(p.indexRange(of: c) == 7...10)
        #expect(c.segments[0].inPoint.offset == nil)
        #expect(c.segments[0].outPoint.offset == 0.4)
    }

    @Test func trimInsideKeepsTheOmissionAndExtendKeepsNewWords() throws {
        var (p, id) = try project()
        try p.moveClipEdge(id, start: false, to: 7)
        #expect(p.clip(id)!.segments.map { p.indexRange(of: $0)! } == [1...3, 6...7])
        try p.moveClipEdge(id, start: false, to: 11)
        #expect(p.clip(id)!.segments.map { p.indexRange(of: $0)! } == [1...3, 6...11])
        #expect(throws: EditError.self) { try p.moveClipEdge(id, start: false, to: 0) }
    }

    @Test func edgeLandingInsideTheOmissionSnapsToKeptWords() throws {
        var (p, id) = try project()
        try p.moveClipEdge(id, start: false, to: 5)   // end inside the omitted 4…5
        #expect(p.clip(id)!.segments.map { p.indexRange(of: $0)! } == [1...3])
    }
}

@Suite struct MergeClipsTests {
    /// Words 0…19; clips A 1…4 (with 2 omitted), B 7…9, C 12…14, D 17…18.
    func project() throws -> (Project, [ClipID]) {
        let words = (0..<20).map { Word(id: WordID($0), text: "w\($0)", start: Double($0), end: Double($0) + 0.8, paragraph: ParagraphID(0)) }
        var p = Project(source: "x", paragraphs: [Paragraph(id: ParagraphID(0))], words: words)
        let a = try p.makeClip(words: 1...4, name: "A")
        try p.omit(words: 2...2, in: a)
        try p.setOffset(clip: a, segment: 0, inPoint: true, -0.3)
        try p.setNotes(clip: a, "Note A")
        let b = try p.makeClip(words: 7...9)
        try p.setNotes(clip: b, "Note B")
        let c = try p.makeClip(words: 12...14, name: "C")
        try p.setOffset(clip: c, segment: 0, inPoint: false, 0.25)
        let d = try p.makeClip(words: 17...18, name: "D")
        return (p, [a, b, c, d])
    }

    @Test func gapsBecomeOmissionsAndInnerOmissionsStay() throws {
        var (p, ids) = try project()
        let m = try p.mergeClips([ids[2], ids[0], ids[1]])   // order of the request doesn't matter
        #expect(p.clips.count == 2)
        let c = p.clip(m)!
        #expect(c.segments.map { p.indexRange(of: $0)! } == [1...1, 3...4, 7...9, 12...14])
        #expect(c.name == "A")
        #expect(c.notes == "Note A\n\nNote B")
        #expect(c.segments.first!.inPoint.offset == -0.3)    // the first clip's start offset
        #expect(c.segments.last!.outPoint.offset == 0.25)    // the last clip's end offset
        #expect(p.validate().filter { $0.severity == .error }.isEmpty)
    }

    /// Adjusted clip edges become the edges of the omission between the clips.
    @Test func clipEdgeAdjustmentsMoveToTheOmissionBetween() throws {
        var (p, ids) = try project()
        try p.setOffset(clip: ids[1], segment: 0, inPoint: false, 0.4)    // B's end
        try p.setOffset(clip: ids[2], segment: 0, inPoint: true, -0.15)   // C's start
        let m = try p.mergeClips([ids[1], ids[2]])
        let segs = p.clip(m)!.segments
        #expect(segs.map { p.indexRange(of: $0)! } == [7...9, 12...14])
        #expect(segs[0].outPoint.offset == 0.4)     // start of the omitted w10–w11
        #expect(segs[1].inPoint.offset == -0.15)    // end of the omitted w10–w11
        #expect(p.resolvedSegments(of: p.clip(m)!).map(\.end).first == 9.8 + 0.4)
    }

    @Test func onlyConsecutiveClipsMerge() throws {
        var (p, ids) = try project()
        #expect(throws: EditError.notConsecutive) { try p.mergeClips([ids[0], ids[2]]) }
        #expect(throws: EditError.invalidRange) { try p.mergeClips([ids[0]]) }
    }

    @Test func nameComesFromTheFirstNamedClip() throws {
        var (p, ids) = try project()
        try p.setName(clip: ids[0], nil)
        let m = try p.mergeClips([ids[0], ids[1], ids[2]])
        #expect(p.clip(m)!.name == "C")
    }
}

@Suite struct SplitClipTests {
    /// Words 0…19; one clip 2…15 with 5…6 and 11 omitted, adjusted start and end, and
    /// an adjusted omission edge.
    func project() throws -> (Project, ClipID) {
        let words = (0..<20).map { Word(id: WordID($0), text: "w\($0)", start: Double($0), end: Double($0) + 0.8, paragraph: ParagraphID(0)) }
        var p = Project(source: "x", paragraphs: [Paragraph(id: ParagraphID(0))], words: words)
        let id = try p.makeClip(words: 2...15, name: "Whole")
        try p.omit(words: 5...6, in: id)
        try p.omit(words: 11...11, in: id)
        try p.setOffset(clip: id, segment: 0, inPoint: true, -0.3)
        try p.setOffset(clip: id, segment: 2, inPoint: false, 0.4)
        try p.setOffset(clip: id, segment: 0, inPoint: false, 0.05)   // edge of the 5…6 omission
        try p.setNotes(clip: id, "Notes")
        return (p, id)
    }

    @Test func eachPartKeepsItsOmissionsAndOffsets() throws {
        var (p, id) = try project()
        let second = try p.splitClip(id, atWord: 9)
        let a = p.clip(id)!, b = p.clip(second)!
        #expect(p.clips.map(\.id) == [id, second])
        #expect(a.segments.map { p.indexRange(of: $0)! } == [2...4, 7...8])
        #expect(b.segments.map { p.indexRange(of: $0)! } == [9...10, 12...15])
        #expect(a.segments[0].inPoint.offset == -0.3)      // original start
        #expect(a.segments[0].outPoint.offset == 0.05)     // omission edge kept
        #expect(a.segments[1].outPoint.offset == nil)      // new end: default pad
        #expect(b.segments[0].inPoint.offset == nil)       // new start: default pad
        #expect(b.segments[1].outPoint.offset == 0.4)      // original end
        #expect(a.name == "Whole" && a.notes == "Notes" && b.name == nil)
    }

    @Test func bothPartsKeepAutoLevels() throws {
        var (p, id) = try project()
        try p.setAutoLevels(clip: id, true)
        let second = try p.splitClip(id, atWord: 9)
        #expect(p.clip(id)!.autoLevels && p.clip(second)!.autoLevels)
    }

    @Test func bothPartsKeepTheExportSetting() throws {
        var (p, id) = try project()
        try p.setExport(clip: id, false)
        let second = try p.splitClip(id, atWord: 9)
        #expect(!p.clip(id)!.export && !p.clip(second)!.export)
        try p.mergeClips([id, second])
        #expect(!p.clips[0].export)
    }

    @Test func aChosenStillStaysWithTheFirstPartAndSurvivesAMerge() throws {
        var (p, id) = try project()
        try p.setStill(clip: id, 1234.5)
        let second = try p.splitClip(id, atWord: 9)
        #expect(p.clip(id)!.still == 1234.5 && p.clip(second)!.still == nil)
        try p.mergeClips([id, second])
        #expect(p.clips[0].still == 1234.5)
        try p.setStill(clip: p.clips[0].id, nil)
        #expect(p.clips[0].still == nil)
    }

    @Test func splittingInsideAnOmissionLeavesItBetweenTheClips() throws {
        var (p, id) = try project()
        let second = try p.splitClip(id, atWord: 6)       // inside the omitted 5…6
        #expect(p.clip(id)!.segments.map { p.indexRange(of: $0)! } == [2...4])
        #expect(p.clip(second)!.segments.map { p.indexRange(of: $0)! } == [7...10, 12...15])
        #expect(p.omissions.map { p.indexRange(of: $0)! } == [5...6])
        #expect(p.omissions[0].cutOffset == 0.05)
        #expect(p.validate().filter { $0.severity == .error }.isEmpty)
    }

    @Test func splitPointMustLeaveWordsOnBothSides() throws {
        var (p, id) = try project()
        #expect(throws: EditError.invalidRange) { try p.splitClip(id, atWord: 2) }    // the first word
        #expect(throws: EditError.invalidRange) { try p.splitClip(id, atWord: 16) }   // outside
    }

    @Test func splitThenMergeRestoresTheCuts() throws {
        var (p, id) = try project()
        let original = p.clip(id)!.segments.map { p.indexRange(of: $0)! }
        let second = try p.splitClip(id, atWord: 9)
        try p.mergeClips([id, second])
        #expect(p.clip(id)!.segments.map { p.indexRange(of: $0)! } == original)
    }
}

@Suite struct OutsideOmissionTests {
    func ranges(_ p: Project) -> [ClosedRange<Int>] { p.omissions.map { p.indexRange(of: $0)! } }

    @Test func omissionOutsideAClipIsKeptAndANewClipHonoursIt() throws {
        var p = sampleProject()
        try p.omit(words: 3...4)
        #expect(ranges(p) == [3...4])
        let c = try p.makeClip(words: 1...8)
        #expect(p.clip(c)!.segments.map { p.indexRange(of: $0)! } == [1...2, 5...8])
        #expect(p.omissions.isEmpty)
    }

    @Test func deletingAClipKeepsItsOmissionsAndOffsets() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 1...8)
        try p.omit(words: 3...4)
        try p.setOffset(clip: c, segment: 0, inPoint: false, 0.05)
        try p.setOffset(clip: c, segment: 1, inPoint: true, -0.04)
        try p.deleteClip(c)
        #expect(ranges(p) == [3...4])
        #expect(p.omissions[0].cutOffset == 0.05 && p.omissions[0].resumeOffset == -0.04)
        let again = try p.makeClip(words: 0...9)
        let segs = p.clip(again)!.segments
        #expect(segs.map { p.indexRange(of: $0)! } == [0...2, 5...9])
        #expect(segs[0].outPoint.offset == 0.05 && segs[1].inPoint.offset == -0.04)
    }

    @Test func trimmingAndExtendingKeepOmissions() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 1...8)
        try p.omit(words: 6...7)
        try p.moveClipEdge(c, start: false, to: 5)
        #expect(p.indexRange(of: p.clip(c)!) == 1...5)
        #expect(ranges(p) == [6...7])
        try p.moveClipEdge(c, start: false, to: 9)
        #expect(p.omittedRanges(of: p.clip(c)!) == [6...7])
        #expect(p.omissions.isEmpty)
        try p.extendClip(c, toInclude: 0...0)
        #expect(p.omittedRanges(of: p.clip(c)!) == [6...7])
    }

    @Test func clipEdgesSkipOmittedWords() throws {
        var p = sampleProject()
        try p.omit(words: 3...5)
        #expect(throws: EditError.wouldOmitEverything) { try p.makeClip(words: 3...5) }
        let c = try p.makeClip(words: 2...5)
        #expect(p.indexRange(of: p.clip(c)!) == 2...2)
        #expect(ranges(p) == [3...5])
    }

    @Test func omittingAcrossAClipEdgeShrinksTheClip() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 3...6)
        try p.omit(words: 5...8)
        #expect(p.indexRange(of: p.clip(c)!) == 3...4)
        #expect(ranges(p) == [5...8])
        try p.restore(words: 7...8)
        #expect(ranges(p) == [5...6])
    }

    @Test func restoreAndOmitOutsideClipsSplitAndJoinRuns() throws {
        var p = sampleProject()
        try p.omit(words: 2...5)
        try p.restore(words: 3...4)
        #expect(ranges(p) == [2...2, 5...5])
        try p.omit(words: 3...4)
        #expect(ranges(p) == [2...5])
    }

    @Test func mergingAcrossAnOutsideOmission() throws {
        var p = sampleProject()
        let a = try p.makeClip(words: 0...2)
        try p.omit(words: 4...4)
        let b = try p.makeClip(words: 6...8)
        try p.mergeClips([a, b])
        #expect(p.omittedRanges(of: p.clip(a)!) == [3...5])
        #expect(p.omissions.isEmpty)
    }

    @Test func zoomOnlyWordsCantBeOmitted() throws {
        var p = sampleProject()
        p.paragraphs.append(Paragraph(id: ParagraphID(2), zoomOnly: true))
        p.words[9].paragraph = ParagraphID(2)
        #expect(throws: EditError.zoomOnlyText) { try p.omit(words: 8...9) }
    }
}

@Suite struct SpeakerTests {
    /// Words 0–4 in paragraph 1 (A), 5–9 in paragraph 2 (B).
    func project() -> Project {
        var p = sampleProject()
        p.paragraphs.append(Paragraph(id: ParagraphID(2), speaker: "B"))
        for i in 5..<10 { p.words[i].paragraph = ParagraphID(2) }
        p.normalizeSpeakers()
        return p
    }

    func speakers(_ p: Project) -> [String?] { p.words.map { p.paragraph($0.paragraph)?.speaker } }

    @Test func rosterIsInOrderOfFirstAppearanceThenUnused() {
        var p = project()
        p.speakers = ["Unused", "B"]
        #expect(p.speakersInOrder() == ["A", "B", "Unused"])
        p.normalizeSpeakers()
        #expect(p.speakers == ["A", "B", "Unused"])
    }

    @Test func assignMidParagraphSplitsBothSides() throws {
        var p = project()
        try p.assignSpeaker(words: 2...3, "C")
        #expect(speakers(p) == ["A", "A", "C", "C", "A", "B", "B", "B", "B", "B"])
        #expect(p.paragraphs.count == 4)
        #expect(p.speakers == ["A", "B", "C"])
    }

    @Test func assignAcrossParagraphsAndWholeParagraphs() throws {
        var p = project()
        try p.assignSpeaker(words: 3...6, "C")
        #expect(speakers(p) == ["A", "A", "A", "C", "C", "C", "C", "B", "B", "B"])
        #expect(p.paragraphs.count == 3)   // C's words join into one paragraph
        var q = project()
        try q.assignSpeaker(words: 5...9, "A")
        #expect(q.paragraphs.count == 1)   // a whole paragraph joins the A paragraph before it
        #expect(speakers(q).allSatisfy { $0 == "A" })
    }

    @Test func assignJoinsTheNeighbourWithTheSameSpeaker() throws {
        // "Thank" ends A's paragraph and "you." starts B's: give "you." to A.
        var p = project()
        let clips = p.clips
        try p.assignSpeaker(words: 5...5, "A")
        #expect(speakers(p) == ["A", "A", "A", "A", "A", "A", "B", "B", "B", "B"])
        #expect(p.paragraphs.count == 2)
        #expect(p.words[4].paragraph == p.words[5].paragraph)
        #expect(p.clips == clips)
        // And back at the end of a paragraph: the B words before join B after.
        try p.assignSpeaker(words: 5...5, "B")
        #expect(p.paragraphs.count == 2)
        #expect(p.words[5].paragraph == p.words[6].paragraph)
    }

    @Test func assignRefusesZoomOnlyText() {
        var p = project()
        p.paragraphs.insert(Paragraph(id: ParagraphID(9), speaker: "Z", zoomOnly: true, zoomStart: 0), at: 0)
        p.words[0].paragraph = ParagraphID(9)
        #expect(throws: EditError.zoomOnlyText) { try p.assignSpeaker(words: 0...2, "C") }
    }

    @Test func renameAndMerge() throws {
        var p = project()
        p.renameSpeaker("A", to: "Alice")
        #expect(p.speakers == ["Alice", "B"])
        #expect(p.paragraphs[0].speaker == "Alice")
        p.renameSpeaker("B", to: "Alice")   // an existing name merges the two
        #expect(p.speakers == ["Alice"])
        #expect(p.paragraphs.allSatisfy { $0.speaker == "Alice" })
        try p.mergeWithPrevious(paragraph: ParagraphID(2))
        #expect(p.paragraphs.count == 1)
    }

    @Test func addAndRemove() throws {
        var p = project()
        p.addSpeaker("  Carol ")
        p.addSpeaker("Carol")
        p.addSpeaker("   ")
        #expect(p.speakers == ["A", "B", "Carol"])
        #expect(throws: EditError.speakerInUse("A")) { try p.removeSpeaker("A") }
        try p.removeSpeaker("Carol")
        #expect(p.speakers == ["A", "B"])
    }
}

@Suite struct VoiceTests {
    @Test func wordsTakeTheVoiceTheyOverlapMost() {
        let p = sampleProject(count: 6)   // word i spans i…i+0.8
        let turns = [VoiceTurn(start: 0, end: 2.5, voice: "S1"), VoiceTurn(start: 2.5, end: 3.9, voice: "S2"),
                     VoiceTurn(start: 5.5, end: 9, voice: "S1")]
        // Word 4 (4.0–4.8) is in no turn but within reach of S2 and S1; it takes S2, the nearer.
        #expect(p.voices(from: turns) == ["S1", "S1", "S1", "S2", "S2", "S1"])
        #expect(p.voices(from: []) == Array(repeating: nil, count: 6))
    }

    @Test func everyVoiceChangeStartsAParagraphAndNamesAreSet() throws {
        var p = sampleProject()
        let c = try p.makeClip(words: 2...7)
        try p.omit(words: 4...4, in: c)
        let before = p.clips
        let voices: [String?] = ["S1", "S1", "S2", nil, "S2", "S1", "S1", "S1", "S2", "S2"]
        p.applyVoices(voices, names: ["S1": "Kathy", "S2": "Ori"])
        let speakers = p.words.map { p.paragraph($0.paragraph)!.speaker! }
        #expect(speakers == ["Kathy", "Kathy", "Ori", "Ori", "Ori", "Kathy", "Kathy", "Kathy", "Ori", "Ori"])
        #expect(p.paragraphs.count == 4)
        #expect(p.paragraphs.first?.id == ParagraphID(1))   // the first run keeps the paragraph
        #expect(p.speakers == ["A", "Kathy", "Ori"] || p.speakers == ["Kathy", "Ori"])
        #expect(p.clips == before)                          // markers stay on their words
    }
}

@Suite struct ExportNameTests {
    func project(clips n: Int) -> Project {
        var p = Project(source: "x.mp4")
        p.paragraphs = [Paragraph(id: ParagraphID(1))]
        p.words = (1...n).map { Word(id: WordID($0), text: "w\($0)", start: Double($0), end: Double($0) + 0.5, paragraph: ParagraphID(1)) }
        p.clips = (1...n).map { k in
            Clip(id: ClipID(k), name: k == 2 ? "Budget" : nil,
                 segments: [Segment(inPoint: Boundary(word: WordID(k)), outPoint: Boundary(word: WordID(k)))])
        }
        return p
    }

    @Test func numberedInVideoOrderWithTwoDigitsAtLeast() {
        let p = project(clips: 3)
        #expect(p.exportName(of: ClipID(1)) == "C01-clip-01")
        #expect(p.exportName(of: ClipID(2)) == "C02-budget")
        #expect(p.exportName(of: ClipID(99)) == nil)
    }

    @Test func paddedToTheWidthOfTheLastNumber() {
        let p = project(clips: 100)
        #expect(p.exportName(of: ClipID(2)) == "C002-budget")
        #expect(p.exportName(of: ClipID(100)) == "C100-clip-100")
    }
}


@Suite struct PostExportArgumentTests {
    @Test func splitsLikeAShell() {
        #expect(PostExport.splitArguments(#"{timeline} -o {output}"#) == ["{timeline}", "-o", "{output}"])
        #expect(PostExport.splitArguments(#"--title "Q & A" 'it''s' a\ b "" x"#) == ["--title", "Q & A", "its", "a b", "", "x"])
        #expect(PostExport.splitArguments("  ") == [])
    }

    @Test func joinReadsBack() {
        let args = ["{timeline}", "-o", "{output}", "--title", "Q & A", "say \"hi\"", "", #"back\slash"#]
        #expect(PostExport.splitArguments(PostExport.joinArguments(args)) == args)
        #expect(PostExport.joinArguments(PostExport.defaultArgs) == "{timeline} -o {output}")
    }

    @Test func nameAndOutput() {
        let pe = PostExport(run: "~/tools/brand-clip")
        #expect(pe.name == "brand-clip" && pe.writesOutput)
        #expect(!PostExport(run: "x", args: ["{video}"]).writesOutput)
    }
}
