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

/// One stretch of one voice, on the source-video clock. `voice` is a label that is
/// stable within one diarization run only ("S1", "S2", …).
public struct VoiceTurn: Equatable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public var voice: String

    public init(start: Seconds, end: Seconds, voice: String) {
        self.start = start
        self.end = end
        self.voice = voice
    }
}

/// Finds who speaks when from the audio alone (no names).
public protocol Diarizer: Sendable {
    func diarize(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [VoiceTurn]
}

/// One voice's speech, as a namer sees it.
public struct VoiceSample: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public var start: Seconds
        public var text: String
        /// The end of the turn before this one (by another voice), for "Leena, do you want to start?".
        public var before: String
        /// The start of the turn after this one, for "Thanks, Mia."
        public var after: String

        public init(start: Seconds, text: String, before: String = "", after: String = "") {
            self.start = start
            self.text = text
            self.before = before
            self.after = after
        }
    }

    public var voice: String
    public var seconds: Seconds
    public var turns: [Turn]

    public init(voice: String, seconds: Seconds, turns: [Turn]) {
        self.voice = voice
        self.seconds = seconds
        self.turns = turns
    }
}

/// Puts roster names on voices from what is said ("I'm Kathy", "Leena, do you want to
/// start?"). Returns only confident matches; each roster name is used at most once.
public protocol SpeakerNamer: Sendable {
    var label: String { get }
    func names(for voices: [VoiceSample], roster: [String]) async -> [String: String]
}
