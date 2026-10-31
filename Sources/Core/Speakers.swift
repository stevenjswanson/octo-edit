import Foundation

/// The speaker roster and who says which words. Every paragraph has exactly one
/// speaker (or none), and every paragraph's speaker is on the roster.
extension Project {
    /// Roster names in order of first appearance in the transcript, then names no
    /// paragraph uses yet, in roster order. Header names missing from the roster are
    /// included, so this is right even before `normalizeSpeakers`.
    public func speakersInOrder() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in paragraphs.compactMap(\.speaker) + speakers where seen.insert(name).inserted {
            out.append(name)
        }
        return out
    }

    /// Puts the roster in first-appearance order, adding any header name missing from it.
    public mutating func normalizeSpeakers() {
        speakers = speakersInOrder()
    }

    /// Adds a name to the end of the roster (nil, blank or already present: no change).
    public mutating func addSpeaker(_ name: String?) {
        guard let name = Self.speakerName(name), !speakers.contains(name) else { return }
        speakers.append(name)
    }

    /// Removes a name from the roster; refused while any paragraph still uses it.
    public mutating func removeSpeaker(_ name: String) throws {
        if paragraphs.contains(where: { $0.speaker == name }) { throw EditError.speakerInUse(name) }
        speakers.removeAll { $0 == name }
    }

    /// Renames a speaker in the roster and every paragraph header. Renaming to a name
    /// already on the roster merges the two (for one person diarized as two voices).
    public mutating func renameSpeaker(_ old: String, to new: String) {
        guard let new = Self.speakerName(new), new != old else { return }
        for i in paragraphs.indices where paragraphs[i].speaker == old { paragraphs[i].speaker = new }
        if speakers.contains(new) {
            speakers.removeAll { $0 == old }
        } else if let k = speakers.firstIndex(of: old) {
            speakers[k] = new
        } else {
            speakers.append(new)
        }
    }

    /// Gives words `r` to `speaker` (nil = no speaker), splitting paragraphs at the
    /// range's edges so the words around it keep their speakers. Neighbouring
    /// paragraphs with the same speaker are left separate.
    public mutating func assignSpeaker(words r: ClosedRange<Int>, _ speaker: String?) throws {
        try checkRange(r)
        if r.contains(where: { isZoomOnly(wordAt: $0) }) { throw EditError.zoomOnlyText }
        var p = self
        if r.lowerBound > 0, p.words[r.lowerBound - 1].paragraph == p.words[r.lowerBound].paragraph {
            try p.splitParagraph(atWord: r.lowerBound)
        }
        if r.upperBound + 1 < p.words.count, p.words[r.upperBound + 1].paragraph == p.words[r.upperBound].paragraph {
            try p.splitParagraph(atWord: r.upperBound + 1)
        }
        let name = Self.speakerName(speaker)
        let ids = Set(r.map { p.words[$0].paragraph })
        for i in p.paragraphs.indices where ids.contains(p.paragraphs[i].id) { p.paragraphs[i].speaker = name }
        p.addSpeaker(name)
        self = p
    }

    /// The voice of each word (by index): the turn holding the word's midpoint, or
    /// the turn overlapping it most, or the nearest turn within `reach`. Untimed and
    /// Zoom-only words get nil.
    public func voices(from turns: [VoiceTurn], reach: Seconds = 1.0) -> [String?] {
        let sorted = turns.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return Array(repeating: nil, count: words.count) }
        let zoomOnly = Set(paragraphs.filter(\.zoomOnly).map(\.id))
        var out: [String?] = []
        out.reserveCapacity(words.count)
        var k = 0
        for w in words {
            guard let s = w.start, let e = w.end, !zoomOnly.contains(w.paragraph) else { out.append(nil); continue }
            while k < sorted.count - 1, sorted[k].end < s - 30 { k += 1 }
            var best: (overlap: Seconds, distance: Seconds, voice: String)?
            var j = k
            while j < sorted.count, sorted[j].start <= e + reach {
                let t = sorted[j]
                let overlap = min(e, t.end) - max(s, t.start)
                let distance = max(t.start - e, s - t.end, 0)
                if distance <= reach, best == nil || overlap > best!.overlap { best = (overlap, distance, t.voice) }
                j += 1
            }
            out.append(best?.voice)
        }
        return out
    }

    /// Starts a new paragraph wherever the voice changes, and names each paragraph's
    /// speaker from `names` (voice → name). Words with no voice keep the voice of the
    /// word before them in the paragraph; a paragraph with no voiced word keeps its
    /// speaker. Zoom-only paragraphs are untouched. Paragraphs are never merged, so
    /// clip and omission markers stay on their words.
    public mutating func applyVoices(_ voiceOfWord: [String?], names: [String: String]) {
        precondition(voiceOfWord.count == words.count)
        var byParagraph: [ParagraphID: [Int]] = [:]
        for (i, w) in words.enumerated() { byParagraph[w.paragraph, default: []].append(i) }
        var nextID = (paragraphs.map(\.id.raw).max() ?? 0) + 1
        var newParagraphs: [Paragraph] = []
        var newWords = words
        for p in paragraphs {
            let idx = byParagraph[p.id] ?? []
            guard !p.zoomOnly, !idx.isEmpty else { newParagraphs.append(p); continue }
            // Runs of one voice; a leading unvoiced stretch joins the first voiced run.
            var runs: [(voice: String?, words: [Int])] = []
            for i in idx {
                let v = voiceOfWord[i]
                if let last = runs.last, v == nil || v == last.voice || last.voice == nil {
                    runs[runs.count - 1].words.append(i)
                    if last.voice == nil { runs[runs.count - 1].voice = v }
                } else {
                    runs.append((v, [i]))
                }
            }
            for (n, run) in runs.enumerated() {
                var q = p
                if n > 0 { q.id = ParagraphID(nextID); nextID += 1 }
                if let v = run.voice { q.speaker = Self.speakerName(names[v]) }
                for i in run.words { newWords[i].paragraph = q.id }
                newParagraphs.append(q)
            }
        }
        paragraphs = newParagraphs
        words = newWords
        for name in paragraphs.compactMap(\.speaker) { addSpeaker(name) }
        normalizeSpeakers()
    }

    /// A trimmed speaker name, or nil when blank.
    static func speakerName(_ name: String?) -> String? {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}

/// Roster text as typed on the command line or in the app.
public enum Roster {
    /// "Mia Minnes, Kathy, Ori" → names, trimmed, blanks and repeats dropped.
    public static func parse(_ s: String) -> [String] {
        var out: [String] = []
        for part in s.split(separator: ",") {
            let n = part.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty, !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// `Speaker 3`: a name made up for a voice nobody recognised, not a real one.
    public static func isPlaceholder(_ name: String) -> Bool {
        let n = name.dropFirst("Speaker ".count)
        return name.hasPrefix("Speaker ") && !n.isEmpty && n.allSatisfy(\.isNumber)
    }
}
