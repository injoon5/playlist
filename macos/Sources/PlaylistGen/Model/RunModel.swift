import AppKit
import DockProgress
import Foundation
import Observation
import PlaylistRender
import PlaylistSource
import UserNotifications

/// The render and concat code below still says BridgeTrack (the Python
/// bridge's name for a track); kept so this file merges cleanly with render
/// work happening in parallel. Rename to PlaylistTrack after that merge.
typealias BridgeTrack = PlaylistTrack

/// Inputs for one generation run, frozen when the user presses Generate.
struct RunConfig: Sendable {
    /// Final order; `index` is 1-based position. Titles may be user-edited.
    var tracks: [PlaylistTrack]
    /// Same order, with Apple Music's original metadata (for the YouTube search).
    var searchTracks: [PlaylistTrack]
    /// Background image per track (nil = blurred artwork / gradient).
    var backgrounds: [String?]
    var output: String
    var width: Int
    var height: Int
    var fps: Int
    var workers: Int
    var renderWorkers: Int?
    var gpu: String
    var transitionDuration: Double
}

/// Overall bar: download 0–45 %, render 45–95 %, concat 95–100 %. Counts
/// in-flight slot fractions, never moves backwards.
struct OverallProgress: Equatable {
    private(set) var value = 0.0
    private var downloadSlots: [Int: Double] = [:]

    mutating func apply(download ev: ProgressEvent) {
        guard ev.phase == "download", ev.total > 0 else { return }
        if let slot = ev.slotId {
            if let f = ev.fraction, ev.trackStatus == "downloading" {
                downloadSlots[slot] = min(max(f, 0), 1)
            } else {
                downloadSlots[slot] = nil
            }
        }
        let partial = downloadSlots.values.reduce(0, +)
        advance(to: 0.45 * min(1, (Double(ev.completed) + partial) / Double(ev.total)))
    }

    mutating func render(completed: Int, inFlight: Double, total: Int) {
        guard total > 0 else { return }
        advance(to: 0.45 + 0.5 * min(1, (Double(completed) + inFlight) / Double(total)))
    }

    mutating func advance(to newValue: Double) {
        value = max(value, min(newValue, 1))
    }
}

struct RunError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
final class RunModel {
    enum State: Equatable {
        case running, cancelling, finished, failed(String), cancelled
    }

    struct Row: Identifiable, Equatable {
        let id: Int
        var title: String
        var artist: String
        var phase: String
        var status: String
    }

    struct Slot: Identifiable, Equatable {
        let id: Int
        var trackIndex: Int?
        var label: String
        var fraction: Double
        var phase: String
    }

    struct LogLine: Identifiable, Equatable {
        enum Kind { case info, success, warning, error, output }
        let id: Int
        let kind: Kind
        let text: String
    }

    struct Output: Equatable, Codable {
        var videoPath: String
        var descriptionPath: String
        var chapters: YouTubeChapters

        /// Ready to paste into a YouTube description.
        var descriptionText: String { chapters.text }
    }

    let config: RunConfig
    private(set) var state: State = .running
    private(set) var phase = "download"
    private(set) var headline = "Starting…"
    /// Second line under the headline, e.g. "12 of 27 songs rendered".
    private(set) var detail = ""
    private(set) var progress = OverallProgress()
    private(set) var rows: [Row]
    private(set) var slots: [Int: Slot] = [:]
    private(set) var log: [LogLine] = []
    private(set) var output: Output?
    /// Called once the video is written.
    var onFinished: ((Output) -> Void)?
    let startedAt = Date()
    private(set) var finishedAt: Date?

    /// yt-dlp / ffmpeg / deno locations; `environment.environment` is the
    /// child-process environment (PATH leads with those tools' folders).
    private let environment: ToolPaths
    private let cancelFlag = CancellationFlag()
    private let workdir: URL
    private var downloadTask: Task<[DownloadedTrack], Error>?
    private var renderFractions: [Int: Double] = [:]
    private var renderCompleted = 0
    private var renderTotal = 0
    private var lastBadge = -1
    /// True once the final file is being written; only then is a stopped
    /// run's output deleted (never a previous video at the same path).
    private var startedWritingOutput = false

    var isActive: Bool { state == .running || state == .cancelling }

    func track(index: Int?) -> PlaylistTrack? {
        guard let index else { return nil }
        return config.tracks.first { $0.index == index }
    }

    init(config: RunConfig, tools: ToolPaths) {
        self.config = config
        self.environment = tools
        self.rows = config.tracks.map {
            Row(id: $0.index ?? 0, title: $0.title, artist: $0.artist, phase: "download", status: "pending")
        }
        self.workdir = FileManager.default.temporaryDirectory
            .appending(path: "amp_video_\(UUID().uuidString.prefix(8))")
    }

    func start() {
        Task { await run() }
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelling
        headline = "Stopping…"
        cancelFlag.cancel()
        downloadTask?.cancel()  // stops every yt-dlp process
    }

    /// App is quitting: stop everything right away.
    func shutdown() {
        DockProgress.resetProgress()
        cancelFlag.cancel()
        downloadTask?.cancel()
        ProcessRegistry.shared.killAll()
        guard isActive else { return }
        removePartialOutput()
        try? FileManager.default.removeItem(at: workdir)
    }

    // MARK: - Pipeline

    private func run() async {
        // Keep the Mac awake (but let the display sleep) while rendering.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Rendering a playlist video"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        DockProgress.style = .bar
        Notifier.requestPermission()
        append(.info, "Rendering \(songCount(config.tracks.count)) at \(config.width)×\(config.height), \(config.fps) fps")
        do {
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            let downloads = try await downloadPhase()
            try checkCancelled()
            let clips = try await renderPhase(downloads)
            try checkCancelled()
            let finished = try await concatPhase(clips)
            output = finished
            onFinished?(finished)
            state = .finished
            phase = "done"
            headline = "Video Ready"
            detail = finishedDetail()
            progress.advance(to: 1)
            append(.success, "Output: \(config.output)")
            removeWorkdir()
        } catch is RenderCancelled {
            removePartialOutput()
            state = .cancelled
            headline = "Stopped"
            detail = "Nothing was saved."
            append(.warning, "Cancelled")
            removeWorkdir()
        } catch {
            let message = error.localizedDescription
            removePartialOutput()
            state = .failed(message)
            headline = "Couldn’t Finish the Video"
            detail = message
            append(.error, message)
            removeWorkdir()
        }
        finishedAt = Date()
        slots.removeAll()
        downloadTask = nil
        if state == .finished {
            DockProgress.progress = 1  // animates to full, then shows the plain icon
        } else {
            DockProgress.resetProgress()
        }
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
            switch state {
            case .finished: Notifier.post(title: "Video Ready", body: detail)
            case .failed(let message): Notifier.post(title: "Couldn’t Finish the Video", body: message)
            default: break
            }
        }
    }

    private func checkCancelled() throws {
        if cancelFlag.isCancelled { throw RenderCancelled() }
    }

    /// yt-dlp search + download and artwork for every song, `workers` at a
    /// time (PlaylistSource's port of the Python download phase).
    private func downloadPhase() async throws -> [Int: DownloadedTrack] {
        phase = "download"
        headline = "Downloading Songs"
        detail = "Finding each song and downloading its audio and artwork"
        let downloader = MediaDownloader(tools: environment)
        let tracks = config.searchTracks
        let workers = config.workers
        let workdir = self.workdir
        let (events, continuation) = AsyncStream<DownloadEvent>.makeStream()
        let task = Task.detached {
            defer { continuation.finish() }
            return try await downloader.downloadAll(tracks, workers: workers, workdir: workdir, events: continuation)
        }
        downloadTask = task
        for await event in events {
            switch event {
            case .progress(let ev): handleDownload(ev)
            case .log(let line): append(.output, line)
            }
        }
        let downloaded: [DownloadedTrack]
        do {
            downloaded = try await task.value
        } catch is CancellationError {
            throw RenderCancelled()
        }
        downloadTask = nil
        if cancelFlag.isCancelled { throw RenderCancelled() }
        for t in downloaded {
            if let title = t.matchedVideoTitle, t.audioPath != nil {
                append(.output, "  #\(t.index) matched “\(title)”")
            }
        }
        return Dictionary(downloaded.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func handleDownload(_ ev: ProgressEvent) {
        progress.apply(download: ev)
        updateBadge()
        if let slot = ev.slotId {
            if let f = ev.fraction, ev.trackStatus == "downloading" {
                let row = rows.first { $0.id == ev.trackIndex }
                let label = row.map { "\($0.artist) - \($0.title)" } ?? ev.trackLabel ?? ""
                slots[slot] = Slot(id: slot, trackIndex: ev.trackIndex, label: label, fraction: f, phase: "download")
            } else {
                slots[slot] = nil
            }
        }
        if let index = ev.trackIndex, let status = ev.trackStatus {
            setRow(index, phase: "download", status: status)
        }
        headline = "Downloading Songs"
        detail = "\(ev.completed) of \(ev.total) downloaded"
        switch ev.trackStatus {
        case "ok": append(.success, ev.message)
        case "failed": append(.error, ev.message)
        case "skipped": append(.warning, ev.message)
        default: break
        }
    }

    private struct PreparedClip: Sendable {
        var track: BridgeTrack
        var job: ClipJob
    }

    private func renderPhase(_ downloads: [Int: DownloadedTrack]) async throws -> [(BridgeTrack, String)] {
        phase = "render"
        headline = "Rendering Video"
        detail = "Preparing…"
        let codec: VideoCodec = config.gpu == "h264" ? .h264 : .hevc
        append(.info, "Encoder: \(codec.summary); compositing on \(GPU.device?.name ?? "the CPU")")

        var prepared: [PreparedClip] = []
        for (i, track) in config.tracks.enumerated() {
            let index = track.index ?? i + 1
            guard let d = downloads[index], let audio = d.audioPath else {
                setRow(index, phase: "render", status: "skipped")
                append(.warning, "Skipping \(track.label) (no audio)")
                continue
            }
            let readable = try await Media.readableAudio(audio, workdir: workdir, environment: environment.environment)
            let duration = try await Media.duration(of: readable)
            let input = TrackRenderInput(
                title: track.title, artist: track.artist, album: track.album,
                artworkPath: d.artworkPath, backgroundPath: config.backgrounds[i],
                duration: duration, width: config.width, height: config.height,
                transitionDuration: config.transitionDuration
            )
            let job = ClipJob(
                input: input, audioPath: readable,
                outputPath: workdir.appending(path: String(format: "clip_%03d.mp4", index)).path,
                fps: config.fps, codec: codec
            )
            prepared.append(PreparedClip(track: track, job: job))
            setRow(index, phase: "render", status: "pending")
        }
        guard !prepared.isEmpty else {
            throw RunError(message: "None of the songs could be downloaded. Check your internet connection, then try again.")
        }

        // The Media Engine's video encoder is the bottleneck (~210 fps of 1080p
        // HEVC on an M2 Pro, shared by all sessions: 1, 2 or 4 clips at once
        // all measured ~208 fps in total). Two clips in flight hide each clip's
        // setup and finishing; more only add memory.
        let workers = max(1, config.renderWorkers ?? min(prepared.count, 2))
        renderTotal = prepared.count
        renderCompleted = 0
        detail = "0 of \(prepared.count) songs rendered"
        append(.info, "Rendering \(songCount(prepared.count)), \(workers) at a time")

        var finished: [Int: String] = [:]
        var freeSlots = Array(0..<workers)
        let flag = cancelFlag
        await withTaskGroup(of: (Int, Int, Error?).self) { group in
            var next = 0
            while true {
                while next < prepared.count, !freeSlots.isEmpty, !flag.isCancelled {
                    let slot = freeSlots.removeFirst()
                    let i = next
                    next += 1
                    let clip = prepared[i]
                    let index = clip.track.index ?? i + 1
                    setRow(index, phase: "render", status: "rendering")
                    slots[slot] = Slot(id: slot, trackIndex: index, label: clip.track.label, fraction: 0, phase: "render")
                    renderFractions[slot] = 0
                    let report: @Sendable (Double) -> Void = { [weak self] fraction in
                        Task { @MainActor [weak self] in self?.renderTick(slot: slot, fraction: fraction) }
                    }
                    group.addTask {
                        do {
                            try await Media.renderClip(clip.job, cancel: flag, progress: report)
                            return (i, slot, nil)
                        } catch {
                            return (i, slot, error)
                        }
                    }
                }
                guard let (i, slot, error) = await group.next() else { break }
                freeSlots.append(slot)
                slots[slot] = nil
                renderFractions[slot] = nil
                renderCompleted += 1
                let clip = prepared[i]
                let index = clip.track.index ?? i + 1
                switch error {
                case nil:
                    finished[i] = clip.job.outputPath
                    setRow(index, phase: "render", status: "ok")
                    append(.success, "Rendered \(clip.track.label)")
                case is RenderCancelled:
                    setRow(index, phase: "render", status: "cancelled")
                case let error?:
                    setRow(index, phase: "render", status: "failed")
                    append(.error, "Failed \(clip.track.label): \(error.localizedDescription)")
                }
                detail = "\(renderCompleted) of \(renderTotal) songs rendered"
                updateRenderProgress()
            }
        }
        try checkCancelled()
        let clips = prepared.indices.compactMap { i in finished[i].map { (prepared[i].track, $0) } }
        guard !clips.isEmpty else {
            throw RunError(message: "None of the songs could be rendered. Show Details for more information.")
        }
        return clips
    }

    private func renderTick(slot: Int, fraction: Double) {
        guard renderFractions[slot] != nil, var current = slots[slot] else { return }
        current.fraction = fraction
        slots[slot] = current
        renderFractions[slot] = fraction
        updateRenderProgress()
    }

    private func updateRenderProgress() {
        progress.render(
            completed: renderCompleted, inFlight: renderFractions.values.reduce(0, +), total: renderTotal
        )
        updateBadge()
    }

    private func concatPhase(_ clips: [(BridgeTrack, String)]) async throws -> Output {
        phase = "concat"
        headline = "Finishing Up"
        detail = "Joining \(clips.count) songs into one video"
        progress.advance(to: 0.95)
        let outputPath = config.output
        let entries = clips.map { (title: $0.0.title, artist: $0.0.artist, clipPath: $0.1) }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        startedWritingOutput = true
        try await Media.concat(entries.map(\.clipPath), to: outputPath)
        let description = try await Media.writeDescription(entries: entries, videoPath: outputPath)
        return Output(videoPath: outputPath, descriptionPath: description.path, chapters: description.chapters)
    }

    // MARK: - Helpers

    private func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    /// Songs that didn't make it into the video.
    var leftOutCount: Int {
        rows.filter { $0.status == "skipped" || $0.status == "failed" }.count
    }

    /// "Playlist Video.mp4 · 1 hr, 52 min", or a heads-up that songs are missing.
    private func finishedDetail() -> String {
        let name = URL(fileURLWithPath: config.output).lastPathComponent
        let missing = leftOutCount
        guard missing > 0 else {
            let seconds = config.tracks.reduce(0.0) { $0 + Double($1.durationMs ?? 0) / 1000 }
            return seconds > 0 ? "\(name) · \(formatLongDuration(seconds))" : name
        }
        let included = rows.count - missing
        return missing == 1
            ? "1 song couldn’t be downloaded or rendered and was left out (\(included) of \(rows.count) are in the video)."
            : "\(missing) songs couldn’t be downloaded or rendered and were left out (\(included) of \(rows.count) are in the video)."
    }

    private func setRow(_ index: Int, phase: String, status: String) {
        guard let i = rows.firstIndex(where: { $0.id == index }) else { return }
        rows[i].phase = phase
        rows[i].status = status
    }

    private func append(_ kind: LogLine.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        log.append(LogLine(id: log.count, kind: kind, text: text))
    }

    /// Progress bar on the Dock icon (DockProgress), updated per percent.
    private func updateBadge() {
        let percent = Int(progress.value * 100)
        guard percent != lastBadge else { return }
        lastBadge = percent
        DockProgress.progress = max(0.001, progress.value)
    }

    /// Delete downloads, artwork and clips. yt-dlp may still be flushing a
    /// file as it's cancelled, so sweep again a moment later.
    private func removeWorkdir() {
        let dir = workdir
        try? FileManager.default.removeItem(at: dir)
        Task.detached {
            try? await Task.sleep(for: .seconds(3))
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func removePartialOutput() {
        guard startedWritingOutput, output == nil else { return }
        let fm = FileManager.default
        try? fm.removeItem(atPath: config.output)
        try? fm.removeItem(atPath: (config.output as NSString).deletingPathExtension + "_description.txt")
    }
}

/// "Video Ready" notifications when the app is in the background.
@MainActor
enum Notifier {
    /// UserNotifications needs a real app bundle (not `swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
