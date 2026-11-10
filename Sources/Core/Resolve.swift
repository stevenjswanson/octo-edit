import Foundation

/// A segment resolved to source-clock times.
public struct ResolvedSegment: Equatable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public var duration: Seconds { end - start }

    public init(start: Seconds, end: Seconds) {
        self.start = start
        self.end = end
    }
}

/// Every omitted word in the project, inside clips and out, with the explicit offsets
/// on the cuts around each run. Runs are maximal: adjacent omitted words form one run.
public struct OmissionMap: Equatable, Sendable {
    public var omitted: [Bool]
    /// Offset of the cut before a run (from the end of the word before it), by the run's first word.
    public var cutOffset: [Int: Seconds] = [:]
    /// Offset where kept words resume after a run (from the start of the word after it), by the run's last word.
    public var resumeOffset: [Int: Seconds] = [:]

    public init(count: Int) { omitted = Array(repeating: false, count: count) }

    /// Maximal runs of omitted words.
    public func runs() -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var i = 0
        while i < omitted.count {
            guard omitted[i] else { i += 1; continue }
            var j = i
            while j + 1 < omitted.count, omitted[j + 1] { j += 1 }
            out.append(i...j)
            i = j + 1
        }
        return out
    }
}

extension Project {
    /// Offset actually applied to a boundary: explicit, else the role default
    /// (pre-pad before a clip's first word, post-pad after its last, 0 at omits).
    public func effectiveOffset(of clip: Clip, segment k: Int, inPoint: Bool) -> Seconds {
        let seg = clip.segments[k]
        if inPoint {
            return seg.inPoint.offset ?? (k == 0 ? -settings.prePad : 0)
        }
        return seg.outPoint.offset ?? (k == clip.segments.count - 1 ? settings.postPad : 0)
    }

    /// Word-index range a segment covers.
    public func indexRange(of segment: Segment) -> ClosedRange<Int>? {
        guard let a = index(of: segment.inPoint.word), let b = index(of: segment.outPoint.word), a <= b else { return nil }
        return a...b
    }

    public func indexRange(of omission: Omission) -> ClosedRange<Int>? {
        guard let a = index(of: omission.first), let b = index(of: omission.last), a <= b else { return nil }
        return a...b
    }

    /// All omissions, from the clips' gaps and the omissions outside clips. Inside a
    /// clip's range its segments decide.
    public func omissionMap() -> OmissionMap {
        var m = OmissionMap(count: words.count)
        for o in omissions {
            guard let r = indexRange(of: o) else { continue }
            for i in r { m.omitted[i] = true }
            m.cutOffset[r.lowerBound] = o.cutOffset
            m.resumeOffset[r.upperBound] = o.resumeOffset
        }
        for clip in clips {
            guard let range = indexRange(of: clip) else { continue }
            for i in range { m.omitted[i] = true }
            m.cutOffset = m.cutOffset.filter { !range.contains($0.key) }
            m.resumeOffset = m.resumeOffset.filter { !range.contains($0.key) }
            let ranges = clip.segments.map { indexRange(of: $0) }
            for r in ranges.compactMap({ $0 }) { for i in r { m.omitted[i] = false } }
            for k in 0..<max(ranges.count - 1, 0) {
                guard let a = ranges[k], let b = ranges[k + 1], a.upperBound + 1 < b.lowerBound else { continue }
                m.cutOffset[a.upperBound + 1] = clip.segments[k].outPoint.offset
                m.resumeOffset[b.lowerBound - 1] = clip.segments[k + 1].inPoint.offset
            }
        }
        return m
    }

    /// Word-index range from a clip's first in-point to its last out-point.
    public func indexRange(of clip: Clip) -> ClosedRange<Int>? {
        guard let first = clip.segments.first, let last = clip.segments.last,
              let a = index(of: first.inPoint.word), let b = index(of: last.outPoint.word), a <= b else { return nil }
        return a...b
    }

    /// Source-clock time ranges for a clip, in order. Untimed anchor words fall back to
    /// the nearest timed word inside the segment; segments with no timed words are dropped.
    /// Later segments never start before earlier ones end; `sourceDuration` clamps the tail.
    public func resolvedSegments(of clip: Clip, sourceDuration: Seconds? = nil) -> [ResolvedSegment] {
        var out: [ResolvedSegment] = []
        for (k, seg) in clip.segments.enumerated() {
            guard let range = indexRange(of: seg),
                  let first = range.first(where: { words[$0].isTimed }),
                  let last = range.reversed().first(where: { words[$0].isTimed }) else { continue }
            var start = words[first].start! + effectiveOffset(of: clip, segment: k, inPoint: true)
            var end = words[last].end! + effectiveOffset(of: clip, segment: k, inPoint: false)
            start = max(start, 0, out.last?.end ?? 0)
            if let d = sourceDuration { end = min(end, d) }
            if end > start { out.append(ResolvedSegment(start: start, end: end)) }
        }
        return out
    }

    public func duration(of clip: Clip, sourceDuration: Seconds? = nil) -> Seconds {
        resolvedSegments(of: clip, sourceDuration: sourceDuration).reduce(0) { $0 + $1.duration }
    }

    /// Words that end up in the clip (inside segments), in order.
    public func keptWords(of clip: Clip) -> [Word] {
        clip.segments.compactMap { indexRange(of: $0) }.flatMap { words[$0] }
    }

    /// Word-index ranges omitted inside a clip.
    public func omittedRanges(of clip: Clip) -> [ClosedRange<Int>] {
        let ranges = clip.segments.compactMap { indexRange(of: $0) }
        return zip(ranges, ranges.dropFirst()).compactMap { a, b in
            a.upperBound + 1 <= b.lowerBound - 1 ? (a.upperBound + 1)...(b.lowerBound - 1) : nil
        }
    }

    /// The clip containing word index `i`, if any.
    public func clip(containingWordAt i: Int) -> Clip? {
        clips.first { indexRange(of: $0)?.contains(i) ?? false }
    }

    /// File-name slugs for every clip, unique within the project.
    /// Named clips slug their name; unnamed clips are `clip-NN` by document order.
    public func slugs() -> [ClipID: String] {
        var used: [String: Int] = [:]
        var result: [ClipID: String] = [:]
        for (n, clip) in clips.enumerated() {
            var base = clip.name.map(slugify) ?? ""
            if base.isEmpty { base = String(format: "clip-%02d", n + 1) }
            let count = (used[base] ?? 0) + 1
            used[base] = count
            result[clip.id] = count == 1 ? base : "\(base)-\(count)"
        }
        return result
    }

    public func slug(of clip: ClipID) -> String? { slugs()[clip] }

    /// The name an exported clip's folder and files start with: `C<n>-<slug>`, where n
    /// is the clip's place in the video, zero-padded to the same width for every clip
    /// (at least two digits), so exports list in the order they occur. `C03-budget`.
    public func exportName(of clip: ClipID) -> String? {
        guard let n = clips.firstIndex(where: { $0.id == clip }), let slug = slug(of: clip) else { return nil }
        let width = max(2, String(clips.count).count)
        let number = String(n + 1)
        return "C" + String(repeating: "0", count: width - number.count) + number + "-" + slug
    }

    public func clip(withSlug slug: String) -> Clip? {
        let all = slugs()
        return clips.first { all[$0.id] == slug }
    }

    /// Structural checks on clips. Format-level problems are reported by the reader.
    public func validate() -> [Issue] {
        var issues: [Issue] = []
        var previousEnd = -1
        var names: [String: Int] = [:]
        for (n, clip) in clips.enumerated() {
            let label = clip.name.map { "\"\($0)\"" } ?? "clip \(n + 1)"
            guard !clip.segments.isEmpty, let range = indexRange(of: clip) else {
                issues.append(Issue(.error, "\(label) has no words"))
                continue
            }
            if range.lowerBound <= previousEnd {
                issues.append(Issue(.error, "\(label) overlaps the previous clip"))
            }
            previousEnd = range.upperBound
            var last = -1
            for seg in clip.segments {
                guard let r = indexRange(of: seg), r.lowerBound > last else {
                    issues.append(Issue(.error, "\(label) has segments out of order"))
                    break
                }
                last = r.upperBound
            }
            let ranges = clip.segments.compactMap { indexRange(of: $0) }
            let edges = ranges.flatMap { [$0.lowerBound, $0.upperBound] }
            let gaps = zip(ranges, ranges.dropFirst()).flatMap { a, b in Array((a.upperBound + 1)..<max(b.lowerBound, a.upperBound + 1)) }
            if (edges + gaps).contains(where: { paragraph(words[$0].paragraph)?.zoomOnly ?? false }) {
                issues.append(Issue(.error, "\(label) has a boundary or omission in Zoom-only text"))
            }
            if resolvedSegments(of: clip).isEmpty {
                issues.append(Issue(.warning, "\(label) has no timed words and will produce no video"))
            }
            if let name = clip.name { names[slugify(name), default: 0] += 1 }
        }
        var clipped = Set<Int>()
        for clip in clips { if let r = indexRange(of: clip) { clipped.formUnion(r) } }
        for o in omissions {
            guard let r = indexRange(of: o) else { issues.append(Issue(.error, "an omission has lost its words")); continue }
            if r.contains(where: { clipped.contains($0) }) {
                issues.append(Issue(.error, "an omission outside the clips overlaps a clip"))
            }
            if r.contains(where: { paragraph(words[$0].paragraph)?.zoomOnly ?? false }) {
                issues.append(Issue(.error, "an omission is in Zoom-only text"))
            }
        }
        for (slug, count) in names where count > 1 {
            issues.append(Issue(.warning, "\(count) clips share the name slug \"\(slug)\"; later ones get -2, -3, …"))
        }
        return issues
    }
}

/// Lower-case, ASCII letters and digits, runs of anything else become "-".
public func slugify(_ name: String) -> String {
    let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
    var out = ""
    var pendingDash = false
    for ch in folded.unicodeScalars {
        if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
            if pendingDash, !out.isEmpty { out.append("-") }
            out.unicodeScalars.append(ch)
            pendingDash = false
        } else {
            pendingDash = true
        }
    }
    return out
}
