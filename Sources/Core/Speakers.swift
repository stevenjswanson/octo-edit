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

    /// A trimmed speaker name, or nil when blank.
    static func speakerName(_ name: String?) -> String? {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}
