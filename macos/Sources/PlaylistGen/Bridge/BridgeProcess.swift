import Foundation

/// One invocation of the Python bridge. Delivers parsed stdout messages and
/// stderr lines on the main actor, and supports cooperative cancel (a
/// "cancel" line on stdin) with a hard SIGTERM fallback.
@MainActor
final class BridgeProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private var cancelRequested = false
    private var killTask: Task<Void, Never>?

    init(environment: ToolEnvironment, arguments: [String]) {
        let command = environment.bridgeCommand(arguments)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = environment.projectRoot
        process.environment = environment.environment
        process.standardInput = stdinPipe
    }

    var isRunning: Bool { process.isRunning }

    /// Runs the bridge to completion and returns its exit status.
    func run(
        input: Data? = nil,
        onMessage: @escaping @MainActor @Sendable (BridgeMessage) -> Void,
        onLog: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Int32 {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()
        if let input {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
        }

        async let out: Void = Self.readLines(stdout.fileHandleForReading) { line in
            if let message = BridgeMessage.parse(line) {
                onMessage(message)
            } else if !line.isEmpty {
                onLog(line)
            }
        }
        async let err: Void = Self.readLines(stderr.fileHandleForReading) { line in
            onLog(line)
        }
        _ = await (out, err)

        var status: Int32 = -1
        for await code in exitStream { status = code }
        killTask?.cancel()
        try? stdinPipe.fileHandleForWriting.close()
        return status
    }

    /// Ask the pipeline to stop; force-terminate if it hasn't exited after `grace`.
    func requestCancel(grace: Duration = .seconds(10)) {
        guard process.isRunning, !cancelRequested else { return }
        cancelRequested = true
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("cancel\n".utf8))
        killTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.terminate()
        }
    }

    /// SIGTERM. The run bridge treats it as a cancel; other commands just exit.
    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Delivers each line as soon as it arrives. (`FileHandle.bytes.lines`
    /// buffers pipe reads in large chunks, which held back progress updates.)
    private nonisolated static func readLines(
        _ handle: FileHandle,
        _ body: @escaping @MainActor @Sendable (String) -> Void
    ) async {
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let splitter = LineSplitter()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                if let tail = splitter.flush() { continuation.yield(tail) }
                continuation.finish()
            } else {
                for line in splitter.append(data) { continuation.yield(line) }
            }
        }
        for await line in lines {
            await body(line)
        }
    }
}

/// Splits a byte stream into UTF-8 lines (\n or \r, so yt-dlp-style
/// carriage-return progress shows up too). Only touched from one
/// readability-handler queue at a time.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        return lines
    }

    func flush() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}
