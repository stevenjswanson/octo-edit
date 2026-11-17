import Testing
import Foundation
@testable import Core
@testable import SpeakerFraming
import MarkupGrammar

/// Two seated people, A on the left (x≈0.2) and B on the right (x≈0.7), sampled at
/// 10 fps for 20 s with a cut at 10 s to another camera (closer, from the other side)
/// where they appear swapped. A talks for the first 5 s of each shot, B for the rest;
/// whoever talks moves their mouth.
func panel() -> (FaceTracks, Project) {
    var frames: [FaceFrame] = []
    for k in 0..<200 {
        let t = Double(k) / 10
        let inShot = t.truncatingRemainder(dividingBy: 10)
        let swapped = t >= 10
        let aTalks = inShot < 5
        func face(_ x: Double, talking: Bool) -> FaceBox {
            FaceBox(x: x, y: swapped ? 0.2 : 0.3, w: 0.06, h: swapped ? 0.15 : 0.1,
                    mouthOpen: talking ? (k % 2 == 0 ? 0.3 : 0.05) : 0.1, mouthWidth: 0.5)
        }
        let a = face(swapped ? 0.67 : 0.17, talking: aTalks), b = face(swapped ? 0.17 : 0.67, talking: !aTalks)
        frames.append(FaceFrame(t: t, change: k == 100 ? 60 : 1, faces: [a, b]))
    }
    var p = Project(source: "v.mp4", paragraphs: [], words: [])
    var words: [Word] = []
    var paragraphs: [Paragraph] = []
    for (n, (start, speaker)) in [(0.0, "A"), (5.0, "B"), (10.0, "A"), (15.0, "B")].enumerated() {
        let pid = ParagraphID(n + 1)
        paragraphs.append(Paragraph(id: pid, speaker: speaker))
        for j in 0..<10 {
            let s = start + Double(j) * 0.5
            words.append(Word(id: WordID(words.count + 1), text: "w", start: s, end: s + 0.45, paragraph: pid))
        }
    }
    p.paragraphs = paragraphs
    p.words = words
    return (FaceTracks(width: 3840, height: 2160, frames: frames), p)
}

@Suite struct FaceLabelTests {
    @Test func mouthsThatMoveWithAParagraphsWordsTakeItsSpeaker() {
        let (faces, p) = panel()
        let labels = FaceLabels(faces: faces, project: p)
        #expect(labels.shotStarts == [0, 10])
        #expect(labels.tracks.count == 4)
        let a1 = labels.position(of: "A", inShotAt: 2)!, b1 = labels.position(of: "B", inShotAt: 2)!
        let a2 = labels.position(of: "A", inShotAt: 12)!
        #expect(abs(a1 - 0.2) < 0.01 && abs(b1 - 0.7) < 0.01 && abs(a2 - 0.7) < 0.01)
        #expect(labels.face(of: "B", at: 13)?.centerX ?? 0 < 0.3)
        #expect(Set(labels.portraits().keys) == ["A", "B"])
    }

    @Test func aShortReturnToTheSameFramingKeepsItsLabels() {
        // The wide shot (A left, B right), a 0.5 s cutaway, then the wide shot again for
        // 1 s with nobody's mouth moving: too little to label on its own.
        var frames: [FaceFrame] = []
        for k in 0..<120 {
            let t = Double(k) / 10
            let cutaway = t >= 10 && t < 10.5, quiet = t >= 10.5
            let aTalks = t < 5
            func face(_ x: Double, talking: Bool) -> FaceBox {
                FaceBox(x: x, y: 0.3, w: 0.06, h: 0.1, mouthOpen: talking && !quiet ? (k % 2 == 0 ? 0.3 : 0.05) : 0.1, mouthWidth: 0.5)
            }
            let faces = cutaway ? [FaceBox(x: 0.45, y: 0.1, w: 0.2, h: 0.35)] : [face(0.17, talking: aTalks), face(0.67, talking: !aTalks)]
            frames.append(FaceFrame(t: t, change: k == 100 || k == 105 ? 60 : 1, faces: faces))
        }
        let (_, p) = panel()
        let labels = FaceLabels(faces: FaceTracks(width: 3840, height: 2160, frames: frames), project: p)
        #expect(labels.shotStarts == [0, 10, 10.5])
        #expect(labels.face(of: "A", at: 11)?.centerX ?? 0 < 0.3)
        #expect(labels.face(of: "B", at: 11)?.centerX ?? 0 > 0.6)
    }

    @Test func aQuestionerFramedLikeTheSpeakerIsNotTheSpeaker() {
        // The speaker S alone at centre for 30 s, talking. Then a cut to a questioner Q
        // at the mic, framed the same way: Q asks for 5 s, then listens, mouth still,
        // while S answers off camera for 10 s.
        var frames: [FaceFrame] = []
        for k in 0..<450 {
            let t = Double(k) / 10
            let mouth = t < 35 ? (k % 2 == 0 ? 0.3 : 0.05) : 0.1
            frames.append(FaceFrame(t: t, change: k == 300 ? 60 : 1,
                                    faces: [FaceBox(x: 0.47, y: 0.25, w: 0.06, h: 0.1, mouthOpen: mouth, mouthWidth: 0.5)]))
        }
        let p = project([(0, 30, "S"), (30, 35, "Q"), (35, 45, "S")])
        let labels = FaceLabels(faces: FaceTracks(width: 3840, height: 2160, frames: frames), project: p)
        #expect(labels.face(of: "S", at: 10) != nil)
        #expect(labels.face(of: "S", at: 40) == nil)
        #expect(labels.face(of: "Q", at: 40) != nil)
    }

    @Test func aLoneFaceThatIsntTalkingWinsNoVotes() {
        // One face on screen, mouth still, while someone off camera talks.
        let frames = (0..<100).map { k in
            FaceFrame(t: Double(k) / 10, change: k == 0 ? 60 : 1,
                      faces: [FaceBox(x: 0.47, y: 0.25, w: 0.06, h: 0.1, mouthOpen: 0.1, mouthWidth: 0.5)])
        }
        let labels = FaceLabels(faces: FaceTracks(width: 3840, height: 2160, frames: frames), project: project([(0, 10, "S")]))
        #expect(labels.tracks.allSatisfy { $0.speaker == nil })
    }

    @Test func relabellingAHeaderMovesTheFace() {
        let (faces, p) = panel()
        var q = p
        q.renameSpeaker("A", to: "Kathy")
        #expect(FaceLabels(faces: faces, project: q).position(of: "Kathy", inShotAt: 2) != nil)
    }

    @Test func facesFileRoundTrips() {
        let (faces, _) = panel()
        let text = FacesFile.encode(faces)
        let back = FacesFile.decode(text)
        #expect(back?.frames.count == faces.frames.count)
        #expect(back?.width == 3840)
        #expect(abs((back?.frames[3].faces[1].x ?? 0) - faces.frames[3].faces[1].x) < 1e-4)
    }
}

/// A project whose words (0.5 s apart) are spoken in the given turns.
func project(_ turns: [(start: Double, end: Double, speaker: String)]) -> Project {
    var words: [Word] = [], paragraphs: [Paragraph] = []
    for (n, turn) in turns.enumerated() {
        let pid = ParagraphID(n + 1)
        paragraphs.append(Paragraph(id: pid, speaker: turn.speaker))
        var s = turn.start
        while s < turn.end - 0.01 {
            words.append(Word(id: WordID(words.count + 1), text: "w", start: s, end: min(s + 0.4, turn.end), paragraph: pid))
            s += 0.5
        }
    }
    return Project(source: "v.mp4", paragraphs: paragraphs, words: words)
}

@Suite struct ColumnPathTests {
    let aspect = 16.0 / 9.0

    @Test func fullHeightColumnCentredOnTheSpeakerThenCuts() {
        let (faces, p) = panel()
        let labels = FaceLabels(faces: faces, project: p)
        let path = ColumnPath(segments: [(0, 10)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        #expect(abs(path.width - 0.31640625) < 1e-9)   // 1215 of 3840 pixels
        #expect(abs(path.x(at: 2) - 0.2) < 0.01)
        #expect(abs(path.x(at: 4.99) - 0.2) < 0.01)
        #expect(abs(path.x(at: 5) - 0.7) < 0.01)       // B speaks: a cut, no pan
        #expect(path.keys.map(\.dips) == [false, true])  // the move to B dips; the clip's start doesn't
    }

    @Test func jumpsWithACutInTheSource() {
        let (faces, p) = panel()
        let path = ColumnPath(segments: [(8, 13)], timeline: SpeechTimeline(p), labels: FaceLabels(faces: faces, project: p),
                              aspect: aspect)
        #expect(path.keys.allSatisfy { !$0.dips })      // the source's cut is a hard cut
        #expect(abs(path.x(at: 9) - 0.7) < 0.01)       // B, right
        #expect(abs(path.x(at: 10.05) - 0.7) < 0.01)   // A now sits on the right: the column stays
        #expect(abs(path.x(at: 12) - 0.7) < 0.01)
    }

    @Test func aBriefInterjectionDoesNotSwingTheColumn() {
        let (faces, base) = panel()
        // B says a word over A, who carries straight on.
        let p = project([(0, 2, "A"), (2, 2.2, "B"), (2.25, 5, "A"), (5, 10, "B")])
        let labels = FaceLabels(faces: faces, project: base)
        let path = ColumnPath(segments: [(0, 10)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        for t in stride(from: 0.0, through: 4.9, by: 0.1) { #expect(abs(path.x(at: t) - 0.2) < 0.01) }
        #expect(abs(path.x(at: 7) - 0.7) < 0.01)
    }

    @Test func aQuickAnswerGetsItsShot() {
        // A lightning round: B answers "Yes." and A goes on.
        let (faces, base) = panel()
        let p = project([(0, 2, "A"), (2, 2.4, "B"), (2.6, 5, "A"), (5, 10, "B")])
        let labels = FaceLabels(faces: faces, project: base)
        let path = ColumnPath(segments: [(0, 10)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        #expect(abs(path.x(at: 1.9) - 0.2) < 0.01)
        #expect(abs(path.x(at: 2.1) - 0.7) < 0.01)
        #expect(abs(path.x(at: 3) - 0.2) < 0.01)
    }

    @Test func aSegmentStartingOnAShortAnswerOpensOnIt() {
        // An omission ends right where B's one-word answer begins; A follows.
        let (faces, base) = panel()
        let p = project([(0, 2, "A"), (2, 3, "B"), (3, 5, "A"), (5, 10, "B")])
        let labels = FaceLabels(faces: faces, project: base)
        let path = ColumnPath(segments: [(2, 5)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        #expect(abs(path.x(at: 2) - 0.7) < 0.01)
        #expect(abs(path.x(at: 3.5) - 0.2) < 0.01)
    }

    @Test func aStartNudgedIntoThePreviousSpeakerOpensOnTheClipsSpeaker() {
        // B's clip starts at 5; its start is moved 0.3 s back into A's last word.
        let (faces, p) = panel()
        let labels = FaceLabels(faces: faces, project: p)
        let path = ColumnPath(segments: [(4.7, 10)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        #expect(abs(path.x(at: 4.7) - 0.7) < 0.01)     // B from the first frame
        #expect(path.keys.count == 1)
    }

    @Test func clampedInsideTheFrameAndCentredWithoutFaces() {
        let frames = (0..<50).map { k in
            FaceFrame(t: Double(k) / 10, change: 1, faces: [FaceBox(x: 0.0, y: 0.3, w: 0.06, h: 0.1,
                                                                   mouthOpen: k % 2 == 0 ? 0.3 : 0.05, mouthWidth: 0.5)])
        }
        let p = project([(0, 5, "A")])
        let labels = FaceLabels(faces: FaceTracks(width: 1920, height: 1080, frames: frames), project: p)
        let edge = ColumnPath(segments: [(0, 5)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        #expect(abs(edge.x(at: 1) - edge.width / 2) < 1e-9)
        let blind = ColumnPath(segments: [(0, 5)], timeline: SpeechTimeline(p), labels: nil, aspect: aspect)
        #expect(blind.x(at: 1) == 0.5)
        let narrow = ColumnPath(segments: [(0, 5)], timeline: SpeechTimeline(p), labels: labels, aspect: 9.0 / 16.0)
        #expect(narrow.width == 1)
    }
}

/// Scores from a table (by time in ms), standing in for Vision.
struct TableScorer: StillScorer {
    let totals: [Int: (q: Double, eyes: Double)]
    /// Frames not listed: eyes shut, unless given.
    var others: (q: Double, eyes: Double) = (0.6, 0)
    func score(video: URL, _ requests: [(t: Seconds, near: FaceBox?)]) async throws -> [StillScore] {
        requests.map { r in
            let v = totals[Int((r.t * 1000).rounded())] ?? others
            return StillScore(t: r.t, quality: v.q, eyes: v.eyes, lips: 0, face: r.near)
        }
    }
}

@Suite struct StillPickerTests {
    @Test func openingSpansFollowTheKeptVideo() {
        let segs = [ResolvedSegment(start: 100, end: 104), ResolvedSegment(start: 110, end: 120)]
        #expect(StillPicker.openingSpans(segs, seconds: 10) == [100...104, 110...116])
        #expect(StillPicker.trim(StillPicker.openingSpans(segs, seconds: .infinity), skipping: 10) == [116...120])
    }

    @Test func theMainSpeakerIsTheFirstToSpeak() throws {
        var (_, p) = panel()
        let id = try p.makeClip(words: 5...29)   // A's last 5 words, all of B's, 10 of A's
        #expect(StillPicker.mainSpeaker(of: p.clip(id)!, in: p) == "A")
        var (_, q) = panel()
        let b = try q.makeClip(words: 8...29)    // A's last 2 words, then B says the most
        #expect(StillPicker.mainSpeaker(of: q.clip(b)!, in: q) == "A")
        #expect(StillPicker.speakingOrder(of: q.clip(b)!, in: q) == ["A", "B"])
    }

    @Test func candidatesAreTheSpeakersStillFrames() throws {
        var (faces, p) = panel()
        let id = try p.makeClip(words: 10...19)   // B, 5–10 s
        let labels = FaceLabels(faces: faces, project: p)
        let cs = StillPicker.candidates(.opening, for: p.clip(id)!, in: p, faces: faces, labels: labels)
        #expect(!cs.isEmpty)
        // B's face (x≈0.7), mouth not mid-word, inside the clip, 0.4 s apart.
        for c in cs {
            #expect(abs(c.face.centerX - 0.7) < 0.05)
            #expect(c.t >= 4.8 && c.t <= 10.2)
        }
        for (a, b) in zip(cs, cs.dropFirst()) { #expect(abs(a.t - b.t) >= 0.4 - 1e-9) }
        // Nothing near the cut at 10 s.
        faces.frames[60].change = 60
        let cut = StillPicker.candidates(.opening, for: p.clip(id)!, in: p, faces: faces, labels: labels)
        #expect(cut.allSatisfy { abs($0.t - 6) > 0.25 })
    }

    @Test func automaticPrefersAGoodOpeningElseTheBestThereIs() async throws {
        var (faces, p) = panel()
        let id = try p.makeClip(words: 10...19)   // B, 5–10 s
        let labels = FaceLabels(faces: faces, project: p)
        let opening = StillPicker.candidates(.opening, for: p.clip(id)!, in: p, faces: faces, labels: labels)
        let pick = opening[min(3, opening.count - 1)]
        // A good frame in the opening wins, even if it isn't the coarse favourite.
        var stills = TitleStills(video: URL(fileURLWithPath: "/v.mp4"), faces: faces, project: p,
                                 scorer: TableScorer(totals: [Int((pick.t * 1000).rounded()): (0.7, 1)]))
        var choice = try await stills.choice(for: p.clip(id)!, in: p)
        #expect(choice?.automatic == true && choice?.t == pick.t)
        #expect(await stills.unsaved)
        // A chosen still wins outright, wherever it is.
        var q = p
        try q.setStill(clip: id, 1.234)
        choice = try await stills.choice(for: q.clip(id)!, in: q)
        #expect(choice?.automatic == false && choice?.t == 1.234)
        // Nothing good anywhere: still the best there is, not nothing.
        stills = TitleStills(video: URL(fileURLWithPath: "/v.mp4"), faces: faces, project: p, scorer: TableScorer(totals: [:]))
        #expect(try await stills.choice(for: p.clip(id)!, in: p) != nil)
        _ = faces
    }

    @Test func clipsWithNoGoodFrameStillGetTheirOwnPicture() async throws {
        var (faces, p) = panel()
        let early = try p.makeClip(words: 10...19)   // B, 5–10 s
        let late = try p.makeClip(words: 30...39)    // B, 15–20 s
        // Every frame mediocre (0.6 × 0.3 < goodEnough): nothing passes anywhere.
        let stills = TitleStills(video: URL(fileURLWithPath: "/v.mp4"), faces: faces, project: p,
                                 scorer: TableScorer(totals: [:], others: (0.6, 0.3)))
        let a = try await stills.choice(for: p.clip(early)!, in: p)!, b = try await stills.choice(for: p.clip(late)!, in: p)!
        #expect(a.t != b.t)
        #expect((5...10).contains(a.t) && (15...20).contains(b.t))
        _ = faces
    }

    @Test func everyLabelledSpeakerGetsCandidatesMainSpeakerFirst() async throws {
        var (faces, p) = panel()
        let id = try p.makeClip(words: 10...19)   // B, 5–10 s
        let labels = FaceLabels(faces: faces, project: p)
        #expect(StillPicker.speakers(for: p.clip(id)!, in: p, labels: labels) == ["B", "A"])
        // A's own frames, anywhere: A's face in each, in the clip first.
        let a = StillPicker.candidates(of: "A", for: p.clip(id)!, in: p, faces: faces, labels: labels)
        #expect(!a.isEmpty && a.allSatisfy { $0.speaker == "A" })
        for c in a { #expect(abs(c.face.centerX - (labels.face(of: "A", at: c.t)?.centerX ?? -1)) < 0.05) }
        #expect(a.first?.origin == .clip)
        // Scored for A's face, so choosing one frames A.
        let stills = TitleStills(video: URL(fileURLWithPath: "/v.mp4"), faces: faces, project: p, scorer: TableScorer(totals: [:]))
        let scored = try await stills.candidates(of: "A", for: p.clip(id)!, in: p)
        var q = p
        try q.setStill(clip: id, scored[0].candidate.t)
        let pick = try await stills.choice(for: q.clip(id)!, in: q)
        #expect(abs((pick?.face?.centerX ?? -1) - scored[0].candidate.face.centerX) < 1e-9)
        _ = faces
    }

    @Test func theTalkFallbackTakesAGoodFrameNearTheClip() {
        func c(_ t: Double) -> StillPicker.Candidate {
            .init(t: t, face: FaceBox(x: 0.4, y: 0.2, w: 0.1, h: 0.1), coarse: 0.5, origin: .talk)
        }
        let cs = [c(100), c(500), c(900)]
        let totals: [Double: Double] = [100: 0.6, 500: 0.45, 900: 0.3]
        func score(_ t: Double) -> StillScore? { StillScore(t: t, quality: totals[t]!, eyes: 1, lips: 0, face: cs[0].face) }
        #expect(StillPicker.pick(cs, score: score)?.t == 100)
        // Near 520: 500 is within 70% of the best (0.45 ≥ 0.42); 900 isn't.
        #expect(StillPicker.pick(cs, score: score, near: 520)?.t == 500)
        #expect(StillPicker.pick(cs, score: score, near: 880)?.t == 500)
        // Nothing good enough: nil, so the caller looks further.
        #expect(StillPicker.pick(cs, score: score, threshold: 0.7) == nil)
    }

    @Test func stillsFileRoundTrips() {
        let s = [StillScore(t: 3481.233, quality: 0.612, eyes: 0.88, lips: 0.0142, face: FaceBox(x: 0.4, y: 0.2, w: 0.03, h: 0.05)),
                 StillScore(t: 12, quality: 0, eyes: 0, lips: nil, face: nil)]
        let back = StillsFile.decode(StillsFile.encode(s))!
        #expect(back.count == 2 && back[0].t == 12 && back[1].face?.x == 0.4 && back[1].quality == 0.612)
        #expect(StillsFile.decode("garbage") == nil)
        #expect(abs((back[1].lips ?? 0) - 0.0142) < 1e-6 && back[0].lips == nil)
    }

    @Test func versionOneStillsFilesKeepTheirLipGap() {
        // Version 1 held exp(-max(lips - 0.004, 0) / 0.006): 0.390 is a gap of 0.0096.
        let v1 = "# octoedit stills 1\n1.000\t0.5\t1\t0.390\t0.4\t0.2\t0.03\t0.05\n2.000\t0.5\t1\t0.000\t0.4\t0.2\t0.03\t0.05\n3.000\t0.5\t1\t1.000\t0.4\t0.2\t0.03\t0.05\n"
        let s = StillsFile.decode(v1)!
        #expect(abs(s[0].lips! - 0.0096) < 0.0002)
        #expect(s[1].lips! > 0.045 && s[1].mouth < 0.02)
        #expect(s[2].lips == 0.004 && s[2].mouth > 0.99)
    }

    @Test func closedLipsScoreClosedOnEveryFace() {
        // Closed, measured on three speakers: 0.003–0.025; open mid-word: 0.04 and up.
        #expect(StillScore.closedness(0.009) > 0.98)
        #expect(StillScore.closedness(0.022) > 0.7)
        #expect(StillScore.closedness(0.045) < 0.02)
    }
}
