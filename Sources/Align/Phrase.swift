import Foundation
import Core

extension Project {
    /// Indices of the words where `phrase` starts within `range`, comparing words the
    /// way the aligner does (case and punctuation ignored): "um because I tell" finds
    /// "Um, because I tell".
    public func occurrences(of phrase: String, in range: ClosedRange<Int>) -> [Int] {
        let wanted = phrase.split(whereSeparator: { $0.isWhitespace }).map { Aligner.normalize(String($0)) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty, range.count >= wanted.count else { return [] }
        let have = range.map { Aligner.normalize(words[$0].text) }
        return (0...(have.count - wanted.count)).filter { Array(have[$0..<($0 + wanted.count)]) == wanted }
            .map { range.lowerBound + $0 }
    }
}
