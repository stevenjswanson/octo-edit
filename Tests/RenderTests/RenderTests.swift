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
        #expect(out.file.lastPathComponent == "clip-01-1080p.mp4")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip-01-1080p.vtt").path))

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
        let vtt = try String(contentsOf: dir.appendingPathComponent("supercut-all-1080p.vtt"), encoding: .utf8)
        #expect(vtt.contains("w1 w2"))
        #expect(vtt.contains("w5 w6"))
        #expect(!vtt.contains("w2 w5"))
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
        #expect(out.file.lastPathComponent == "tone-test.preview.mp4")
        let v = try await AVURLAsset(url: out.file).loadTracks(withMediaType: .video)[0]
        let (size, formats) = try await (v.load(.naturalSize), v.load(.formatDescriptions))
        #expect(size == CGSize(width: 1280, height: 720))
        #expect(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tone-test.preview.vtt").path))
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
        #expect(out.file.lastPathComponent == "tone-test-720p.mp4")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tone-test-720p.vtt").path))
        let v = try await AVURLAsset(url: out.file).loadTracks(withMediaType: .video)[0]
        let (size, formats) = try await (v.load(.naturalSize), v.load(.formatDescriptions))
        #expect(size == CGSize(width: 1280, height: 720))
        #expect(CMFormatDescriptionGetMediaSubType(formats[0]) == kCMVideoCodecType_H264)
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
        #expect(abs(cut.duration - (ra.duration + rb.duration)) < 0.1, "\(cut.duration) vs \(ra.duration + rb.duration)")
        let vtt = try String(contentsOf: dir.appendingPathComponent("talk-supercut-1080p.vtt"), encoding: .utf8)
        #expect(vtt.contains("w1 w2") && vtt.contains("w5 w6"))
        // The second clip's caption starts where that clip starts in the supercut.
        let lines = vtt.components(separatedBy: "\n")
        let cueLine = try #require(lines.firstIndex { $0.contains("w5") })
        let start = try #require(Captions.parseStamp(lines[cueLine - 1].components(separatedBy: " --> ")[0]))
        let inClip = try #require(Captions.parseStamp(try String(contentsOf: dir.appendingPathComponent("second-1080p.vtt"), encoding: .utf8)
            .components(separatedBy: "\n").first { $0.contains(" --> ") }!.components(separatedBy: " --> ")[0]))
        #expect(abs(start - (ra.duration + inClip)) < 0.1, "\(start) vs \(ra.duration) + \(inClip)")
        let md = try String(contentsOf: dir.appendingPathComponent("talk-supercut-1080p.md"), encoding: .utf8)
        #expect(md.contains("0:00 First\n0:0"))
        #expect(md.contains("Second"))
        #expect(md.contains("About the second."))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("second-1080p.md").path))
    }
}
