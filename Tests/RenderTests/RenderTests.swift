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
        #expect(out.file.lastPathComponent == "clip-01.mp4")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip-01.vtt").path))

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
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tone-test.vtt").path))
    }

    @Test(.enabled(if: haveTone)) func notesFileListsClipsWithFootnotes() async throws {
        var p = secondsProject(source: fixture("tone-4k.mp4").path)
        let a = try p.makeClip(words: 0...1, name: "First")
        _ = try p.makeClip(words: 3...4)
        try p.setNotes(clip: a, "Keep this one.\nIt matters.")
        let r = try await Renderer(project: p, source: fixture("tone-4k.mp4"))
        let notes = r.notesFile(for: [
            .init(slug: "first", name: "First", file: URL(fileURLWithPath: "/x/first.mp4"), duration: 2.3),
            .init(slug: "clip-02", name: nil, file: URL(fileURLWithPath: "/x/clip-02.mp4"), duration: 1.1),
        ])
        #expect(notes.contains("- [first.mp4](first.mp4) — First — 0:02.3[^first]"))
        #expect(notes.contains("- [clip-02.mp4](clip-02.mp4) — clip-02 — 0:01.1\n"))
        #expect(notes.contains("[^first]: Keep this one.\n    It matters."))
    }
}
