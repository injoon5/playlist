import AppKit
import Foundation
import Observation
import PlaylistRender

struct TrackRow: Identifiable, Hashable, Codable {
    let id: UUID
    /// Metadata as shown and rendered (the user may edit it).
    var track: BridgeTrack
    /// Apple Music's metadata, used for the YouTube search.
    let original: BridgeTrack
    var included = true

    init(track: BridgeTrack) {
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
    // Backend
    private(set) var environment: ToolEnvironment?
    private(set) var environmentError: String?
    private(set) var isConnecting = false
    private(set) var backgroundsDir: URL?
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
    private var fetchProcess: BridgeProcess?
    private let hadSavedSettings: Bool

    // Run
    private(set) var run: RunModel?

    static let imageExtensions: Set<String> = ["jpeg", "jpg", "png", "webp", "gif", "bmp", "heic", "tiff"]

    init() {
        let saved = RunSettings.load()
        hadSavedSettings = saved != nil
        settings = saved ?? RunSettings()
        if let session = Self.loadSession() {
            tracks = session
            previewTrackID = session.first?.id
        }
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

    // MARK: - Backend

    /// Locate the Python project + uv, then read its defaults (also warms up
    /// `uv run`, which syncs the venv on first use).
    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        environmentError = nil
        let env: ToolEnvironment
        do {
            env = try ToolEnvironment.resolve()
        } catch {
            environment = nil
            environmentError = error.localizedDescription
            return
        }

        let process = BridgeProcess(environment: env, arguments: ["defaults"])
        let box = MessageBox()
        let status = try? await process.run(
            onMessage: { box.messages.append($0) },
            onLog: { box.log.append($0) }
        )
        guard let defaults = box.messages.lazy.compactMap({ message -> BridgeDefaults? in
            if case .defaults(let d) = message { return d }
            return nil
        }).first else {
            environment = nil
            let tail = box.log.suffix(6).joined(separator: "\n")
            environmentError = "The Python backend didn't start (exit \(status ?? -1)).\n\(tail)"
            return
        }

        environment = env
        backgroundsDir = URL(fileURLWithPath: defaults.backgroundsDir)
        if !hadSavedSettings && settings == RunSettings() {
            settings.apply(defaults)
        }
        // Save to ~/Movies by default rather than inside the repository.
        if settings.output.isEmpty || settings.output == env.defaultOutputPath {
            settings.output = Self.defaultOutputPath
        }
        if settings.gpu != "h264" { settings.gpu = "auto" }  // legacy on/off values
        refreshBackgrounds()
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
        let kept = settings.backgrounds.filter { available.contains($0) }
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
            loadState = .failed("Paste an Apple Music playlist link first.")
            return
        }
        guard url.contains("music.apple.com") else {
            loadState = .failed("That doesn't look like an Apple Music link (music.apple.com/…/playlist/…).")
            return
        }
        guard let environment, run == nil else { return }
        fetchProcess?.terminate()
        var arguments = ["fetch", url]
        if settings.fastScrape { arguments.append("--fast-scrape") }
        let process = BridgeProcess(environment: environment, arguments: arguments)
        fetchProcess = process
        loadState = .loading

        Task {
            let box = MessageBox()
            let status = try? await process.run(
                onMessage: { box.messages.append($0) },
                onLog: { box.log.append($0) }
            )
            guard fetchProcess === process else { return }  // superseded or cancelled
            fetchProcess = nil
            for message in box.messages {
                switch message {
                case .tracks(let loaded):
                    tracks = Self.merge(loaded, into: tracks)
                    if !tracks.contains(where: { $0.id == previewTrackID }) {
                        previewTrackID = tracks.first?.id
                    }
                    loadState = .idle
                    return
                case .error(let message, _):
                    loadState = .failed(message)
                    return
                default:
                    continue
                }
            }
            let tail = box.log.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            loadState = .failed(tail ?? "Loading stopped (exit \(status ?? -1)).")
        }
    }

    /// Reloading keeps your work: songs still in the playlist keep their
    /// edits, selection and your order; new songs are added at the end.
    static func merge(_ loaded: [BridgeTrack], into existing: [TrackRow]) -> [TrackRow] {
        func key(_ t: BridgeTrack) -> String { "\(t.title)\u{1F}\(t.artist)\u{1F}\(t.album)" }
        var fresh: [String: [BridgeTrack]] = [:]
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
        fetchProcess?.terminate()
        fetchProcess = nil
        loadState = .idle
    }

    func setAllIncluded(_ included: Bool) {
        for i in tracks.indices { tracks[i].included = included }
    }

    var includedTracks: [BridgeTrack] { tracks.filter(\.included).map(\.track) }
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
        if environment == nil { return "The Python backend isn't connected." }
        if run != nil { return "A run is already open." }
        if isLoading { return "Wait for the playlist to finish loading." }
        if tracks.isEmpty { return "Load a playlist first." }
        if includedCount == 0 { return "Select at least one track." }
        if settings.backgrounds.count > includedCount {
            return "\(settings.backgrounds.count) backgrounds but only \(includedCount) track(s) selected."
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
        guard canGenerate, let environment else { return }
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
        let model = RunModel(config: config, environment: environment)
        run = model
        model.start()
    }

    func closeRun() {
        guard let run, !run.isActive else { return }
        self.run = nil
    }

    func shutdown() {
        fetchProcess?.terminate()
        run?.shutdown()
    }
}

/// Collects bridge output on the main actor.
@MainActor
final class MessageBox {
    var messages: [BridgeMessage] = []
    var log: [String] = []
}
