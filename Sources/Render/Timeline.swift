import Foundation
import Core

/// The `.timeline.json` written beside an exported file: what is said, by whom, and
/// where the cuts are, all on the exported file's own clock (seconds from its start),
/// so another tool can read it without knowing OctoEdit's markup or cut rules.
///
/// - `clips`: each clip in the file and the span it fills (one entry, or several for a supercut).
/// - `segments`: each run of source video that was kept, in order. Every boundary between
///   two segments is a cut; `sourceStart`/`sourceEnd` say where it came from in the input.
/// - `turns`: consecutive kept words by one speaker. A turn can run across a cut; a new
///   turn starts at every change of speaker (or of clip).
/// - `words`: each kept, timed word, with its speaker and the index of its segment.
///
/// Times are from the frame-snapped ranges the encoder used, rounded to milliseconds.
/// Words typed by hand (never spoken, so untimed) are left out, as in the captions.
public struct Timeline: Codable, Equatable, Sendable {
    public struct ClipSpan: Codable, Equatable, Sendable {
        public var slug: String
        public var title: String
        public var start: Seconds
        public var end: Seconds
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var clip: String
        public var start: Seconds
        public var end: Seconds
        public var sourceStart: Seconds
        public var sourceEnd: Seconds
    }

    public struct Turn: Codable, Equatable, Sendable {
        public var speaker: String?
        public var start: Seconds
        public var end: Seconds
        public var text: String
    }

    public struct TimedWord: Codable, Equatable, Sendable {
        public var start: Seconds
        public var end: Seconds
        public var speaker: String?
        public var segment: Int
        public var text: String
    }

    public var octoedit = 1
    public var source: String
    public var duration: Seconds
    /// Speakers in order of first appearance.
    public var speakers: [String]
    public var clips: [ClipSpan]
    public var segments: [Segment]
    public var turns: [Turn]
    public var words: [TimedWord]

    /// One clip, from the builder's `sourceRanges` and `segmentStarts`.
    public static func clip(_ clip: Clip, in p: Project, sourceRanges: [ResolvedSegment], clipStarts: [Seconds]) -> Timeline {
        make([clip], in: p, segmentCounts: [sourceRanges.count], sourceRanges: sourceRanges, clipStarts: clipStarts)
    }

    /// Several clips encoded as one file; `segmentCounts[i]` is how many of the
    /// composition's segments belong to clip i.
    public static func supercut(_ clips: [Clip], in p: Project, segmentCounts: [Int],
                                sourceRanges: [ResolvedSegment], clipStarts: [Seconds]) -> Timeline {
        make(clips, in: p, segmentCounts: segmentCounts, sourceRanges: sourceRanges, clipStarts: clipStarts)
    }

    /// Timelines of files joined end to end, each shifted by its file's start.
    public static func concatenate(_ parts: [(timeline: Timeline, start: Seconds)], duration: Seconds) -> Timeline? {
        guard let first = parts.first?.timeline else { return nil }
        var out = Timeline(source: first.source, duration: ms(duration), speakers: [], clips: [], segments: [], turns: [], words: [])
        for (t, shift) in parts {
            let base = out.segments.count
            out.clips += t.clips.map { ClipSpan(slug: $0.slug, title: $0.title, start: ms($0.start + shift), end: ms($0.end + shift)) }
            out.segments += t.segments.map { var s = $0; s.start = ms(s.start + shift); s.end = ms(s.end + shift); return s }
            out.turns += t.turns.map { var u = $0; u.start = ms(u.start + shift); u.end = ms(u.end + shift); return u }
            out.words += t.words.map { var w = $0; w.start = ms(w.start + shift); w.end = ms(w.end + shift); w.segment += base; return w }
            for s in t.speakers where !out.speakers.contains(s) { out.speakers.append(s) }
        }
        return out
    }

    static func make(_ clips: [Clip], in p: Project, segmentCounts: [Int],
                     sourceRanges: [ResolvedSegment], clipStarts: [Seconds]) -> Timeline {
        let slugs = p.slugs()
        // Which clip each segment belongs to. If a segment vanished when snapped to
        // frames the counts no longer add up; then the words say which clip is which.
        var owner: [Int] = []
        if segmentCounts.reduce(0, +) == sourceRanges.count {
            for (i, n) in segmentCounts.enumerated() { owner += Array(repeating: i, count: n) }
        }
        let words = Captions.timedWords(supercut: clips, in: p, segmentCounts: segmentCounts,
                                        sourceRanges: sourceRanges, clipStarts: clipStarts)
        if owner.count != sourceRanges.count {
            owner = sourceRanges.indices.map { k in words.first { $0.segment == k }?.group ?? 0 }
        }
        let duration = zip(clipStarts, sourceRanges).map { $0 + $1.duration }.max() ?? 0

        let segments = sourceRanges.indices.map { k in
            Segment(clip: slugs[clips[owner[k]].id] ?? "", start: ms(clipStarts[k]),
                    end: ms(clipStarts[k] + sourceRanges[k].duration),
                    sourceStart: ms(sourceRanges[k].start), sourceEnd: ms(sourceRanges[k].end))
        }
        var spans: [ClipSpan] = []
        for (i, clip) in clips.enumerated() {
            let mine = segments.indices.filter { owner[$0] == i }
            guard let a = mine.first, let b = mine.last else { continue }
            spans.append(ClipSpan(slug: slugs[clip.id] ?? "", title: ExportNotes.title(clip, p),
                                  start: segments[a].start, end: segments[b].end))
        }

        var turns: [Turn] = []
        var lastGroup = -1
        var speakers: [String] = []
        for w in words {
            if let s = w.speaker, !speakers.contains(s) { speakers.append(s) }
            if var t = turns.last, t.speaker == w.speaker, w.group == lastGroup {
                t.end = ms(w.end)
                t.text += " " + w.text
                turns[turns.count - 1] = t
            } else {
                turns.append(Turn(speaker: w.speaker, start: ms(w.start), end: ms(w.end), text: w.text))
            }
            lastGroup = w.group
        }

        return Timeline(source: p.source, duration: ms(duration), speakers: speakers, clips: spans, segments: segments,
                        turns: turns,
                        words: words.map { TimedWord(start: ms($0.start), end: ms($0.end), speaker: $0.speaker,
                                                     segment: $0.segment, text: $0.text) })
    }

    static func ms(_ t: Seconds) -> Seconds { (t * 1000).rounded() / 1000 }

    /// Pretty JSON with one array element per line and keys in a fixed order, so it
    /// reads (and diffs) line by line.
    public func json() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        func value<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }
        func object(_ pairs: [(String, any Encodable)]) throws -> String {
            var fields: [String] = []
            for (key, v) in pairs { fields.append("\"\(key)\": " + (try value(v))) }   // opens the existential
            return "{" + fields.joined(separator: ", ") + "}"
        }
        func array<T>(_ xs: [T], _ row: (T) throws -> String) throws -> String {
            xs.isEmpty ? "[]" : "[\n    " + (try xs.map(row)).joined(separator: ",\n    ") + "\n  ]"
        }
        return """
        {
          "octoedit": \(octoedit),
          "source": \(try value(source)),
          "duration": \(try value(duration)),
          "speakers": \(try value(speakers)),
          "clips": \(try array(clips) { try object([("slug", $0.slug), ("title", $0.title), ("start", $0.start), ("end", $0.end)]) }),
          "segments": \(try array(segments) {
              try object([("clip", $0.clip), ("start", $0.start), ("end", $0.end),
                          ("sourceStart", $0.sourceStart), ("sourceEnd", $0.sourceEnd)]) }),
          "turns": \(try array(turns) {
              try object([("speaker", $0.speaker), ("start", $0.start), ("end", $0.end), ("text", $0.text)]) }),
          "words": \(try array(words) {
              try object([("start", $0.start), ("end", $0.end), ("speaker", $0.speaker),
                          ("segment", $0.segment), ("text", $0.text)]) })
        }

        """
    }
}
