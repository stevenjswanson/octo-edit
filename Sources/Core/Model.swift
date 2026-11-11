import Foundation

public typealias Seconds = Double

public struct WordID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public static func < (a: WordID, b: WordID) -> Bool { a.raw < b.raw }
    public var description: String { "w\(raw)" }
}

public struct ParagraphID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "p\(raw)" }
}

public struct ClipID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "c\(raw)" }
}

/// One word of the unified transcript, timed on the source-video clock.
/// `start`/`end` are nil for words that were typed by hand and never spoken.
public struct Word: Equatable, Sendable {
    public var id: WordID
    public var text: String
    public var start: Seconds?
    public var end: Seconds?
    public var confidence: Double?
    public var paragraph: ParagraphID

    public init(id: WordID, text: String, start: Seconds? = nil, end: Seconds? = nil,
                confidence: Double? = nil, paragraph: ParagraphID) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.paragraph = paragraph
    }

    public var isTimed: Bool { start != nil && end != nil }
}

/// Our grouping of words for display and editing.
/// Zoom-only paragraphs hold Zoom cues that matched nothing in the source audio;
/// their words are never timed and they may not contain clip markers.
public struct Paragraph: Equatable, Sendable {
    public var id: ParagraphID
    public var speaker: String?
    public var zoomCue: Int?
    public var zoomOnly: Bool
    /// Start on the Zoom clock; only meaningful for zoom-only paragraphs.
    public var zoomStart: Seconds?

    public init(id: ParagraphID, speaker: String? = nil, zoomCue: Int? = nil,
                zoomOnly: Bool = false, zoomStart: Seconds? = nil) {
        self.id = id
        self.speaker = speaker
        self.zoomCue = zoomCue
        self.zoomOnly = zoomOnly
        self.zoomStart = zoomStart
    }
}

/// A cut point anchored to a word. In-points anchor to a word's start, out-points
/// to a word's end. `offset` nil means "use the project default for this role".
public struct Boundary: Equatable, Sendable {
    public var word: WordID
    public var offset: Seconds?

    public init(word: WordID, offset: Seconds? = nil) {
        self.word = word
        self.offset = offset
    }
}

/// A run of kept words. The words between consecutive segments of a clip are omitted.
public struct Segment: Equatable, Sendable {
    public var inPoint: Boundary
    public var outPoint: Boundary

    public init(inPoint: Boundary, outPoint: Boundary) {
        self.inPoint = inPoint
        self.outPoint = outPoint
    }
}

public struct Clip: Equatable, Sendable {
    public var id: ClipID
    public var name: String?
    public var notes: String
    public var suggestions: [String]
    public var segments: [Segment]
    /// Auto-levels: stretch the clip's tones and colours to a full range, in preview
    /// and export. On unless the marker says `{clip … nolevels}`.
    public var autoLevels: Bool

    public init(id: ClipID, name: String? = nil, notes: String = "", suggestions: [String] = [],
                segments: [Segment], autoLevels: Bool = true) {
        self.id = id
        self.name = name
        self.notes = notes
        self.suggestions = suggestions
        self.segments = segments
        self.autoLevels = autoLevels
    }
}

/// A run of omitted words outside every clip (omissions inside a clip are the gaps
/// between its segments). It is kept so that a clip later drawn over these words
/// still leaves them out. The offsets fine-tune the cuts around the run, as they do
/// inside a clip: `cutOffset` from the end of the word before it, `resumeOffset` from
/// the start of the word after it.
public struct Omission: Equatable, Sendable {
    public var first: WordID
    public var last: WordID
    public var cutOffset: Seconds?
    public var resumeOffset: Seconds?

    public init(first: WordID, last: WordID, cutOffset: Seconds? = nil, resumeOffset: Seconds? = nil) {
        self.first = first
        self.last = last
        self.cutOffset = cutOffset
        self.resumeOffset = resumeOffset
    }
}

public struct ZoomInfo: Equatable, Sendable {
    public var file: String
    /// Zoom clock = source clock + offset.
    public var offset: Seconds

    public init(file: String, offset: Seconds) {
        self.file = file
        self.offset = offset
    }
}

public enum Codec: String, Sendable, CaseIterable {
    case hevc, h264
}

/// Output shape of exported clips.
public enum Framing: String, Sendable, CaseIterable {
    /// As the input video came in: no crop.
    case source
    /// A full-height 9:16 column of the shot, centred on the current speaker.
    case portrait = "9:16"
}

public struct ProjectSettings: Equatable, Sendable {
    public var prePad: Seconds
    public var postPad: Seconds
    public var crossfade: Seconds
    /// nil = same codec as the input video.
    public var codec: Codec?
    public var framing: Framing
    /// 9:16: how long a move to a new speaker takes, fading to black and back in
    /// (half each way); 0 cuts.
    public var speakerFade: Seconds

    public static let defaultSpeakerFade: Seconds = 0.2

    public init(prePad: Seconds = 0.12, postPad: Seconds = 0.18, crossfade: Seconds = 0.02, codec: Codec? = nil,
                framing: Framing = .source, speakerFade: Seconds = Self.defaultSpeakerFade) {
        self.prePad = prePad
        self.postPad = postPad
        self.crossfade = crossfade
        self.codec = codec
        self.framing = framing
        self.speakerFade = speakerFade
    }
}

/// A note whose key matches no clip; kept so hand edits are never silently lost.
public struct StrayNote: Equatable, Sendable {
    public var key: String
    public var text: String

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

public struct Project: Equatable, Sendable {
    /// Path to the input video exactly as written in the document.
    public var source: String
    public var zoom: ZoomInfo?
    public var settings: ProjectSettings
    public var paragraphs: [Paragraph]
    public var words: [Word] { didSet { reindex() } }
    /// Clips in document order; their word ranges never overlap.
    public var clips: [Clip]
    /// Omitted runs outside every clip, in document order; never inside a clip's range.
    public var omissions: [Omission]
    public var strayNotes: [StrayNote]
    /// The roster: every speaker name in the project, including names no paragraph
    /// uses yet. Every paragraph's speaker is on it (see `Project.speakersInOrder`).
    public var speakers: [String]

    private var wordIndex: [WordID: Int] = [:]

    public init(source: String, zoom: ZoomInfo? = nil, settings: ProjectSettings = ProjectSettings(),
                paragraphs: [Paragraph] = [], words: [Word] = [], clips: [Clip] = [],
                strayNotes: [StrayNote] = [], omissions: [Omission] = [], speakers: [String] = []) {
        self.source = source
        self.zoom = zoom
        self.settings = settings
        self.paragraphs = paragraphs
        self.words = words
        self.clips = clips
        self.strayNotes = strayNotes
        self.omissions = omissions
        self.speakers = speakers
        reindex()
    }

    private mutating func reindex() {
        wordIndex = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1.id, $0) })
    }

    public func index(of id: WordID) -> Int? { wordIndex[id] }

    public func word(_ id: WordID) -> Word? { index(of: id).map { words[$0] } }

    public func paragraph(_ id: ParagraphID) -> Paragraph? { paragraphs.first { $0.id == id } }

    public func clip(_ id: ClipID) -> Clip? { clips.first { $0.id == id } }
}

/// Raw recognizer output: one word with its source-clock timing.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    public var confidence: Double?

    public init(text: String, start: Seconds, end: Seconds, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// One caption block from a Zoom `.vtt`, on the Zoom clock.
public struct Cue: Equatable, Sendable {
    public var index: Int
    public var start: Seconds
    public var end: Seconds
    public var speaker: String?
    public var text: String

    public init(index: Int, start: Seconds, end: Seconds, speaker: String?, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// Audio loudness over time: linear RMS in fixed-width buckets.
public struct Envelope: Equatable, Sendable {
    public var bucketsPerSecond: Double
    public var rms: [Float]

    public init(bucketsPerSecond: Double, rms: [Float]) {
        self.bucketsPerSecond = bucketsPerSecond
        self.rms = rms
    }

    public var duration: Seconds { Double(rms.count) / bucketsPerSecond }

    public func bucket(at t: Seconds) -> Int {
        min(max(Int(t * bucketsPerSecond), 0), max(rms.count - 1, 0))
    }

    public func time(ofBucket i: Int) -> Seconds { Double(i) / bucketsPerSecond }

    /// Level in dBFS of bucket `i` (floored at -120 dB).
    public func decibels(_ i: Int) -> Double {
        20 * log10(max(Double(rms[i]), 1e-6))
    }
}

public struct Issue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    public var message: String
    public var line: Int?

    public init(_ severity: Severity, _ message: String, line: Int? = nil) {
        self.severity = severity
        self.message = message
        self.line = line
    }

    public var description: String {
        (line.map { "line \($0): " } ?? "") + "\(severity.rawValue): \(message)"
    }
}
