import Foundation

/// Where the Python project lives, which `uv` to run it with, and the
/// environment child processes get. GUI apps launch with a minimal PATH, so
/// Homebrew / ~/.local/bin are added explicitly (ffmpeg, deno, uv live there).
struct ToolEnvironment: Sendable, Equatable {
    var projectRoot: URL
    var uv: URL
    var environment: [String: String]

    static let rootOverrideKey = "projectRootOverride"
    static let uvOverrideKey = "uvPathOverride"
    /// Written into Info.plist by build-app.sh.
    static let bundledRootKey = "PlaylistGenProjectRoot"

    enum ResolveError: LocalizedError {
        case projectNotFound(String?)
        case uvNotFound

        var errorDescription: String? {
            switch self {
            case .projectNotFound(let tried?):
                return "No playlist-gen project at \(tried). Choose the repository folder in Settings."
            case .projectNotFound(nil):
                return "Couldn't find the playlist-gen project. Choose the repository folder in Settings."
            case .uvNotFound:
                return "Couldn't find uv. Install it (https://docs.astral.sh/uv/) or set its path in Settings."
            }
        }
    }

    static func resolve(defaults: UserDefaults = .standard) throws -> ToolEnvironment {
        let root = try resolveProjectRoot(defaults: defaults)
        let uv = try resolveUV(defaults: defaults)
        return ToolEnvironment(projectRoot: root, uv: uv, environment: childEnvironment(uv: uv))
    }

    /// `uv run --project <root> python -m playlist_video.bridge <args…>`
    func bridgeCommand(_ arguments: [String]) -> (executable: URL, arguments: [String]) {
        (uv, ["run", "--project", projectRoot.path, "python", "-m", "playlist_video.bridge"] + arguments)
    }

    var defaultOutputPath: String {
        projectRoot.appending(path: "output/playlist_video.mp4").path
    }

    // MARK: - Resolution

    static func isProjectRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appending(path: "pyproject.toml").path)
            && fm.fileExists(atPath: url.appending(path: "playlist_video/bridge.py").path)
    }

    private static func resolveProjectRoot(defaults: UserDefaults) throws -> URL {
        if let override = defaults.string(forKey: rootOverrideKey), !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard isProjectRoot(url) else { throw ResolveError.projectNotFound(url.path) }
            return url
        }
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PLAYLIST_GEN_ROOT"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: bundledRootKey) as? String {
            candidates.append(URL(fileURLWithPath: bundled))
        }
        // `swift run` from macos/, or an app bundle built inside the repo.
        candidates += ancestors(of: Bundle.main.bundleURL)
        candidates += ancestors(of: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if let found = candidates.first(where: isProjectRoot) {
            return found.standardizedFileURL
        }
        throw ResolveError.projectNotFound(nil)
    }

    private static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while current.path != "/" {
            result.append(current)
            current = current.deletingLastPathComponent()
        }
        return result
    }

    private static func resolveUV(defaults: UserDefaults) throws -> URL {
        let fm = FileManager.default
        if let override = defaults.string(forKey: uvOverrideKey), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path) else { throw ResolveError.uvNotFound }
            return URL(fileURLWithPath: path)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = extraPathDirs + pathDirs
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent("uv")
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        throw ResolveError.uvNotFound
    }

    private static var extraPathDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.deno/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    private static func childEnvironment(uv: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var dirs: [String] = [uv.deletingLastPathComponent().path]
        for dir in extraPathDirs + existing where !dirs.contains(dir) {
            dirs.append(dir)
        }
        env["PATH"] = dirs.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        // Don't let an activated venv from the launching shell leak in.
        env.removeValue(forKey: "VIRTUAL_ENV")
        return env
    }
}
