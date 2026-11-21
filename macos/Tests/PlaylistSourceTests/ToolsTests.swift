import Foundation
import Testing
@testable import PlaylistSource

@Suite("Tool discovery")
struct ToolDiscoveryTests {
    /// A locator over a fake file system containing exactly `executables`.
    func locator(
        _ executables: Set<String>, path: String = "/usr/bin:/bin:/custom/bin",
        overrides: [Tool: String] = [:], roots: [URL] = []
    ) -> ToolLocator {
        ToolLocator(
            home: "/Users/me", pathVariable: path, overrides: overrides, projectRoots: roots,
            baseEnvironment: ["PATH": path, "VIRTUAL_ENV": "/somewhere/.venv", "HOME": "/Users/me"],
            isExecutable: { executables.contains($0) }
        )
    }

    @Test func precedenceOrder() {
        let everywhere: Set<String> = [
            "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/Users/me/.local/bin/yt-dlp",
            "/Users/me/.pyenv/shims/yt-dlp", "/custom/bin/yt-dlp", "/repo/.venv/bin/yt-dlp", "/picked/yt-dlp",
        ]
        let roots = [URL(fileURLWithPath: "/repo")]
        func found(_ files: Set<String>, overrides: [Tool: String] = [:]) -> LocatedTool? {
            locator(files, overrides: overrides, roots: roots).locate().located[.ytDlp]
        }
        #expect(found(everywhere, overrides: [.ytDlp: "/picked/yt-dlp"])?.source == .override)
        #expect(found(everywhere)?.path == "/opt/homebrew/bin/yt-dlp")
        var files = everywhere.subtracting(["/opt/homebrew/bin/yt-dlp"])
        #expect(found(files)?.path == "/usr/local/bin/yt-dlp")
        files.remove("/usr/local/bin/yt-dlp")
        #expect(found(files) == LocatedTool(url: URL(fileURLWithPath: "/Users/me/.local/bin/yt-dlp"), source: .userDirectory))
        files.remove("/Users/me/.local/bin/yt-dlp")
        #expect(found(files)?.source == .pyenv)
        files.remove("/Users/me/.pyenv/shims/yt-dlp")
        #expect(found(files)?.path == "/custom/bin/yt-dlp")
        files.remove("/custom/bin/yt-dlp")
        #expect(found(files) == LocatedTool(url: URL(fileURLWithPath: "/repo/.venv/bin/yt-dlp"), source: .projectVenv))
        files.remove("/repo/.venv/bin/yt-dlp")
        #expect(found(files) == nil)
    }

    @Test func venvIsOnlyAFallbackForYtDlp() {
        let tools = locator(["/repo/.venv/bin/yt-dlp", "/repo/.venv/bin/ffmpeg"], roots: [URL(fileURLWithPath: "/repo")]).locate()
        #expect(tools.ytDlp?.path == "/repo/.venv/bin/yt-dlp")
        #expect(tools.ffmpeg == nil)
        #expect(tools.problem == .missing([.ffmpeg]))
    }

    @Test func missingAndInvalidOverrides() {
        let none = locator([]).locate()
        #expect(none.problem == .missing([.ytDlp, .ffmpeg]))
        #expect(none.problem?.localizedDescription.contains("brew install yt-dlp ffmpeg deno") == true)

        let bad = locator(["/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg"], overrides: [.ytDlp: "/nope/yt-dlp"]).locate()
        #expect(bad.ytDlp == nil)
        #expect(bad.problem == .invalidOverride(.ytDlp, "/nope/yt-dlp"))

        let ok = locator(["/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg"]).locate()
        #expect(ok.problem == nil)
        #expect(ok.jsRuntime == nil)  // deno/node are optional
    }

    @Test func ffprobeComesFromNextToFFmpeg() {
        let tools = locator(
            ["/opt/homebrew/bin/ffprobe", "/tools/ff/ffmpeg", "/tools/ff/ffprobe", "/opt/homebrew/bin/yt-dlp"],
            overrides: [.ffmpeg: "/tools/ff/ffmpeg"]
        ).locate()
        #expect(tools.ffmpeg?.path == "/tools/ff/ffmpeg")
        #expect(tools.ffprobe?.path == "/tools/ff/ffprobe")
    }

    @Test func nodeStandsInForDeno() {
        let tools = locator(["/usr/local/bin/node"]).locate()
        #expect(tools.jsRuntime?.path == "/usr/local/bin/node")
        #expect(YTDLP.JSRuntimes(tools) == YTDLP.JSRuntimes(deno: nil, node: "/usr/local/bin/node"))
    }

    @Test func childPATHLeadsWithToolFolders() throws {
        let tools = locator(
            ["/Users/me/.local/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg", "/Users/me/.deno/bin/deno"],
            path: "/usr/bin:/bin"
        ).locate()
        let dirs = try #require(tools.environment["PATH"]).split(separator: ":").map(String.init)
        #expect(Array(dirs.prefix(3)) == ["/Users/me/.local/bin", "/opt/homebrew/bin", "/Users/me/.deno/bin"])
        #expect(dirs.contains("/usr/bin") && dirs.contains("/usr/local/bin"))
        #expect(Set(dirs).count == dirs.count)
        #expect(tools.environment["VIRTUAL_ENV"] == nil)
        #expect(tools.environment["PYTHONIOENCODING"] == "utf-8")
        #expect(tools.environment["HOME"] == "/Users/me")
    }

    @Test func updateCommandDependsOnInstall() {
        let brew = ToolUpdater.updateCommand(
            for: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            resolve: { _ in URL(fileURLWithPath: "/opt/homebrew/Cellar/yt-dlp/2026.07.04/bin/yt-dlp") },
            isExecutable: { $0 == "/opt/homebrew/bin/brew" }
        )
        #expect(brew.display == "brew upgrade yt-dlp")
        let standalone = ToolUpdater.updateCommand(
            for: URL(fileURLWithPath: "/Users/me/.local/bin/yt-dlp"), resolve: { $0 }, isExecutable: { _ in true }
        )
        #expect(standalone.display == "yt-dlp -U")
        #expect(standalone.executable.path == "/Users/me/.local/bin/yt-dlp")
    }
}

@Suite("Child processes")
struct ChildProcessTests {
    @Test func collectsLinesAndStatus() async throws {
        let seen = LinesBox()
        let result = try await ChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo one; printf 'two\\rthree\\n'; echo err >&2; exit 3"]
        ) { seen.append($0) }
        #expect(result.status == 3)
        #expect(result.lines == ["one", "two", "three", "err"])
        #expect(seen.lines == result.lines)
    }

    @Test func cancellationStopsTheProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "pg-\(UUID().uuidString)")
        // The child starts a grandchild (like yt-dlp starting ffmpeg); both must stop.
        let task = Task {
            try await ChildProcess.run(
                URL(fileURLWithPath: "/bin/sh"),
                ["-c", "sleep 30 & echo $! > '\(marker.path)'; wait"]
            )
        }
        var grandchild: pid_t?
        for _ in 0..<100 where grandchild == nil {
            try await Task.sleep(for: .milliseconds(20))
            grandchild = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let pid = try #require(grandchild)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(pid, 0) != 0, "grandchild \(pid) still running")
        try? FileManager.default.removeItem(at: marker)
    }

    @Test func timeoutStopsTheProcess() async throws {
        let result = try await ChildProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(ProcessRegistry.shared.runningCount >= 0)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: ChildProcessError.self) {
            try await ChildProcess.run(URL(fileURLWithPath: "/nonexistent/yt-dlp"), [])
        }
    }
}

final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
