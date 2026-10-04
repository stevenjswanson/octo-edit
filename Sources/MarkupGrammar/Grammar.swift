import Foundation
import Core

/// Everything both the reader (Load) and writer (Save) must agree on:
/// file names, the transcript.md syntax, and the words.tsv / waveform.bin encodings.
public enum PackageLayout {
    public static let transcript = "transcript.md"
    public static let words = "words.tsv"
    public static let cacheDir = "cache"
    public static let waveform = "cache/waveform.bin"
    public static let exportsDir = "exports"
    public static let gitignore = ".gitignore"
    public static let gitignoreContents = "cache/\nexports/\n"
    public static let formatVersion = 1
}

public enum Grammar {
    public static let wrapWidth = 72
    public static let frontMatterFence = "---"
    public static let fence = "~~"
    public static let zoomPrefix = "> "
    public static let noteIndent = "    "

    // MARK: Times and offsets

    /// `hh:mm:ss.d` (tenths, truncated so a header never claims a time after its first word).
    public static func timestamp(_ t: Seconds) -> String {
        let tenths = Int((max(t, 0) * 10).rounded(.down))
        let h = tenths / 36000, m = (tenths / 600) % 60, s = (tenths / 10) % 60, d = tenths % 10
        return String(format: "%02d:%02d:%02d.%d", h, m, s, d)
    }

    public static func parseTimestamp(_ s: Substring) -> Seconds? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Signed whole milliseconds: `+40ms`, `-120ms`.
    public static func offset(_ s: Seconds) -> String {
        let ms = Int((s * 1000).rounded())
        return ms >= 0 ? "+\(ms)ms" : "\(ms)ms"
    }

    /// Unsigned milliseconds for durations in front matter: `120ms`.
    public static func duration(_ s: Seconds) -> String { "\(Int((s * 1000).rounded()))ms" }

    /// Parses `+40ms`, `-120ms`, `40ms`.
    public static func parseMilliseconds<S: StringProtocol>(_ text: S) -> Seconds? {
        guard text.hasSuffix("ms") else { return nil }
        let body = text.dropLast(2)
        guard !body.isEmpty, let v = Int(body) else { return nil }
        return Double(v) / 1000
    }

    // MARK: Line patterns

    nonisolated(unsafe) public static let paragraphHeader = /^\[(\d{2}:\d{2}:\d{2}\.\d)\](?:\s+\*\*(.+):\*\*)?\s*$/
    nonisolated(unsafe) public static let zoomHeader = /^>\s?\((\d{2}:\d{2}:\d{2}\.\d)\)(?:\s+\*\*(.+):\*\*)?\s*$/
    nonisolated(unsafe) public static let noteDefinition = /^\[\^([^\]\s]+)\]:\s?(.*)$/

    public static func paragraphHeaderLine(time: Seconds, speaker: String?) -> String {
        "[\(timestamp(time))]" + (speaker.map { " **\($0):**" } ?? "")
    }

    public static func zoomHeaderLine(time: Seconds, speaker: String?) -> String {
        "> (\(timestamp(time)))" + (speaker.map { " **\($0):**" } ?? "")
    }

    // MARK: Markers

    public static func clipOpen(name: String?, offset: Seconds?) -> String {
        var s = "{clip"
        if let name { s += " \"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        if let offset { s += " " + Self.offset(offset) }
        return s + "}"
    }

    public static func clipClose(offset: Seconds?) -> String {
        "{/clip" + (offset.map { " " + Self.offset($0) } ?? "") + "}"
    }

    public static func offsetMarker(_ s: Seconds) -> String { "{" + offset(s) + "}" }

    public static func noteReference(_ key: String) -> String { "[^\(key)]" }
}

/// Body-text tokens of transcript.md.
public enum Token: Equatable, Sendable {
    case word(String)
    case clipOpen(name: String?, offset: Seconds?)
    case clipClose(offset: Seconds?)
    case fence
    case offset(Seconds)
    case noteReference(String)
    case invalid(String)
}

public enum Lexer {
    /// Splits one line of body text into tokens.
    public static func tokens(_ line: Substring) -> [Token] {
        var out: [Token] = []
        var i = line.startIndex
        func starts(_ p: String, at k: Substring.Index) -> Bool { line[k...].hasPrefix(p) }
        while i < line.endIndex {
            let c = line[i]
            if c == " " || c == "\t" { i = line.index(after: i); continue }
            if starts("~~", at: i) {
                out.append(.fence)
                i = line.index(i, offsetBy: 2)
            } else if c == "{" {
                guard let close = closingBrace(in: line, from: i) else {
                    out.append(.invalid(String(line[i...])))
                    break
                }
                out.append(marker(line[line.index(after: i)..<close]))
                i = line.index(after: close)
            } else if starts("[^", at: i), let close = line[i...].firstIndex(of: "]") {
                out.append(.noteReference(String(line[line.index(i, offsetBy: 2)..<close])))
                i = line.index(after: close)
            } else {
                var j = i
                while j < line.endIndex, line[j] != " ", line[j] != "\t", line[j] != "{",
                      !starts("~~", at: j), !starts("[^", at: j) {
                    j = line.index(after: j)
                }
                out.append(.word(String(line[i..<j])))
                i = j
            }
        }
        return out
    }

    /// Index of the `}` closing the marker at `start`, honouring quoted names.
    private static func closingBrace(in line: Substring, from start: Substring.Index) -> Substring.Index? {
        var inQuote = false
        var escaped = false
        var k = line.index(after: start)
        while k < line.endIndex {
            let ch = line[k]
            if escaped { escaped = false }
            else if ch == "\\" && inQuote { escaped = true }
            else if ch == "\"" { inQuote.toggle() }
            else if ch == "}" && !inQuote { return k }
            k = line.index(after: k)
        }
        return nil
    }

    private static func marker(_ body: Substring) -> Token {
        let text = body.trimmingCharacters(in: .whitespaces)
        if text == "/clip" || text.hasPrefix("/clip ") {
            let rest = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return .clipClose(offset: nil) }
            if let o = Grammar.parseMilliseconds(rest) { return .clipClose(offset: o) }
            return .invalid("{\(body)}")
        }
        if text == "clip" || text.hasPrefix("clip ") {
            var rest = Substring(text.dropFirst(4)).drop { $0 == " " }
            var name: String?
            if rest.first == "\"" {
                var value = ""
                var k = rest.index(after: rest.startIndex)
                var escaped = false
                var closed = false
                while k < rest.endIndex {
                    let ch = rest[k]
                    if escaped { value.append(ch); escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { closed = true; break }
                    else { value.append(ch) }
                    k = rest.index(after: k)
                }
                guard closed else { return .invalid("{\(body)}") }
                name = value
                rest = rest[rest.index(after: k)...].drop { $0 == " " }
            }
            if rest.isEmpty { return .clipOpen(name: name, offset: nil) }
            if let o = Grammar.parseMilliseconds(rest) { return .clipOpen(name: name, offset: o) }
            return .invalid("{\(body)}")
        }
        if let o = Grammar.parseMilliseconds(text), text.first == "+" || text.first == "-" {
            return .offset(o)
        }
        return .invalid("{\(body)}")
    }
}

// MARK: - words.tsv

public enum WordsTSV {
    public static let header = "start\tend\tconfidence\ttext"

    public static func encode(_ words: [TimedWord]) -> String {
        var s = header + "\n"
        for w in words {
            let conf = w.confidence.map { String(format: "%.2f", $0) } ?? "-"
            s += String(format: "%.3f\t%.3f\t", w.start, w.end) + conf + "\t" + w.text + "\n"
        }
        return s
    }

    public struct DecodeError: Error, CustomStringConvertible {
        public let line: Int
        public var description: String { "\(PackageLayout.words) line \(line): malformed row" }
    }

    public static func decode(_ text: String) throws -> [TimedWord] {
        var out: [TimedWord] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || (n == 0 && line.hasPrefix("start")) { continue }
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let a = Double(f[0]), let b = Double(f[1]) else { throw DecodeError(line: n + 1) }
            out.append(TimedWord(text: String(f[3]), start: a, end: b, confidence: Double(f[2])))
        }
        return out
    }
}

// MARK: - waveform.bin

public enum WaveformFile {
    static let magic: [UInt8] = Array("OCTW".utf8)

    public static func encode(_ e: Envelope) -> Data {
        var d = Data(magic)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt32(1))
        put(e.bucketsPerSecond.bitPattern)
        put(UInt32(e.rms.count))
        for v in e.rms { put(v.bitPattern) }
        return d
    }

    public static func decode(_ d: Data) -> Envelope? {
        let bytes = [UInt8](d)
        guard bytes.count >= 20, Array(bytes[0..<4]) == magic else { return nil }
        func get<T: FixedWidthInteger>(_: T.Type, _ at: Int) -> T {
            var v: T = 0
            for k in 0..<MemoryLayout<T>.size { v |= T(bytes[at + k]) << (8 * k) }
            return v
        }
        guard get(UInt32.self, 4) == 1 else { return nil }
        let bps = Double(bitPattern: get(UInt64.self, 8))
        let n = Int(get(UInt32.self, 16))
        guard bytes.count >= 20 + 4 * n else { return nil }
        let rms = (0..<n).map { Float(bitPattern: get(UInt32.self, 20 + 4 * $0)) }
        return Envelope(bucketsPerSecond: bps, rms: rms)
    }
}
