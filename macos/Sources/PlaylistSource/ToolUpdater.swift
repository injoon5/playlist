import Foundation

/// `yt-dlp --version` and "Update yt-dlp" (YouTube changes often break old yt-dlp releases).
public enum ToolUpdater {
    /// The installed yt-dlp's version, or a `ToolProblem.broken` if it doesn't run
    /// (e.g. a stale pyenv shim).
    public static func ytDlpVersion(_ tools: ToolPaths) async throws -> String {
        guard let ytDlp = tools.ytDlp else { throw ToolProblem.missing([.ytDlp]) }
        let result: ProcessResult
        do {
            result = try await ChildProcess.run(ytDlp, ["--version"], environment: tools.environment, timeout: .seconds(20))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolProblem.broken(.ytDlp, error.localizedDescription)
        }
        let version = result.lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        guard result.status == 0, !result.timedOut, !version.isEmpty else {
            throw ToolProblem.broken(.ytDlp, result.timedOut ? "it didn’t answer within 20 seconds" : (version.isEmpty ? "exit status \(result.status)" : version))
        }
        return version.trimmingCharacters(in: .whitespaces)
    }

    public struct Command: Equatable, Sendable {
        public var executable: URL
        public var arguments: [String]
        public var display: String { ([executable.lastPathComponent] + arguments).joined(separator: " ") }
    }

    /// `brew upgrade yt-dlp` for a Homebrew install (its self-updater refuses
    /// to touch those), otherwise `yt-dlp -U`.
    public static func updateCommand(
        for ytDlp: URL,
        resolve: (URL) -> URL = { $0.resolvingSymlinksInPath() },
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Command {
        let real = resolve(ytDlp).path
        let isHomebrew = real.contains("/Cellar/yt-dlp/") || real.hasPrefix("/opt/homebrew/")
        if isHomebrew {
            let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: isExecutable)
            if let brew { return Command(executable: URL(fileURLWithPath: brew), arguments: ["upgrade", "yt-dlp"]) }
        }
        return Command(executable: ytDlp, arguments: ["-U"])
    }

    /// Runs the update and returns its last line of output.
    public static func updateYtDlp(_ tools: ToolPaths) async throws -> String {
        guard let ytDlp = tools.ytDlp else { throw ToolProblem.missing([.ytDlp]) }
        let command = updateCommand(for: ytDlp)
        let result = try await ChildProcess.run(
            command.executable, command.arguments, environment: tools.environment, timeout: .seconds(600)
        )
        let last = result.lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        guard result.status == 0 else {
            throw UpdateError(message: "\(command.display) failed: \(last.isEmpty ? "exit status \(result.status)" : last)")
        }
        return last
    }

    public struct UpdateError: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }
}
