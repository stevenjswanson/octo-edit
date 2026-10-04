import Foundation
import Core

/// Parses a Zoom transcript (.vtt). Speakers come from a leading `Name: ` or a
/// WebVTT `<v Name>` voice tag.
public enum ZoomVTT {
    public static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { continue }
            var body = lines[(timing + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            var speaker: String?
            if let m = body.firstMatch(of: /^<v\s+([^>]+)>\s*/) {
                speaker = String(m.1).trimmingCharacters(in: .whitespaces)
                body = String(body[m.range.upperBound...]).replacingOccurrences(of: "</v>", with: "")
            } else if let m = body.firstMatch(of: /^([^:]{1,60}):\s+/), !m.1.contains(where: \.isNumber) || m.1.contains(" ") {
                speaker = String(m.1).trimmingCharacters(in: .whitespaces)
                body = String(body[m.range.upperBound...])
            }
            body = body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            guard !body.isEmpty else { continue }
            cues.append(Cue(index: cues.count + 1, start: start, end: end, speaker: speaker, text: body))
        }
        return cues
    }

    /// `hh:mm:ss.mmm` or `mm:ss.mmm`.
    static func time(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count else { return nil }
        switch nums.count {
        case 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
        case 2: return nums[0] * 60 + nums[1]
        default: return nil
        }
    }
}
