import Foundation

/// App-wide gate for transcription jobs (several windows importing at once would
/// fight over the Neural Engine). v1 runs one import at a time anyway, so this is a
/// pass-through; a bounded queue replaces it when multi-document is turned on.
protocol TranscriptionQueue: Sendable {
    func run<T: Sendable>(_ job: @Sendable () async throws -> T) async throws -> T
}

struct PassThroughTranscriptionQueue: TranscriptionQueue {
    func run<T: Sendable>(_ job: @Sendable () async throws -> T) async throws -> T { try await job() }
}
