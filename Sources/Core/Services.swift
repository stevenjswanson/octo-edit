import Foundation

/// Speech-to-text engine. Implementations live outside Core (e.g. Transcribe);
/// callers only ever see this protocol.
public protocol Transcriber: Sendable {
    func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord]
}

/// Produces a loudness envelope from a media file's first audio track.
public protocol EnvelopeAnalyzer: Sendable {
    func envelope(of media: URL) async throws -> Envelope
}
