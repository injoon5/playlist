import Foundation
import Synchronization

/// Output of a finished child process (stdout and stderr interleaved, split into lines).
public struct ProcessResult: Sendable {
    public var status: Int32
    public var lines: [String]
    public var timedOut: Bool
}

public enum ChildProcessError: LocalizedError {
    case launchFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let reason): return "Couldn’t run \(path): \(reason)"
        }
    }
}

/// Runs command-line tools (yt-dlp, ffprobe, brew) with line-by-line output.
///
/// Each child is its own process-group leader (Foundation's `Process` does
/// that on macOS), so stopping one signals the whole group: yt-dlp and the
/// ffmpeg / deno processes it starts. Task cancellation sends SIGTERM, then
/// SIGKILL after a short grace period. Every live child is also listed in
/// `ProcessRegistry.shared` so the app can kill them all when it quits.
public enum ChildProcess {
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil,
        maxLines: Int = 2000,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let (lines, lineContinuation) = AsyncStream<String>.makeStream()
        let splitter = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let tail = splitter.flush() { lineContinuation.yield(tail) }
                lineContinuation.finish()
            } else {
                for line in splitter.append(data) { lineContinuation.yield(line) }
            }
        }
        let exit = ExitWaiter()
        let registry = ProcessRegistry.shared
        process.terminationHandler = { finished in
            registry.unregister(finished.processIdentifier)
            exit.finish(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            lineContinuation.finish()
            throw ChildProcessError.launchFailed(executable.path, error.localizedDescription)
        }
        let pid = process.processIdentifier
        registry.register(pid)

        let timedOut = Mutex(false)
        let watchdog: Task<Void, Never>? = timeout.map { limit in
            Task.detached {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                timedOut.withLock { $0 = true }
                registry.stop(pid)
            }
        }
        defer { watchdog?.cancel() }

        let result = await withTaskCancellationHandler {
            var collected: [String] = []
            for await line in lines {
                onLine?(line)
                collected.append(line)
                if collected.count > maxLines { collected.removeFirst(collected.count - maxLines) }
            }
            // Not cancellable on purpose: after a cancel this waits for the
            // SIGTERM (or, after the grace period, SIGKILL) to land.
            let status = await exit.wait()
            return ProcessResult(status: status, lines: collected, timedOut: timedOut.withLock { $0 })
        } onCancel: {
            registry.stop(pid)
        }
        try Task.checkCancellation()
        return result
    }
}

/// One-shot exit status, awaitable once (ignores task cancellation).
private final class ExitWaiter: Sendable {
    private enum State {
        case running
        case waiting(CheckedContinuation<Int32, Never>)
        case exited(Int32)
    }
    private let state = Mutex(State.running)

    func finish(_ status: Int32) {
        let waiter: CheckedContinuation<Int32, Never>? = state.withLock { state in
            defer { state = .exited(status) }
            if case .waiting(let c) = state { return c }
            return nil
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done: Int32? = state.withLock { state in
                if case .exited(let status) = state { return status }
                state = .waiting(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}

/// Live child processes, so they can be stopped together (e.g. on quit).
public final class ProcessRegistry: Sendable {
    public static let shared = ProcessRegistry()
    private let pids = Mutex<Set<pid_t>>([])

    func register(_ pid: pid_t) {
        pids.withLock { _ = $0.insert(pid) }
    }

    func unregister(_ pid: pid_t) {
        pids.withLock { _ = $0.remove(pid) }
    }

    func isRunning(_ pid: pid_t) -> Bool {
        pids.withLock { $0.contains(pid) }
    }

    public var runningCount: Int { pids.withLock { $0.count } }

    /// SIGTERM the process group now, SIGKILL it if it's still around after `grace`.
    func stop(_ pid: pid_t, grace: Duration = .seconds(3)) {
        guard isRunning(pid) else { return }
        Self.signal(pid, SIGTERM)
        Task.detached { [self] in
            try? await Task.sleep(for: grace)
            if isRunning(pid) { Self.signal(pid, SIGKILL) }
        }
    }

    /// Kill every child immediately (app quit).
    public func killAll() {
        let all = pids.withLock { $0 }
        for pid in all { Self.signal(pid, SIGKILL) }
    }

    private static func signal(_ pid: pid_t, _ sig: Int32) {
        if killpg(pid, sig) != 0 { kill(pid, sig) }
    }
}

/// Splits a byte stream into UTF-8 lines on \n or \r. Only used from one
/// readability-handler callback at a time; the lock keeps that honest.
final class LineSplitter: Sendable {
    private let buffer = Mutex(Data())

    func append(_ data: Data) -> [String] {
        buffer.withLock { buffer in
            buffer.append(data)
            var lines: [String] = []
            while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            return lines
        }
    }

    func flush() -> String? {
        buffer.withLock { buffer in
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
    }
}
