import Foundation
import Core

extension Project {
    /// Replaces a paragraph's words with `tokens` — a text correction typed by the user.
    ///
    /// - Words that still match (case- and punctuation-insensitive) keep their id and
    ///   timing; only their text changes.
    /// - New or changed words take their timing from the words they replace, as Load
    ///   does for hand edits (a word typed into silence gets none).
    /// - A clip or omission edge on a removed word moves to the nearest word on its
    ///   side; segments that collapse are dropped, and an omission whose words were
    ///   all removed disappears.
    public mutating func replaceText(ofParagraph pid: ParagraphID, with tokens: [String]) throws {
        guard !tokens.isEmpty else { throw EditError.emptyParagraph }
        guard let lo = words.firstIndex(where: { $0.paragraph == pid }) else { throw EditError.invalidRange }
        var hi = lo
        while hi + 1 < words.count, words[hi + 1].paragraph == pid { hi += 1 }
        let old = Array(words[lo...hi])
        guard old.map(\.text) != tokens else { return }

        let pairs = Aligner.matches(old.map { Aligner.normalize($0.text) }, tokens.map(Aligner.normalize))
        let oldTimed = old.compactMap { w -> TimedWord? in
            guard let s = w.start, let e = w.end else { return nil }
            return TimedWord(text: w.text, start: s, end: e, confidence: w.confidence)
        }
        let times = Aligner.transferTimes(texts: tokens, timed: oldTimed)

        // New words: matched ones keep their old identity and timing.
        var newFor = [Int: Int]()           // old local index → new local index (matched)
        for (i, j) in pairs { newFor[i] = j }
        var oldFor = [Int: Int]()
        for (i, j) in pairs { oldFor[j] = i }
        var nextID = (words.map(\.id.raw).max() ?? 0) + 1
        let replacement: [Word] = tokens.enumerated().map { j, text in
            if let i = oldFor[j] {
                var w = old[i]
                w.text = text
                return w
            }
            defer { nextID += 1 }
            return Word(id: WordID(nextID), text: text, start: times[j]?.start, end: times[j]?.end,
                        confidence: times[j]?.confidence, paragraph: pid)
        }

        // Where a removed word's boundaries go: an in-point to the first new word after
        // the last surviving word before it; an out-point to the last new word before
        // the first surviving word after it. An edge never crosses a surviving word: if
        // nothing is left on its side within the paragraph it moves into the neighbouring
        // paragraph (or the segment is dropped).
        let wordBefore = lo > 0 ? words[lo - 1].id : nil
        let wordAfter = hi + 1 < words.count ? words[hi + 1].id : nil
        let oldIndex = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1.id, $0) })
        func remap(_ b: Boundary, inPoint: Bool) -> Boundary? {
            guard let i = oldIndex[b.word] else { return b }
            if let j = newFor[i] { return Boundary(word: replacement[j].id, offset: b.offset) }
            // Measured from a word that's gone: the offset goes too.
            if inPoint {
                let j = (pairs.last { $0.0 < i }?.1 ?? -1) + 1
                if j < tokens.count { return Boundary(word: replacement[j].id) }
                return wordAfter.map { Boundary(word: $0) }
            }
            let j = (pairs.first { $0.0 > i }?.1 ?? tokens.count) - 1
            if j >= 0 { return Boundary(word: replacement[j].id) }
            return wordBefore.map { Boundary(word: $0) }
        }
        for c in clips.indices {
            clips[c].segments = clips[c].segments.compactMap {
                guard let a = remap($0.inPoint, inPoint: true), let b = remap($0.outPoint, inPoint: false) else { return nil }
                return Segment(inPoint: a, outPoint: b)
            }
        }

        var all = words
        all.replaceSubrange(lo...hi, with: replacement)
        words = all

        // Drop collapsed segments; merge segments whose omission vanished; drop empty clips.
        for c in clips.indices {
            var segs: [Segment] = []
            for seg in clips[c].segments {
                guard let r = indexRange(of: seg) else { continue }
                if let last = segs.last, let lr = indexRange(of: last), r.lowerBound <= lr.upperBound + 1 {
                    if r.upperBound > lr.upperBound { segs[segs.count - 1].outPoint = seg.outPoint }
                    continue
                }
                segs.append(seg)
            }
            clips[c].segments = segs
        }
        clips.removeAll { $0.segments.isEmpty }
    }
}
