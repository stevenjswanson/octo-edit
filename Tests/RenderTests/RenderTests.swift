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
        #expect(ExportStamp.states(p, exports: dir, sourceIdentity: id) == [c: .current, other: .notExported])
        #expect(ExportStamp.states(p, exports: dir, sourceIdentity: "another.mp4 1")[c] == .changed)

        var edited = p
        try edited.omit(words: 2...2, in: c)
        #expect(ExportStamp.states(edited, exports: dir, sourceIdentity: id)[c] == .changed)
        var noted = p
        noted.clips[0].notes = "new notes"
        #expect(ExportStamp.states(noted, exports: dir, sourceIdentity: id)[c] == .changed)
        var renamed = p
        renamed.clips[0].name = "Renamed"
        #expect(ExportStamp.states(renamed, exports: dir, sourceIdentity: id)[c] == .notExported)
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
