import Foundation

/// The command-line tools the app runs.
public enum Tool: String, CaseIterable, Sendable {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case ffprobe
    case deno
    case node

    public var executableName: String { rawValue }

    /// UserDefaults key for a user-chosen path (Settings › Tools).
    public var overrideKey: String { "toolPath.\(rawValue)" }
}

/// Where a tool was found, for Settings.
public enum ToolSource: String, Sendable {
    case override = "Chosen in Settings"
    case homebrew = "Homebrew"
    case userDirectory = "User folder"
    case pyenv = "pyenv"
    case path = "PATH"
    case projectVenv = "playlist-gen .venv"
}

public struct LocatedTool: Equatable, Sendable {
    public var url: URL
    public var source: ToolSource
    public var path: String { url.path }
}

/// Result of a tool search: every tool's location (or nil) plus the
/// environment child processes get.
public struct ToolPaths: Equatable, Sendable {
    public var located: [Tool: LocatedTool]
    /// An override that points at something that isn't an executable.
    public var invalidOverrides: [Tool: String]
    /// Environment for child processes: PATH leads with the tools' folders,
    /// so yt-dlp finds ffmpeg and deno/node even from a Finder-launched app.
    public var environment: [String: String]

    public subscript(tool: Tool) -> URL? { located[tool]?.url }

    public var ytDlp: URL? { self[.ytDlp] }
    public var ffmpeg: URL? { self[.ffmpeg] }
    public var ffprobe: URL? { self[.ffprobe] }
    /// deno preferred (yt-dlp's default), node as the alternative.
    public var jsRuntime: LocatedTool? { located[.deno] ?? located[.node] }

    /// Tools that must exist to download anything.
    public var missingRequired: [Tool] {
        [Tool.ytDlp, .ffmpeg].filter { located[$0] == nil }
    }

    public static let installCommand = "brew install yt-dlp ffmpeg deno"

    /// nil when yt-dlp and ffmpeg are both available.
    public var problem: ToolProblem? {
        for tool in [Tool.ytDlp, .ffmpeg] {
            if let bad = invalidOverrides[tool] { return .invalidOverride(tool, bad) }
        }
        let missing = missingRequired
        return missing.isEmpty ? nil : .missing(missing)
    }
}

public enum ToolProblem: LocalizedError, Equatable, Sendable {
    case missing([Tool])
    case invalidOverride(Tool, String)
    case broken(Tool, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let tools):
            let names = tools.map(\.rawValue).joined(separator: " and ")
            return "Playlist Gen needs \(names) to download songs. Install them with Homebrew (\(ToolPaths.installCommand)), or choose where they are in Settings › Tools."
        case .invalidOverride(let tool, let path):
            return "The \(tool.rawValue) chosen in Settings (\(path)) isn’t an executable. Choose it again or use the automatic location."
        case .broken(let tool, let detail):
            return "\(tool.rawValue) didn’t run: \(detail)"
        }
    }
}

/// Finds tools. Precedence, first match wins:
/// 1. a path chosen in Settings,
/// 2. Homebrew (/opt/homebrew/bin, /usr/local/bin),
/// 3. ~/.local/bin, ~/.cargo/bin, ~/.deno/bin,
/// 4. pyenv shims,
/// 5. the inherited PATH,
/// 6. for yt-dlp only: the repository's `.venv/bin` (uv installs it there
///    for the Python CLI), when the app happens to run from the repo.
///
/// ffprobe is looked up next to the chosen ffmpeg first.
public struct ToolLocator: Sendable {
    public var home: String
    public var pathVariable: String
    public var overrides: [Tool: String]
    /// Repository checkouts to check for `.venv/bin/yt-dlp`.
    public var projectRoots: [URL]
    public var isExecutable: @Sendable (String) -> Bool
    public var baseEnvironment: [String: String]

    public init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        overrides: [Tool: String] = [:],
        projectRoots: [URL] = [],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    ) {
        self.home = home
        self.pathVariable = pathVariable
        self.overrides = overrides
        self.projectRoots = projectRoots
        self.baseEnvironment = baseEnvironment
        self.isExecutable = isExecutable
    }

    /// Reads overrides from UserDefaults and looks for the repo around the
    /// running executable / working directory (only used as a yt-dlp fallback).
    public static func standard(defaults: UserDefaults = .standard) -> ToolLocator {
        var overrides: [Tool: String] = [:]
        for tool in Tool.allCases {
            if let value = defaults.string(forKey: tool.overrideKey), !value.isEmpty {
                overrides[tool] = (value as NSString).expandingTildeInPath
            }
        }
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PLAYLIST_GEN_ROOT"] {
            roots.append(URL(fileURLWithPath: env))
        }
        roots += ancestors(of: Bundle.main.bundleURL)
        roots += ancestors(of: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return ToolLocator(overrides: overrides, projectRoots: roots)
    }

    static func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        while current.path != "/" && !current.path.isEmpty {
            result.append(current)
            current = current.deletingLastPathComponent()
        }
        return result
    }

    public var homebrewDirs: [String] { ["/opt/homebrew/bin", "/usr/local/bin"] }
    public var userDirs: [String] { ["\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.deno/bin"] }
    public var pyenvDirs: [String] { ["\(home)/.pyenv/shims"] }
    public var pathDirs: [String] { pathVariable.split(separator: ":").map(String.init).filter { !$0.isEmpty } }

    /// Search directories in precedence order, tagged with their source.
    var searchDirs: [(String, ToolSource)] {
        homebrewDirs.map { ($0, .homebrew) }
            + userDirs.map { ($0, .userDirectory) }
            + pyenvDirs.map { ($0, .pyenv) }
            + pathDirs.map { ($0, .path) }
    }

    public func locate() -> ToolPaths {
        var located: [Tool: LocatedTool] = [:]
        var invalid: [Tool: String] = [:]
        for tool in Tool.allCases {
            if let override = overrides[tool] {
                if isExecutable(override) {
                    located[tool] = LocatedTool(url: URL(fileURLWithPath: override), source: .override)
                } else {
                    invalid[tool] = override
                }
                continue
            }
            if tool == .ffprobe, let ffmpeg = located[.ffmpeg] {
                let sibling = ffmpeg.url.deletingLastPathComponent().appending(path: "ffprobe").path
                if isExecutable(sibling) {
                    located[tool] = LocatedTool(url: URL(fileURLWithPath: sibling), source: ffmpeg.source)
                    continue
                }
            }
            if let found = search(tool) { located[tool] = found }
        }
        return ToolPaths(located: located, invalidOverrides: invalid, environment: childEnvironment(located))
    }

    func search(_ tool: Tool) -> LocatedTool? {
        for (dir, source) in searchDirs {
            let path = (dir as NSString).appendingPathComponent(tool.executableName)
            if isExecutable(path) { return LocatedTool(url: URL(fileURLWithPath: path), source: source) }
        }
        if tool == .ytDlp {
            for root in projectRoots {
                let path = root.appending(path: ".venv/bin/yt-dlp").path
                if isExecutable(path) { return LocatedTool(url: URL(fileURLWithPath: path), source: .projectVenv) }
            }
        }
        return nil
    }

    func childEnvironment(_ located: [Tool: LocatedTool]) -> [String: String] {
        var env = baseEnvironment
        var dirs: [String] = []
        // The tools' own folders first (in the order yt-dlp needs them), then
        // the usual install locations, then whatever PATH we inherited.
        let toolDirs = [Tool.ytDlp, .ffmpeg, .ffprobe, .deno, .node].compactMap {
            located[$0]?.url.deletingLastPathComponent().path
        }
        let fallback = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in toolDirs + homebrewDirs + userDirs + pathDirs + fallback where !dirs.contains(dir) {
            dirs.append(dir)
        }
        env["PATH"] = dirs.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        // An activated venv from the launching shell mustn't leak into yt-dlp.
        env.removeValue(forKey: "VIRTUAL_ENV")
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }
}
