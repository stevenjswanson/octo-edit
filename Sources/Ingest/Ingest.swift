import Foundation
import Core

/// Builds a new Project from an input video (and optionally a Zoom transcript).
///
/// The result is meant to go straight to Save; nothing edits or renders an
/// ingested project in memory (everything else starts from Load).
public struct Ingest: Sendable {
    public struct Result: Sendable {
        public var project: Project
        /// The timed words for words.tsv.
        public var words: [TimedWord]
        public var envelope: Envelope
    }

    public enum Stage: String, Sendable {
        case analyzingAudio = "Analyzing audio"
        case transcribing = "Transcribing"
        case aligning = "Aligning with Zoom transcript"
    }

    public var transcriber: any Transcriber
    public var analyzer: any EnvelopeAnalyzer
    public var refiner = SilenceRefiner()

    /// Paragraph breaks when there is no Zoom transcript.
    public var paragraphPause: Seconds = 1.5
    public var longPause: Seconds = 2.5
    public var maxParagraphWords = 90
    /// With a Zoom transcript, a pause this long always starts a paragraph.
    public var cuePause: Seconds = 1.0

    public init(transcriber: any Transcriber, analyzer: any EnvelopeAnalyzer) {
        self.transcriber = transcriber
        self.analyzer = analyzer
    }

    public func run(video: URL, zoom: URL?, settings: ProjectSettings,
                    progress: @escaping @Sendable (Stage, Double) -> Void = { _, _ in }) async throws -> Result {
        progress(.analyzingAudio, 0)
        let envelope = try await analyzer.envelope(of: video)
        progress(.analyzingAudio, 1)
        let raw = try await transcriber.transcribe(audio: video) { progress(.transcribing, $0) }
        let refined = refiner.refine(raw, envelope: envelope)

        var project = Project(source: video.standardizedFileURL.path, settings: settings)
        if let zoom {
            progress(.aligning, 0)
            let cues = ZoomVTT.parse(try String(contentsOf: zoom, encoding: .utf8))
            let merged = ZoomMerge.merge(asr: refined, cues: cues)
            project.zoom = ZoomInfo(file: zoom.lastPathComponent, offset: merged.offset)
            build(&project, merged: merged, cues: cues)
            progress(.aligning, 1)
        } else {
            build(&project, words: refined)
        }
        let timed = project.words.compactMap { w -> TimedWord? in
            guard let s = w.start, let e = w.end else { return nil }
            return TimedWord(text: w.text, start: s, end: e, confidence: w.confidence)
        }
        return Result(project: project, words: timed, envelope: envelope)
    }

    /// Paragraphs from Zoom cues. A new paragraph starts at a cue boundary where a
    /// sentence really ends (Zoom's fake cue-end periods are already repaired), when the
    /// speaker changes, after a pause, or at a sentence end once a paragraph is long.
    /// Zoom transcripts may credit one speaker for everything, so speaker alone never
    /// merges paragraphs. Zoom-only cues become `>` paragraphs placed by time.
    func build(_ p: inout Project, merged: ZoomMerge.Output, cues: [Cue]) {
        var paragraphs: [Paragraph] = []
        var words: [Word] = []
        var zoomOnly = merged.zoomOnly[...]

        func emitZoomOnly(before t: Seconds?) {
            while let c = zoomOnly.first, t == nil || c.start - merged.offset <= t! {
                zoomOnly = zoomOnly.dropFirst()
                let id = ParagraphID(paragraphs.count + 1)
                paragraphs.append(Paragraph(id: id, speaker: c.speaker, zoomCue: c.index, zoomOnly: true, zoomStart: c.start))
                for t in c.text.split(whereSeparator: \.isWhitespace) {
                    words.append(Word(id: WordID(words.count + 1), text: String(t), paragraph: id))
                }
            }
        }

        var lastCue: Int?
        var countInParagraph = 0
        for mw in merged.words {
            emitZoomOnly(before: mw.word.start)
            let cue = mw.cue.map { cues[$0] }
            let prev = words.last
            let afterZoomOnly = paragraphs.last?.zoomOnly ?? true
            let speakerChanged = paragraphs.last.map { $0.speaker != cue?.speaker } ?? true
            let pause = (prev?.end).map { mw.word.start - $0 } ?? 0
            let sentenceEnded = prev.map { ZoomMerge.endsSentence($0.text) } ?? false
            let cueBoundary = mw.cue != lastCue
            lastCue = mw.cue
            if afterZoomOnly || speakerChanged || pause >= cuePause || (cueBoundary && sentenceEnded)
                || (countInParagraph >= maxParagraphWords && sentenceEnded) {
                countInParagraph = 0
                paragraphs.append(Paragraph(id: ParagraphID(paragraphs.count + 1), speaker: cue?.speaker, zoomCue: cue?.index))
            }
            words.append(Word(id: WordID(words.count + 1), text: mw.word.text, start: mw.word.start, end: mw.word.end,
                              confidence: mw.word.confidence, paragraph: paragraphs.last!.id))
            countInParagraph += 1
        }
        emitZoomOnly(before: nil)
        p.paragraphs = paragraphs
        p.words = words
    }

    /// Paragraphs from pauses alone (no Zoom transcript, no speakers).
    func build(_ p: inout Project, words timed: [TimedWord]) {
        var paragraphs: [Paragraph] = []
        var words: [Word] = []
        var countInParagraph = 0
        for w in timed {
            let prev = words.last
            let pause = (prev?.end).map { w.start - $0 } ?? 0
            let sentenceEnded = prev.map { [".", "?", "!"].contains($0.text.last ?? " ") } ?? false
            if paragraphs.isEmpty || pause >= longPause || (pause >= paragraphPause && sentenceEnded)
                || (countInParagraph >= maxParagraphWords && sentenceEnded) {
                paragraphs.append(Paragraph(id: ParagraphID(paragraphs.count + 1)))
                countInParagraph = 0
            }
            words.append(Word(id: WordID(words.count + 1), text: w.text, start: w.start, end: w.end,
                              confidence: w.confidence, paragraph: paragraphs.last!.id))
            countInParagraph += 1
        }
        p.paragraphs = paragraphs
        p.words = words
    }
}
