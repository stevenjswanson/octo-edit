import Foundation
import Core

/// Runs a project's `post-export:` program on a staged export and puts its result in
/// place. The contract (documented in `octoedit render --help`, POST-EXPORT):
///
/// - The staged files are `<clip folder>/.unbranded/<base>.{mp4,timeline.json,vtt,md,still.jpg}`.
/// - The program is run directly (no shell), in the package folder, with the args'
///   placeholders filled in and `OCTOEDIT_*` variables set. `{output}` is a hidden
///   partial file beside the final one.
/// - Exit 0 with `{output}` written: it becomes `<clip folder>/<base>.mp4`, the sidecars
///   are copied up beside it and the stamp is written. Anything else is a failure, and
///   nothing appears under the final name.
/// - Cancelling sends SIGTERM and removes `{output}`.
public enum PostExportRunner {
    public struct Failure: Error, CustomStringConvertible {
        public var message: String
        /// Everything the program printed (stdout and stderr together).
        public var output: String
        public var description: String { message }
    }

    /// What `run` needs besides the file.
    public struct Context: Sendable {
        public var command: PostExport
        /// The .octoedit package: the working directory, and the base of a relative `run`.
        public var package: URL
        /// The export destination (`{exports}`).
        public var exports: URL
        public var framing: Framing
        public var resolution: Renderer.Resolution

        public init(command: PostExport, package: URL, exports: URL, framing: Framing, resolution: Renderer.Resolution) {
            self.command = command
            self.package = package
            self.exports = exports
            self.framing = framing
            self.resolution = resolution
        }
    }

    /// The program's path: `~` expanded, relative paths against the package.
    public static func executable(_ command: PostExport, package: URL) -> URL {
        let path = (command.run as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL
            : package.appendingPathComponent(path).standardizedFileURL
    }

    /// Why the program can't run, or nil if it can.
    public static func problem(_ command: PostExport, package: URL) -> String? {
        let exe = executable(command, package: package)
        if !FileManager.default.fileExists(atPath: exe.path) { return "\(command.name) not found at \(exe.path)" }
        if !FileManager.default.isExecutableFile(atPath: exe.path) { return "\(command.name) is not executable (chmod +x)" }
        if !command.writesOutput { return "the arguments have no {output}, so \(command.name) can't hand back a file" }
        return nil
    }

    /// Where the staged export's final video goes: the clip folder above `.unbranded/`.
    public static func finalFile(for staged: URL) -> URL {
        staged.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent)
    }

    static func partialFile(for final: URL) -> URL {
        final.deletingLastPathComponent().appendingPathComponent("." + final.deletingPathExtension().lastPathComponent + ".partial.mp4")
    }

    /// The args with placeholders filled in.
    public static func arguments(_ command: PostExport, staged: URL, output: URL, exports: URL) -> [String] {
        let base = staged.deletingPathExtension()
        let values = ["{timeline}": base.path + ".timeline.json", "{video}": staged.path,
                      "{output}": output.path, "{exports}": exports.path]
        return command.args.map { arg in values.reduce(arg) { $0.replacingOccurrences(of: $1.key, with: $1.value) } }
    }

    public static func environment(_ ctx: Context, slug: String, supercut: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Apps started from the Finder get a bare PATH; the usual tools live here.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        env["OCTOEDIT_PROJECT"] = ctx.package.path
        env["OCTOEDIT_EXPORTS"] = ctx.exports.path
        env["OCTOEDIT_FRAMING"] = ctx.framing.rawValue
        env["OCTOEDIT_QUALITY"] = ctx.resolution == .hd720 ? "720p" : "full"
        env["OCTOEDIT_SLUG"] = slug
        if supercut { env["OCTOEDIT_SUPERCUT"] = "1" }
        return env
    }

    /// Runs the program on a staged export and, if it succeeds, returns the export with
    /// its file moved to the final name. `line` gets each line the program prints.
    /// Throws `Failure`, or `CancellationError` if the task is cancelled.
    public static func run(_ staged: Renderer.Rendered, _ ctx: Context, supercut: Bool = false,
                           line: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Renderer.Rendered {
        if let problem = problem(ctx.command, package: ctx.package) { throw Failure(message: problem, output: "") }
        let final = finalFile(for: staged.file)
        let partial = partialFile(for: final)
        let fm = FileManager.default
        try? fm.removeItem(at: partial)

        let (status, output) = try await execute(executable(ctx.command, package: ctx.package),
                                                 arguments(ctx.command, staged: staged.file, output: partial, exports: ctx.exports),
                                                 environment: environment(ctx, slug: staged.slug, supercut: supercut),
                                                 directory: ctx.package, partial: partial, line: line)
        guard status == 0 else {
            try? fm.removeItem(at: partial)
            throw Failure(message: "\(ctx.command.name) failed (exit \(status))" + lastLine(output).map { ": \($0)" }.orEmpty, output: output)
        }
        guard fm.fileExists(atPath: partial.path) else {
            throw Failure(message: "\(ctx.command.name) exited without writing {output}", output: output)
        }
        if fm.fileExists(atPath: final.path) { _ = try fm.replaceItemAt(final, withItemAt: partial) }
        else { try fm.moveItem(at: partial, to: final) }
        // The captions, notes and timeline go beside it, as in a plain export.
        let base = staged.file.deletingPathExtension()
        for ext in ["timeline.json", "vtt", "md", "still.jpg"] {
            let from = URL(fileURLWithPath: base.path + "." + ext)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = final.deletingLastPathComponent().appendingPathComponent(from.lastPathComponent)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }
        if let stamp = staged.stamp { try ExportStamp.write(stamp, in: final.deletingLastPathComponent()) }
        var done = staged
        done.file = final
        done.stamp = nil
        return done
    }

    /// Removes a staged export's `.unbranded/` folder (after the batch, since a supercut
    /// is joined from the staged clips).
    public static func removeStaging(of staged: Renderer.Rendered) {
        let dir = staged.file.deletingLastPathComponent()
        guard dir.lastPathComponent == Renderer.stagingFolder else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Runs a process to completion, streaming its combined output. Cancellation sends
    /// SIGTERM, then SIGKILL two seconds later, and throws `CancellationError`.
    static func execute(_ exe: URL, _ args: [String], environment: [String: String], directory: URL, partial: URL,
                        line: @escaping @Sendable (String) -> Void) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputCollector(line: line)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { collected.append(data) }
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { k.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    k.resume(throwing: Failure(message: "couldn't start \(exe.lastPathComponent): \(error.localizedDescription)", output: ""))
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        collected.finish()
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: partial)
            throw CancellationError()
        }
        return (status, collected.text)
    }
}

/// Collects a process's output and splits it into lines (ffmpeg's `\r` progress
/// updates count as line ends).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let line: @Sendable (String) -> Void

    init(line: @escaping @Sendable (String) -> Void) { self.line = line }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        pending += String(decoding: chunk, as: UTF8.self)
        var lines: [String] = []
        while let r = pending.rangeOfCharacter(from: .newlines) {
            let l = String(pending[..<r.lowerBound])
            pending.removeSubrange(..<r.upperBound)
            if !l.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(l) }
        }
        lock.unlock()
        lines.forEach(line)
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { line(rest) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs jobs one at a time, in the order submitted, alongside whatever submits them
/// (so clip N's post-export step runs while clip N+1 encodes).
public actor SerialLane {
    private var last: Task<Void, Never>?
    private var cancellers: [@Sendable () -> Void] = []

    public init() {}

    /// Starts `job` after every job submitted before it has finished.
    public func submit<T: Sendable>(_ job: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = last
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await job()
        }
        last = Task { _ = try? await task.value }
        cancellers.append { task.cancel() }
        return task
    }

    /// Cancels every job submitted, running or waiting.
    public func cancelAll() { cancellers.forEach { $0() } }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
