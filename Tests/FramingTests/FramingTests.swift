import Testing
import Foundation
@testable import Core
@testable import SpeakerFraming
import MarkupGrammar

/// Two seated people, A on the left (x≈0.2) and B on the right (x≈0.7), sampled at
/// 10 fps for 20 s with a cut at 10 s after which they swap seats. A talks for the
/// first 5 s of each shot, B for the rest; whoever talks moves their mouth.
func panel() -> (FaceTracks, Project) {
    var frames: [FaceFrame] = []
    for k in 0..<200 {
        let t = Double(k) / 10
        let inShot = t.truncatingRemainder(dividingBy: 10)
        let swapped = t >= 10
        let aTalks = inShot < 5
        func face(_ x: Double, talking: Bool) -> FaceBox {
            FaceBox(x: x, y: 0.3, w: 0.06, h: 0.1, mouthOpen: talking ? (k % 2 == 0 ? 0.3 : 0.05) : 0.1, mouthWidth: 0.5)
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

    @Test func fullHeightColumnCentredOnTheSpeakerThenPans() {
        let (faces, p) = panel()
        let labels = FaceLabels(faces: faces, project: p)
        let path = ColumnPath(segments: [(0, 10)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        #expect(abs(path.width - 0.31640625) < 1e-9)   // 1215 of 3840 pixels
        #expect(abs(path.x(at: 2) - 0.2) < 0.01)
        let mid = path.x(at: 5.3)
        #expect(mid > 0.25 && mid < 0.65)              // panning
        #expect(abs(path.x(at: 6) - 0.7) < 0.01)
    }

    @Test func jumpsWithACutInTheSource() {
        let (faces, p) = panel()
        let path = ColumnPath(segments: [(8, 13)], timeline: SpeechTimeline(p), labels: FaceLabels(faces: faces, project: p),
                              aspect: aspect)
        #expect(abs(path.x(at: 9) - 0.7) < 0.01)       // B, right
        #expect(path.keys.contains { $0.t == 10 && $0.jump })
        #expect(abs(path.x(at: 10.05) - 0.7) < 0.01)   // A now sits on the right: no pan needed
        #expect(abs(path.x(at: 12) - 0.7) < 0.01)
    }

    @Test func aBriefInterjectionDoesNotSwingTheColumn() {
        let (faces, base) = panel()
        let p = project([(0, 2, "A"), (2, 2.4, "B"), (2.5, 5, "A"), (5, 10, "B")])
        let labels = FaceLabels(faces: faces, project: base)
        let path = ColumnPath(segments: [(0, 10)], timeline: SpeechTimeline(p), labels: labels, aspect: aspect)
        for t in stride(from: 0.0, through: 4.9, by: 0.1) { #expect(abs(path.x(at: t) - 0.2) < 0.01) }
        #expect(abs(path.x(at: 7) - 0.7) < 0.01)
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
