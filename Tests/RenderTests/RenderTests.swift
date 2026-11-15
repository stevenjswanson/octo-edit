import Testing
import Foundation
import AVFoundation
@testable import Core
@testable import Render

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/generated")
func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
let haveSine = FileManager.default.fileExists(atPath: fixture("sine-1080.mp4").path)
let haveTone = FileManager.default.fileExists(atPath: fixture("tone-4k.mp4").path)

/// Words "w0"… one per second, spoken i…i+0.8.
func secondsProject(source: String) -> Project {
    let p = ParagraphID(1)
    let words = (0..<10).map { Word(id: WordID($0 + 1), text: "w\($0)", start: Double($0), end: Double($0) + 0.8, paragraph: p) }
    return Project(source: source, paragraphs: [Paragraph(id: p, speaker: "A")], words: words)
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("octo-render-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Mono float samples of a file's audio at 48 kHz.
func samples(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .audio)[0]
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000,
    ])
    reader.add(out)
    reader.startReading()
    var all: [Float] = []
    while let b = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(b) {
        let n = CMBlockBufferGetDataLength(block) / 4
        var chunk = [Float](repeating: 0, count: n)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
        all += chunk
    }
    return all
}

@Suite struct PresetTests {
    func info(_ w: Int, _ h: Int, _ c: Codec = .hevc) -> SourceInfo {
        SourceInfo(duration: 10, frameRate: 29.97, width: w, height: h, codec: c, hasAudio: true)
    }

    @Test func autoLevelsAverageEachFramesSuggestions() {
        typealias F = AutoLevels.Filter
        let curve = { (y: Double) in F(name: "CIToneCurve", numbers: [:], vectors: ["inputPoint3": [0.4, y]]) }
        let shadow = F(name: "CIHighlightShadowAdjust", numbers: ["inputShadowAmount": 0.3], vectors: [:])
        let l = AutoLevels(frames: [[curve(0.5)], [curve(0.6), shadow], [curve(0.7)]])
        // The curve, averaged; the shadow lift, suggested once in three, left out.
        #expect(l.filters.map(\.name) == ["CIToneCurve"])
        #expect(abs(l.filters[0].vectors["inputPoint3"]![1] - 0.6) < 1e-9)
    }

    @Test func exactSizesUseSizedPresetsOthersKeepSourceSize() {
        #expect(ClipExporter.preset(for: info(3840, 2160), quality: .full(.hevc)) == AVAssetExportPresetHEVC3840x2160)
        #expect(ClipExporter.preset(for: info(1920, 1080), quality: .full(.h264)) == AVAssetExportPreset1920x1080)
        #expect(ClipExporter.preset(for: info(2560, 1440), quality: .full(.hevc)) == AVAssetExportPresetHEVCHighestQuality)
        #expect(ClipExporter.preset(for: info(1080, 1920), quality: .full(.h264)) == AVAssetExportPresetHighestQuality)
        #expect(ClipExporter.preset(for: info(3840, 2160), quality: .preview) == AVAssetExportPreset1280x720)
    }
}

@Suite struct CaptionTests {
    @Test func onlyKeptWordsRetimedToClip() throws {
        var p = secondsProject(source: "x.mp4")
        let c = try p.makeClip(words: 1...6)
        try p.omit(words: 3...4, in: c)
        let ranges = p.resolvedSegments(of: p.clip(c)!)        // [0.88, 2.8], [5.0, 6.98]
        let starts = [0.0, ranges[0].duration]
        let vtt = Captions.webVTT(for: p.clip(c)!, in: p, sourceRanges: ranges, clipStarts: starts)
        #expect(!vtt.contains("w3") && !vtt.contains("w4"))
        #expect(vtt.contains("<v A>w1 w2 w5 w6"))
        #expect(vtt.contains("00:00:00.120 --> "))             // w1 starts 0.12 s into the clip (pre-pad)
        #expect(vtt.contains(" --> 00:00:03.720"))             // w6 ends at 1.92 + (6.8 - 5.0)
    }
}

@Suite struct TimelineTests {
    /// w0–w4 by A, w5–w9 by B; the clip keeps w1–w7 with w3–w4 cut out, so the
    /// speaker changes right at the cut.
    func twoSpeakers() throws -> (Project, Clip) {
        var p = secondsProject(source: "x.mp4")
        p.paragraphs.append(Paragraph(id: ParagraphID(2), speaker: "B"))
        p.speakers = ["A", "B"]
        for i in 5..<10 { p.words[i].paragraph = ParagraphID(2) }
        let c = try p.makeClip(words: 1...7, name: "Talk")
        try p.omit(words: 3...4, in: c)
        return (p, p.clip(c)!)
    }

    @Test func turnsAndCutsOnTheClipsClock() throws {
        let (p, clip) = try twoSpeakers()
        let ranges = p.resolvedSegments(of: clip)
        let starts = [0.0, ranges[0].duration]
        let t = Timeline.clip(clip, in: p, sourceRanges: ranges, clipStarts: starts)
        #expect(t.speakers == ["A", "B"])
        #expect(t.clips.map(\.title) == ["Talk"])
        #expect(t.segments.count == 2)
        #expect(t.segments[1].start == t.segments[0].end)                 // the cut
        #expect(t.segments[0].sourceStart == ranges[0].start)
        // A before the cut, B from the first word after it.
        #expect(t.turns.map(\.speaker) == ["A", "B"])
        #expect(t.turns[0].text == "w1 w2")
        #expect(t.turns[1].text == "w5 w6 w7")
        #expect(t.words.map(\.segment) == [0, 0, 1, 1, 1])
        let w5 = t.words.first { $0.text == "w5" }!
        #expect(abs(w5.start - (starts[1] + 5 - ranges[1].start)) < 0.001)
        #expect(t.turns[1].start == w5.start)
        #expect(abs(t.duration - ranges.reduce(0) { $0 + $1.duration }) < 0.001)
    }

    @Test func concatenateShiftsTimesAndSegmentIndices() throws {
        let (p, clip) = try twoSpeakers()
        let ranges = p.resolvedSegments(of: clip)
        let one = Timeline.clip(clip, in: p, sourceRanges: ranges, clipStarts: [0, ranges[0].duration])
        let joined = Timeline.concatenate([(one, 0), (one, 10)], duration: 10 + one.duration)!
        #expect(joined.segments.count == 4 && joined.clips.count == 2)
        #expect(joined.clips[1].start == 10)
        #expect(joined.words.last!.segment == 3)
        #expect(joined.turns.count == 4)
        #expect(joined.speakers == ["A", "B"])
    }

    @Test func jsonParsesAndHasOneWordPerLine() throws {
        let (p, clip) = try twoSpeakers()
        let ranges = p.resolvedSegments(of: clip)
        let t = Timeline.clip(clip, in: p, sourceRanges: ranges, clipStarts: [0, ranges[0].duration])
        let json = try t.json()
        #expect(try JSONDecoder().decode(Timeline.self, from: Data(json.utf8)) == t)
        #expect(json.split(separator: "\n").filter { $0.contains("\"text\": \"w") && $0.contains("\"segment\"") }.count == 5)
        #expect(!json.contains("titlecard"))
        var withCard = t
        withCard.titlecard = Timeline.TitleCard(time: 3481.233, auto: false, image: "C01-x-4k-9x16.still.jpg")
        let cardJSON = try withCard.json()
        #expect(cardJSON.contains("\"titlecard\": {\"time\": 3481.233, \"auto\": false, \"image\": \"C01-x-4k-9x16.still.jpg\"}"))
        #expect(try JSONDecoder().decode(Timeline.self, from: Data(cardJSON.utf8)) == withCard)
    }
}

@Suite(.serialized) struct RenderIntegrationTests {
    @Test(.enabled(if: haveSine)) func crossfadedJoinsHaveNoClicksAndExactFrames() async throws {
        let src = fixture("sine-1080.mp4")
        var p = secondsProject(source: src.path)
        let c = try p.makeClip(words: 1...8)
        try p.omit(words: 3...4, in: c)
        try p.omit(words: 6...6, in: c)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        let out = try await r.render(p.clip(c)!, into: dir, options: .init())
        #expect(out.file.lastPathComponent == "C01-clip-01-1080p.mp4")
        #expect(out.file.deletingLastPathComponent().lastPathComponent == "C01-clip-01")     // the clip's own folder
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("C01-clip-01/C01-clip-01-1080p.vtt").path))
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: dir.appendingPathComponent("C01-clip-01/C01-clip-01-1080p.timeline.json")))
        #expect(timeline.segments.count == 3)

        let asset = AVURLAsset(url: out.file)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let (size, fps) = try await (video.load(.naturalSize), video.load(.nominalFrameRate))
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(abs(Double(fps) - 29.97) < 0.01)
        // Really re-encoded: every decoded frame is shown (no GOP pass-through hidden by
        // edit lists), so the decoded frame count matches the duration exactly.
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - out.duration) < 0.05)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(frames)
        reader.startReading()
        var count = 0
        while let b = frames.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(b) > 0 { count += 1 } }
        #expect(abs(count - Int((out.duration * 30000 / 1001).rounded())) <= 1, "\(count) frames for \(out.duration) s")

        // Joins: sample-to-sample jumps stay near the steady-state sine slope.
        let x = try await samples(out.file)
        let d = zip(x, x.dropFirst()).map { abs($1 - $0) }
        let steady = d[24_000..<36_000].max()!
        let built = try await CompositionBuilder.build(asset: AVURLAsset(url: src), segments: p.resolvedSegments(of: p.clip(c)!), crossfade: 0.02)
        for join in built.segmentStarts.dropFirst() {
            let j = Int(join * 48_000)
            let worst = d[(j - 960)..<(j + 960)].max()!
            #expect(worst < steady * 3, "click at \(join): \(worst) vs steady \(steady)")
        }
    }

    /// An export leaves a stamp; editing the clip or swapping the video makes it stale,
    /// and renaming it leaves nothing exported under the new name.
    @Test(.enabled(if: haveSine)) func exportStampTracksChanges() async throws {
        let src = fixture("sine-1080.mp4")
        var p = secondsProject(source: src.path)
        let c = try p.makeClip(words: 1...4)
        let other = try p.makeClip(words: 6...7)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        _ = try await r.render(p.clip(c)!, into: dir, options: .init(resolution: .hd720))
        let id = ExportStamp.sourceIdentity(src)
        let plain = ExportStamp.Output(framing: .source, codec: nil, postExport: nil, faces: nil)
        func state(_ q: Project, _ out: ExportStamp.Output = plain, source: String? = nil) -> ExportStamp.State? {
            ExportStamp.states(q, exports: dir, sourceIdentity: source ?? id, output: out)[c]
        }
        #expect(ExportStamp.states(p, exports: dir, sourceIdentity: id, output: plain) == [c: .current, other: .notExported])
        #expect(state(p, source: "another.mp4 1") == .changed)

        var edited = p
        try edited.omit(words: 2...2, in: c)
        #expect(state(edited) == .changed)
        var noted = p
        noted.clips[0].notes = "new notes"
        #expect(state(noted) == .changed)
        var renamed = p
        renamed.clips[0].name = "Renamed"
        #expect(state(renamed) == .notExported)
        // Output settings count too.
        #expect(state(p, .init(framing: .portrait, codec: nil, postExport: nil, faces: nil)) == .changed)
        #expect(state(p, .init(framing: .source, codec: .h264, postExport: nil, faces: nil)) == .changed)
        #expect(state(p, .init(framing: .source, codec: nil, postExport: PostExport(run: "brand-clip"), faces: nil)) == .changed)
    }

    /// Every kind of change gives a different stamp; faces count only in 9:16, and only
    /// near the clip.
    @Test func stampCoversEveryChange() throws {
        var p = secondsProject(source: "/v.mp4")
        let c = try p.makeClip(words: 2...4)
        func faces(at t: Double, x: Double) -> FaceTracks {
            FaceTracks(width: 1920, height: 1080, frames: [FaceFrame(t: t, change: 0, faces: [FaceBox(x: x, y: 0.3, w: 0.1, h: 0.2)])])
        }
        let base = ExportStamp.Output(framing: .portrait, codec: nil, postExport: PostExport(run: "~/b"), faces: faces(at: 3, x: 0.4))
        func stamp(_ q: Project, _ o: ExportStamp.Output = base) -> String? {
            ExportStamp.fingerprint(of: q.clip(c)!, in: q, sourceIdentity: "v.mp4 1", output: o)
        }
        let s0 = stamp(p)
        var variants: [String?] = []
        var o = base; o.framing = .source; variants.append(stamp(p, o))
        o = base; o.codec = .hevc; variants.append(stamp(p, o))
        o = base; o.postExport = nil; variants.append(stamp(p, o))
        o = base; o.postExport = PostExport(run: "~/b", args: ["{timeline}", "-o", "{output}", "--logo", "lockup"]); variants.append(stamp(p, o))
        o = base; o.faces = faces(at: 3, x: 0.5); variants.append(stamp(p, o))
        o = base; o.faces = nil; variants.append(stamp(p, o))
        var q = p; q.settings.crossfade = 0.05; variants.append(stamp(q))
        q = p; q.settings.speakerFade = 0.5; variants.append(stamp(q))
        q = p; q.settings.prePad = 0.3; variants.append(stamp(q))
        q = p; q.clips[0].autoLevels.toggle(); variants.append(stamp(q))
        q = p; q.paragraphs[0].speaker = "B"; variants.append(stamp(q))
        q = p; q.words[2].text = "changed"; variants.append(stamp(q))
        q = p; q.clips[0].still = 12.5; variants.append(stamp(q))
        q = p; q.clips[0].still = 12.6; variants.append(stamp(q))
        for v in variants { #expect(v != nil && v != s0) }
        #expect(Set(variants.compactMap { $0 }).count == variants.count)
        // Faces far from the clip, or in source framing, don't matter.
        o = base; o.faces = FaceTracks(width: 1920, height: 1080, frames: base.faces!.frames + faces(at: 9, x: 0.9).frames)
        #expect(stamp(p, o) == s0)
        var src = base; src.framing = .source
        var srcOther = src; srcOther.faces = faces(at: 3, x: 0.7)
        #expect(stamp(p, src) == stamp(p, srcOther))
    }

    /// Two clips joined: duration is the sum, captions keep both clips' words and no
    /// cue straddles the join; the slug avoids clip slugs.
    @Test(.enabled(if: haveSine)) func supercutJoinsClipsInOrder() async throws {
        let src = fixture("sine-1080.mp4")
        var p = secondsProject(source: src.path)
        let a = try p.makeClip(words: 1...2, name: "First")
        let b = try p.makeClip(words: 5...6, name: "Supercut")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        let slug = r.supercutSlug(base: "")
        #expect(slug == "supercut-all")
        #expect(r.supercutSlug(base: "My Talk") == "my-talk-supercut")
        let out = try await r.renderSupercut([p.clip(a)!, p.clip(b)!], slug: slug, into: dir, options: .init())
        let expected = p.duration(of: p.clip(a)!) + p.duration(of: p.clip(b)!)
        #expect(abs(out.duration - expected) < 0.1, "\(out.duration) vs \(expected)")
        let fileDuration = try await AVURLAsset(url: out.file).load(.duration).seconds
        #expect(abs(fileDuration - out.duration) < 0.1)
        let vtt = try String(contentsOf: dir.appendingPathComponent("supercut-all/supercut-all-1080p.vtt"), encoding: .utf8)
        #expect(vtt.contains("w1 w2"))
        #expect(vtt.contains("w5 w6"))
        #expect(!vtt.contains("w2 w5"))
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: dir.appendingPathComponent("supercut-all/supercut-all-1080p.timeline.json")))
        #expect(timeline.clips.map(\.title) == ["First", "Supercut"])
        #expect(timeline.turns.map(\.text) == ["w1 w2", "w5 w6"])          // a new turn at the clip join
        #expect(abs(timeline.duration - out.duration) < 0.05)
    }

    @Test(.enabled(if: haveTone)) func previewIs720pH264() async throws {
        let src = fixture("tone-4k.mp4")
        var p = secondsProject(source: src.path)
        let c = try p.makeClip(words: 2...4, name: "Tone test")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        #expect(r.info.width == 3840 && r.info.codec == .hevc)
        let out = try await r.render(p.clip(c)!, into: dir, options: .init(preview: true))
        #expect(out.file.lastPathComponent == "C01-tone-test.preview.mp4")
        #expect(out.file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)   // previews stay flat
        let v = try await AVURLAsset(url: out.file).loadTracks(withMediaType: .video)[0]
        let (size, formats) = try await (v.load(.naturalSize), v.load(.formatDescriptions))
        #expect(size == CGSize(width: 1280, height: 720))
        #expect(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("C01-tone-test.preview.vtt").path))
    }

    /// 720p output: 1280×720 H.264, named -720p (captions too); full size is named 4k.
    @Test(.enabled(if: haveTone)) func hd720IsLabelledAndScaled() async throws {
        let src = fixture("tone-4k.mp4")
        var p = secondsProject(source: src.path)
        let c = try p.makeClip(words: 2...3, name: "Tone test")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        #expect(r.resolutionLabel(.full) == "4k")
        let out = try await r.render(p.clip(c)!, into: dir, options: .init(resolution: .hd720))
        #expect(out.file.lastPathComponent == "C01-tone-test-720p.mp4")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("C01-tone-test/C01-tone-test-720p.vtt").path))
        let v = try await AVURLAsset(url: out.file).loadTracks(withMediaType: .video)[0]
        let (size, formats) = try await (v.load(.naturalSize), v.load(.formatDescriptions))
        #expect(size == CGSize(width: 1280, height: 720))
        #expect(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264)
    }

    /// 9:16 framing: a full-height 1215×2160 column from 4K, named -4k-9x16; 720×1280 at 720p.
    @Test(.enabled(if: haveTone)) func portraitFramingCropsAFullHeightColumn() async throws {
        let src = fixture("tone-4k.mp4")
        var p = secondsProject(source: src.path)
        p.settings.framing = .portrait
        let c = try p.makeClip(words: 2...3, name: "Tone test")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        for (options, name, size) in [(Renderer.Options(), "C01-tone-test-4k-9x16.mp4", CGSize(width: 1216, height: 2160)),
                                      (Renderer.Options(resolution: .hd720), "C01-tone-test-720p-9x16.mp4", CGSize(width: 720, height: 1280))] {
            let out = try await r.render(p.clip(c)!, into: dir, options: options)
            #expect(out.file.lastPathComponent == name)
            let v = try await AVURLAsset(url: out.file).loadTracks(withMediaType: .video)[0]
            #expect(try await v.load(.naturalSize) == size)
        }
        let plain = try await r.render(p.clip(c)!, into: dir, options: .init(resolution: .hd720, framing: .source))
        #expect(plain.file.lastPathComponent == "C01-tone-test-720p.mp4")
    }

    @Test(.enabled(if: haveTone)) func cancellingLeavesNoFiles() async throws {
        let src = fixture("tone-4k.mp4")
        var p = secondsProject(source: src.path)
        let c = try p.makeClip(words: 0...9, name: "Long")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        let clip = p.clip(c)!
        let task = Task { try await r.render(clip, into: dir, options: .init()) }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty, "left behind: \(left)")
    }

    @Test func clipNotesHaveTitleAndNotes() throws {
        var p = secondsProject(source: "x.mp4")
        let a = try p.makeClip(words: 0...1, name: "First")
        let b = try p.makeClip(words: 3...4)
        try p.setNotes(clip: a, "Keep this one.\nIt matters.")
        #expect(ExportNotes.clip(p.clip(a)!, in: p) == "# First\n\nKeep this one.\nIt matters.\n")
        #expect(ExportNotes.clip(p.clip(b)!, in: p) == "# clip-02\n")
    }

    @Test func youTubeChapters() {
        #expect(ExportNotes.chapters(["Intro", "Budget", "Hiring"], starts: [0.4, 65.9, 600]) == "0:00 Intro\n1:05 Budget\n10:00 Hiring")
        #expect(ExportNotes.chapters(["A", "B"], starts: [0, 3725]) == "0:00:00 A\n1:02:05 B")
    }

    /// The fast supercut: the exported clip files joined without re-encoding.
    @Test(.enabled(if: haveSine)) func joinedSupercutHasChaptersAndShiftedCaptions() async throws {
        let src = fixture("sine-1080.mp4")
        var p = secondsProject(source: src.path)
        let a = try p.makeClip(words: 1...2, name: "First")
        let b = try p.makeClip(words: 5...6, name: "Second")
        try p.setNotes(clip: b, "About the second.")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await Renderer(project: p, source: src)
        let ra = try await r.render(p.clip(a)!, into: dir, options: .init())
        let rb = try await r.render(p.clip(b)!, into: dir, options: .init())
        let cut = try await r.joinSupercut([ra, rb], slug: "talk-supercut", into: dir, options: .init())
        #expect(cut.file.lastPathComponent == "talk-supercut-1080p.mp4")
        #expect(cut.file.deletingLastPathComponent() == dir.appendingPathComponent("talk-supercut", isDirectory: true))
        #expect(abs(cut.duration - (ra.duration + rb.duration)) < 0.1, "\(cut.duration) vs \(ra.duration + rb.duration)")
        let vtt = try String(contentsOf: dir.appendingPathComponent("talk-supercut/talk-supercut-1080p.vtt"), encoding: .utf8)
        #expect(vtt.contains("w1 w2") && vtt.contains("w5 w6"))
        // The second clip's caption starts where that clip starts in the supercut.
        let lines = vtt.components(separatedBy: "\n")
        let cueLine = try #require(lines.firstIndex { $0.contains("w5") })
        let start = try #require(Captions.parseStamp(lines[cueLine - 1].components(separatedBy: " --> ")[0]))
        let inClip = try #require(Captions.parseStamp(try String(contentsOf: dir.appendingPathComponent("C02-second/C02-second-1080p.vtt"), encoding: .utf8)
            .components(separatedBy: "\n").first { $0.contains(" --> ") }!.components(separatedBy: " --> ")[0]))
        #expect(abs(start - (ra.duration + inClip)) < 0.1, "\(start) vs \(ra.duration) + \(inClip)")
        let md = try String(contentsOf: dir.appendingPathComponent("talk-supercut/talk-supercut-1080p.md"), encoding: .utf8)
        #expect(md.contains("0:00 First\n0:0"))
        #expect(md.contains("Second"))
        #expect(md.contains("About the second."))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("C02-second/C02-second-1080p.md").path))
    }
}

@Suite struct PostExportRunnerTests {
    /// A staged export (fake bytes; the runner never decodes it) in `<root>/exports/C01-a/.unbranded/`.
    func staged(_ root: URL) throws -> Renderer.Rendered {
        let dir = root.appendingPathComponent("exports/C01-a/.unbranded")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for ext in ["mp4", "timeline.json", "vtt", "md"] {
            try Data("plain \(ext)".utf8).write(to: dir.appendingPathComponent("C01-a-4k.\(ext)"))
        }
        var r = Renderer.Rendered(slug: "a", name: "A", file: dir.appendingPathComponent("C01-a-4k.mp4"), duration: 1)
        r.stamp = "abc"
        return r
    }

    func script(_ root: URL, _ body: String) throws -> PostExport {
        let url = root.appendingPathComponent("tool with space")
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return PostExport(run: url.path, args: ["{timeline}", "-o", "{output}", "{exports}"])
    }

    func context(_ root: URL, _ command: PostExport) -> PostExportRunner.Context {
        PostExportRunner.Context(command: command, package: root, exports: root.appendingPathComponent("exports"),
                                 framing: .portrait, resolution: .full)
    }

    @Test func successPutsTheResultUnderTheUsualName() async throws {
        let root = tempDir()
        let r = try staged(root)
        let cmd = try script(root, #"""
        echo "slug $OCTOEDIT_SLUG $OCTOEDIT_FRAMING $OCTOEDIT_QUALITY"
        [ "$4" = "$OCTOEDIT_EXPORTS" ] || exit 9
        { echo branded; cat "${1%.timeline.json}.mp4"; } > "$3"
        """#)
        let lines = LineBox()
        let done = try await PostExportRunner.run(r, context(root, cmd)) { lines.add($0) }
        let folder = root.appendingPathComponent("exports/C01-a")
        #expect(done.file == folder.appendingPathComponent("C01-a-4k.mp4"))
        #expect(try String(contentsOf: done.file, encoding: .utf8) == "branded\nplain mp4")
        for ext in ["timeline.json", "vtt", "md"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("C01-a-4k.\(ext)").path))
        }
        #expect(ExportStamp.read(in: folder) == "abc")
        #expect(lines.all == ["slug a 9:16 full"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".C01-a-4k.partial.mp4").path))
        PostExportRunner.removeStaging(of: r)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".unbranded").path))
    }

    @Test func failureLeavesNoFinalFileAndKeepsTheStagedOne() async throws {
        let root = tempDir()
        let r = try staged(root)
        let cmd = try script(root, "echo half > \"$3\"; echo 'no talks.json' >&2; exit 2\n")
        await #expect {
            _ = try await PostExportRunner.run(r, context(root, cmd))
        } throws: { e in
            guard let f = e as? PostExportRunner.Failure else { return false }
            return f.message.contains("exit 2") && f.message.contains("no talks.json") && f.output.contains("no talks.json")
        }
        let folder = root.appendingPathComponent("exports/C01-a")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("C01-a-4k.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".C01-a-4k.partial.mp4").path))
        #expect(FileManager.default.fileExists(atPath: r.file.path))
        #expect(ExportStamp.read(in: folder) == nil)
    }

    @Test func missingProgramAndMissingOutputAreReported() async throws {
        let root = tempDir()
        let r = try staged(root)
        #expect(PostExportRunner.problem(PostExport(run: "nope/brand-clip"), package: root)?.contains("not found") == true)
        let silent = try script(root, "exit 0\n")
        await #expect {
            _ = try await PostExportRunner.run(r, context(root, silent))
        } throws: { ($0 as? PostExportRunner.Failure)?.message.contains("without writing") == true }
    }

    @Test func cancellingStopsTheProgramAndRemovesThePartialFile() async throws {
        let root = tempDir()
        let r = try staged(root)
        let cmd = try script(root, "echo started; echo part > \"$3\"; sleep 30\n")
        let lines = LineBox()
        let task = Task { try await PostExportRunner.run(r, context(root, cmd)) { lines.add($0) } }
        for _ in 0..<100 where lines.all.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
        let folder = root.appendingPathComponent("exports/C01-a")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".C01-a-4k.partial.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("C01-a-4k.mp4").path))
    }

    @Test func laneRunsJobsOneAtATimeInOrder() async throws {
        let lane = SerialLane()
        let log = LineBox()
        var tasks: [Task<Int, Error>] = []
        for i in 0..<4 {
            tasks.append(await lane.submit {
                log.add("start \(i)")
                try await Task.sleep(for: .milliseconds(i == 0 ? 80 : 10))
                log.add("end \(i)")
                return i
            })
        }
        for (i, t) in tasks.enumerated() { #expect(try await t.value == i) }
        #expect(log.all == (0..<4).flatMap { ["start \($0)", "end \($0)"] })
    }

    @Test func placeholdersAndPathResolution() {
        let staged = URL(fileURLWithPath: "/x/exports/C01-a/.unbranded/C01-a-4k.mp4")
        let out = URL(fileURLWithPath: "/x/exports/C01-a/.C01-a-4k.partial.mp4")
        let cmd = PostExport(run: "../tools/b", args: ["{timeline}", "--in={video}", "-o", "{output}", "{exports}"])
        #expect(PostExportRunner.arguments(cmd, staged: staged, output: out, exports: URL(fileURLWithPath: "/x/exports"))
                == ["/x/exports/C01-a/.unbranded/C01-a-4k.timeline.json", "--in=/x/exports/C01-a/.unbranded/C01-a-4k.mp4",
                    "-o", "/x/exports/C01-a/.C01-a-4k.partial.mp4", "/x/exports"])
        #expect(PostExportRunner.executable(cmd, package: URL(fileURLWithPath: "/p/s.octoedit")).path == "/p/tools/b")
        #expect(PostExportRunner.finalFile(for: staged).path == "/x/exports/C01-a/C01-a-4k.mp4")
        #expect(PostExportRunner.executable(PostExport(run: "~/b"), package: URL(fileURLWithPath: "/p")).path
                == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("b").path)
    }
}

final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
