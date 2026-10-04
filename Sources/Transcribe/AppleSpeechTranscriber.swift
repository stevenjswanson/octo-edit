import Foundation
import AVFoundation
import Speech
import Core

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26), English only.
/// Each attributed run of a result carries its own audio time range; runs are
/// split on whitespace so every TimedWord is a single word.
public struct AppleSpeechTranscriber: Transcriber {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public enum TranscriberError: Error, CustomStringConvertible {
        case unsupportedLocale(String)
        case unavailable

        public var description: String {
            switch self {
            case .unsupportedLocale(let l): "speech recognition does not support \(l) on this Mac"
            case .unavailable: "speech recognition is not available on this Mac"
            }
        }
    }

    public func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    words += Self.split(text, start: range.start.seconds, end: range.end.seconds,
                                        confidence: run.transcriptionConfidence)
                }
                if duration > 0 { progress(min(result.range.end.seconds / duration, 1)) }
            }
            return words
        }
        do {
            // Cancelling the calling task stops the analyzer (and so the results stream).
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        try Task.checkCancellation()
        progress(1)
        return words.sorted { $0.start < $1.start }
    }

    /// Splits a run into words, sharing its time range by character count.
    static func split(_ text: String, start: Double, end: Double, confidence: Double?) -> [TimedWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        if parts.count == 1 { return [TimedWord(text: parts[0], start: start, end: end, confidence: confidence)] }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var t = start
        return parts.map { p in
            let d = (end - start) * Double(p.count) / total
            defer { t += d }
            return TimedWord(text: p, start: t, end: t + d, confidence: confidence)
        }
    }
}
