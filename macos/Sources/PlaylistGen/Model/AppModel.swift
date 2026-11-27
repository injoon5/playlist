import AppKit
import Foundation
import Observation
import PlaylistRender
import PlaylistSource

struct TrackRow: Identifiable, Hashable, Codable {
    let id: UUID
    /// Metadata as shown and rendered (the user may edit it).
    var track: PlaylistTrack
    /// Apple Music's metadata, used for the YouTube search.
    let original: PlaylistTrack
    var included = true

    init(track: PlaylistTrack) {
        self.id = UUID()
        self.track = track
        self.original = track
    }

    var isEdited: Bool {
        track.title != original.title || track.artist != original.artist || track.album != original.album
    }
}

enum LoadState: Equatable {
    case idle, loading, failed(String)
}

@MainActor @Observable
final class AppModel {
    // Tools (yt-dlp, ffmpeg, deno/node)
    /// Set once yt-dlp and ffmpeg are found and yt-dlp runs.
    private(set) var tools: ToolPaths?
    /// The latest search, even when something required is missing (Settings shows it).
    private(set) var toolSearch: ToolPaths?
    private(set) var toolProblem: ToolProblem?
    private(set) var isCheckingTools = false
    private(set) var ytDlpVersion: String?
    private(set) var ytDlpUpdate: ToolUpdateState = .idle
    /// Bundled sample backgrounds (Contents/Resources/Backgrounds in the app).
    let backgroundsDir: URL? = BundledBackgrounds.directory
    private(set) var backgroundCandidates: [String] = []

    // Setup
    var settings: RunSettings {
        didSet { if settings != oldValue { settings.save() } }
    }
    /// The song list (with edits and order) survives quitting.
    var tracks: [TrackRow] = [] {
        didSet { scheduleSessionSave() }
    }
    /// Set when Generate would overwrite an existing video; the view asks first.
    var confirmReplacePath: String?
    private var sessionSaveTask: Task<Void, Never>?
    /// The row the preview shows (the table's first selected row).
    var previewTrackID: TrackRow.ID?
    private(set) var loadState: LoadState = .idle
    private var fetchTask: Task<Void, Never>?

    // Run
    private(set) var run: RunModel?
    /// The last video made (kept across launches), for copying its chapters.
    private(set) var lastOutput: RunModel.Output? = AppModel.loadLastOutput()

    static let imageExtensions: Set<String> = ["jpeg", "jpg", "png", "webp", "gif", "bmp", "heic", "tiff"]

    init() {
        var settings = RunSettings.load() ?? RunSettings.firstLaunch(backgroundsDir: BundledBackgrounds.directory)
        // Save to ~/Movies by default (older versions saved inside the repository).
        if settings.output.isEmpty || settings.output.hasSuffix("/output/playlist_video.mp4") {
            settings.output = Self.defaultOutputPath
        }
        if settings.gpu != "h264" { settings.gpu = "auto" }  // legacy on/off values
        self.settings = settings
        if let session = Self.loadSession() {
            tracks = session
            previewTrackID = session.first?.id
        }
        refreshBackgrounds()
    }

    // MARK: - Session

    private static var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Playlist Gen/session.json")
    }

    private static func loadSession() -> [TrackRow]? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode([TrackRow].self, from: data)
    }

    private func scheduleSessionSave() {
        sessionSaveTask?.cancel()
        let snapshot = tracks
        sessionSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let url = Self.sessionURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }

    /// Default save location: ~/Movies/Playlist Gen.
    static var defaultOutputPath: String {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appending(path: "Playlist Gen/Playlist Video.mp4").path
    }

    // MARK: - Tools

    /// Look for yt-dlp, ffmpeg and deno/node, and make sure yt-dlp runs.
    /// Quick: a few file checks plus `yt-dlp --version`.
    func checkTools() async {
        guard !isCheckingTools else { return }
        isCheckingTools = true
        defer { isCheckingTools = false }
        let found = ToolLocator.standard().locate()
        toolSearch = found
        if let problem = found.problem {
            tools = nil
            toolProblem = problem
            ytDlpVersion = nil
            return
        }
        do {
            ytDlpVersion = try await ToolUpdater.ytDlpVersion(found)
            tools = found
            toolProblem = nil
        } catch let problem as ToolProblem {
            tools = nil
            toolProblem = problem
        } catch {
            tools = nil
            toolProblem = .broken(.ytDlp, error.localizedDescription)
        }
    }

    /// Settings › Tools › Update yt-dlp: `brew upgrade yt-dlp` or `yt-dlp -U`.
    func updateYtDlp() async {
        guard let found = toolSearch, found.ytDlp != nil, ytDlpUpdate != .running else { return }
        ytDlpUpdate = .running
        do {
            let output = try await ToolUpdater.updateYtDlp(found)
            await checkTools()
            ytDlpUpdate = .finished(output)
        } catch {
            ytDlpUpdate = .failed(error.localizedDescription)
        }
    }

    func refreshBackgrounds() {
        let fm = FileManager.default
        var found: [String] = []
        if let dir = backgroundsDir, let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            found = names
                .filter { Self.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
                .map { dir.appending(path: $0).path }
        }
        let extras = settings.extraBackgrounds.filter { fm.fileExists(atPath: $0) && !found.contains($0) }
        backgroundCandidates = found + extras
        let available = Set(backgroundCandidates)
        // Selections made when the samples came from the repository's
        // assets/backgrounds (or from a moved app) map to the bundled copies.
        let kept = settings.backgrounds.compactMap { path -> String? in
            if available.contains(path) { return path }
            return BundledBackgrounds.equivalent(of: path, in: found)
        }
        if kept != settings.backgrounds { settings.backgrounds = kept }
    }

    func addBackgrounds(_ paths: [String]) {
        for path in paths where !backgroundCandidates.contains(path) {
            settings.extraBackgrounds.append(path)
        }
        for path in paths where !settings.backgrounds.contains(path) {
            settings.backgrounds.append(path)
        }
        refreshBackgrounds()
    }

    func removeExtraBackground(_ path: String) {
        settings.extraBackgrounds.removeAll { $0 == path }
        settings.backgrounds.removeAll { $0 == path }
        refreshBackgrounds()
    }

    func toggleBackground(_ path: String) {
        if let i = settings.backgrounds.firstIndex(of: path) {
            settings.backgrounds.remove(at: i)
        } else {
            settings.backgrounds.append(path)
        }
    }

    // MARK: - Playlist

    var isLoading: Bool { loadState == .loading }

    func loadTracks() {
        let url = settings.playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            loadState = .failed("Paste an Apple Music playlist link first. In Music, choose Share › Copy Link on a playlist.")
            return
        }
        guard Self.isAppleMusicLink(url) else {
            loadState = .failed("That doesn’t look like an Apple Music link (music.apple.com/…/playlist/…).")
            return
        }
        guard tools != nil, run == nil else { return }
        fetchTask?.cancel()
        loadState = .loading
        let fastFirst = settings.fastScrape

        // Web view first by default (like the Python default of headless
        // Chromium), the fast reader first if that setting is on; each falls
        // back to the other.
        fetchTask = Task {
            do {
                let loaded = try await PlaylistScraper.fetchTracks(url, fastFirst: fastFirst)
                guard !Task.isCancelled else { return }
                tracks = Self.merge(loaded, into: tracks)
                if !tracks.contains(where: { $0.id == previewTrackID }) {
                    previewTrackID = tracks.first?.id
                }
                loadState = .idle
            } catch {
                guard !Task.isCancelled else { return }  // superseded or stopped
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    static func isAppleMusicLink(_ string: String) -> Bool {
        string.contains("music.apple.com")
    }

    /// Use the Apple Music link on the clipboard (if there is one), then load.
    func pasteLinkAndLoad() {
        let clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.isAppleMusicLink(clipboard) {
            settings.playlistURL = clipboard
        } else if !Self.isAppleMusicLink(settings.playlistURL) {
            loadState = .failed("There’s no Apple Music link on the clipboard. In Music, choose Share › Copy Link on a playlist, then try again.")
            return
        }
        loadTracks()
    }

    /// Editing the link dismisses a previous load error.
    func clearLoadError() {
        if case .failed = loadState { loadState = .idle }
    }

    /// Reloading keeps your work: songs still in the playlist keep their
    /// edits, selection and your order; new songs are added at the end.
    static func merge(_ loaded: [PlaylistTrack], into existing: [TrackRow]) -> [TrackRow] {
        func key(_ t: PlaylistTrack) -> String { "\(t.title)\u{1F}\(t.artist)\u{1F}\(t.album)" }
        var fresh: [String: [PlaylistTrack]] = [:]
        for t in loaded { fresh[key(t), default: []].append(t) }
        var kept: [TrackRow] = []
        for row in existing {
            guard var matches = fresh[key(row.original)], !matches.isEmpty else { continue }
            matches.removeFirst()
            fresh[key(row.original)] = matches
            kept.append(row)
        }
        let added = loaded.filter { t in
            guard var matches = fresh[key(t)], !matches.isEmpty else { return false }
            matches.removeFirst()
            fresh[key(t)] = matches
            return true
        }
        return kept + added.map { TrackRow(track: $0) }
    }

    func cancelLoad() {
        fetchTask?.cancel()
        fetchTask = nil
        loadState = .idle
    }

    /// Include or exclude every song. Undoable like the table's own edits
    /// (same window undo manager), so a stray Exclude All isn't a disaster.
    func setAllIncluded(_ included: Bool, undoManager: UndoManager? = nil) {
        let updated = tracks.map { row in
            var row = row
            row.included = included
            return row
        }
        replaceTracks(
            updated, actionName: included ? "Include All" : "Exclude All",
            undoManager: undoManager ?? NSApp.mainWindow?.undoManager
        )
    }

    private func replaceTracks(_ updated: [TrackRow], actionName: String, undoManager: UndoManager?) {
        let previous = tracks
        guard previous != updated else { return }
        tracks = updated
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.replaceTracks(previous, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
    }

    var includedTracks: [PlaylistTrack] { tracks.filter(\.included).map(\.track) }
    var includedCount: Int { tracks.reduce(0) { $0 + ($1.included ? 1 : 0) } }
    var includedDuration: Double {
        tracks.filter(\.included).reduce(0) { $0 + Double($1.track.durationMs ?? 0) / 1000 }
    }

    /// Background a track would get, given its position among included tracks.
    func background(forIncludedPosition position: Int) -> String? {
        let assigned = Background.assign(settings.backgrounds, trackCount: includedCount)
        return position < assigned.count ? assigned[position] : nil
    }

    /// Inputs for the preview pane: the selected (or first) track, the
    /// background it would get, and the current video settings.
    var previewKey: PreviewKey? {
        guard let row = tracks.first(where: { $0.id == previewTrackID }) ?? tracks.first else { return nil }
        let position = tracks.filter(\.included).firstIndex(where: { $0.id == row.id }) ?? 0
        let (w, h) = PreviewModel.previewSize(for: settings)
        return PreviewKey(
            title: row.track.title, artist: row.track.artist, album: row.track.album,
            artworkURL: row.track.artworkUrl,
            background: background(forIncludedPosition: position),
            duration: Double(row.track.durationMs ?? 200_000) / 1000,
            transition: settings.transitionDuration, width: w, height: h
        )
    }

    // MARK: - Generate

    var generateBlocker: String? {
        if tools == nil { return "yt-dlp and ffmpeg are needed to download songs." }
        if run != nil { return "A video is already being generated." }
        if isLoading { return "Wait for the playlist to finish loading." }
        if tracks.isEmpty { return "Load a playlist first." }
        if includedCount == 0 { return "Include at least one song." }
        if settings.backgrounds.count > includedCount {
            return "There are more background images (\(settings.backgrounds.count)) than included songs (\(includedCount))."
        }
        return nil
    }

    var canGenerate: Bool { generateBlocker == nil }

    var outputPath: String { settings.output.isEmpty ? Self.defaultOutputPath : settings.output }

    /// Generate, asking first if a video is already at the save location.
    func requestGenerate() {
        guard canGenerate else { return }
        if FileManager.default.fileExists(atPath: outputPath) {
            confirmReplacePath = outputPath
        } else {
            generate()
        }
    }

    func generate() {
        guard canGenerate, let tools else { return }
        var selected = tracks.filter(\.included)
        if settings.shuffle { selected.shuffle() }
        let shown = selected.enumerated().map { i, row in
            var t = row.track
            t.index = i + 1
            return t
        }
        let search = selected.enumerated().map { i, row in
            var t = row.original
            t.index = i + 1
            return t
        }
        let size = settings.size
        let output = settings.output.isEmpty ? Self.defaultOutputPath : settings.output
        let config = RunConfig(
            tracks: shown,
            searchTracks: search,
            backgrounds: Background.assign(settings.backgrounds, trackCount: shown.count),
            output: output,
            width: size.width, height: size.height, fps: settings.fps,
            workers: settings.workers, renderWorkers: settings.renderWorkers,
            gpu: settings.gpu, transitionDuration: settings.transitionDuration
        )
        start(RunModel(config: config, tools: tools))
    }

    /// Run the same video again after a failure or a stop.
    func retryRun() {
        guard let previous = run, !previous.isActive, let tools else { return }
        start(RunModel(config: previous.config, tools: tools))
    }

    private func start(_ model: RunModel) {
        model.onFinished = { [weak self] output in self?.remember(output) }
        run = model
        model.start()
    }

    // MARK: - Chapters

    /// The video whose chapters Copy YouTube Chapters copies: the one on
    /// screen, else the last one made (while it still exists).
    var chaptersOutput: RunModel.Output? {
        if let output = run?.output { return output }
        guard run == nil, let lastOutput, FileManager.default.fileExists(atPath: lastOutput.videoPath) else { return nil }
        return lastOutput
    }

    func copyChapters() {
        guard let output = chaptersOutput else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.descriptionText, forType: .string)
    }

    private static var lastOutputURL: URL {
        sessionURL.deletingLastPathComponent().appending(path: "last-video.json")
    }

    private static func loadLastOutput() -> RunModel.Output? {
        guard let data = try? Data(contentsOf: lastOutputURL) else { return nil }
        return try? JSONDecoder().decode(RunModel.Output.self, from: data)
    }

    private func remember(_ output: RunModel.Output) {
        lastOutput = output
        let url = Self.lastOutputURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(output).write(to: url, options: .atomic)
    }

    func closeRun() {
        guard let run, !run.isActive else { return }
        self.run = nil
    }

    func shutdown() {
        fetchTask?.cancel()
        run?.shutdown()
        // yt-dlp, ffmpeg, brew: nothing outlives the app.
        ProcessRegistry.shared.killAll()
    }
}

enum ToolUpdateState: Equatable {
    case idle, running, finished(String), failed(String)
}

/// The sample background images (assets/backgrounds in the repository).
/// build-app.sh copies them into the app's Resources/Backgrounds; a
/// `swift run` build uses the repository's folder.
enum BundledBackgrounds {
    static let directory: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: "Backgrounds"))
        }
        // Development builds: <repo>/macos/Sources/PlaylistGen/Model/AppModel.swift -> <repo>/assets/backgrounds
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo = repo.deletingLastPathComponent() }
        candidates.append(repo.appending(path: "assets/backgrounds"))
        return candidates.first { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }()

    /// A bundled image with the same name as `path`, when `path` was one of
    /// the samples from somewhere else (a repository checkout, an older app).
    static func equivalent(of path: String, in bundled: [String]) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().lastPathComponent.lowercased() == "backgrounds" else { return nil }
        return bundled.first { ($0 as NSString).lastPathComponent == url.lastPathComponent }
    }
}
