import AppKit
import DockProgress
import Foundation
import Observation
import PlaylistRender
import UserNotifications

/// Inputs for one generation run, frozen when the user presses Generate.
struct RunConfig: Sendable {
    /// Final order; `index` is 1-based position. Titles may be user-edited.
    var tracks: [BridgeTrack]
    /// Same order, with Apple Music's original metadata (for the YouTube search).
    var searchTracks: [BridgeTrack]
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

    struct Output: Equatable {
        var videoPath: String
        var descriptionPath: String
        var descriptionText: String
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
    let startedAt = Date()
    private(set) var finishedAt: Date?

    private let environment: ToolEnvironment
    private let cancelFlag = CancellationFlag()
    private let workdir: URL
    private var bridge: BridgeProcess?
    private var downloaded: [DownloadedTrack]?
    private var bridgeError: String?
    private var bridgeCancelled = false
    private var renderFractions: [Int: Double] = [:]
    private var renderCompleted = 0
    private var renderTotal = 0
    private var lastBadge = -1
    /// True once the final file is being written; only then is a stopped
    /// run's output deleted (never a previous video at the same path).
    private var startedWritingOutput = false

    var isActive: Bool { state == .running || state == .cancelling }

    func track(index: Int?) -> BridgeTrack? {
        guard let index else { return nil }
        return config.tracks.first { $0.index == index }
    }

    init(config: RunConfig, environment: ToolEnvironment) {
        self.config = config
        self.environment = environment
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
        bridge?.requestCancel()
    }

    /// App is quitting: stop everything right away.
    func shutdown() {
        DockProgress.resetProgress()
        cancelFlag.cancel()
        bridge?.terminate()
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
        append(.info, "Rendering \(config.tracks.count) track(s) at \(config.width)×\(config.height), \(config.fps) fps")
        do {
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            let downloads = try await downloadPhase()
            try checkCancelled()
            let clips = try await renderPhase(downloads)
            try checkCancelled()
            output = try await concatPhase(clips)
            state = .finished
            phase = "done"
            headline = "Video Ready"
            detail = URL(fileURLWithPath: config.output).lastPathComponent
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
        bridge = nil
        if state == .finished {
            DockProgress.progress = 1  // animates to full, then shows the plain icon
        } else {
            DockProgress.resetProgress()
        }
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
            switch state {
            case .finished: Notifier.post(title: "Video Ready", body: URL(fileURLWithPath: config.output).lastPathComponent)
            case .failed(let message): Notifier.post(title: "Couldn’t Finish the Video", body: message)
            default: break
            }
        }
    }

    private func checkCancelled() throws {
        if cancelFlag.isCancelled { throw RenderCancelled() }
    }

    private func downloadPhase() async throws -> [Int: DownloadedTrack] {
        phase = "download"
        headline = "Downloading Songs"
        detail = "Finding each song and downloading its audio and artwork"
        let request = DownloadRequest(tracks: config.searchTracks, workers: config.workers, workdir: workdir.path)
        let process = BridgeProcess(environment: environment, arguments: ["download"])
        bridge = process
        let status = try await process.run(
            input: try request.encodedLine(),
            onMessage: { [weak self] message in self?.handleBridge(message) },
            onLog: { [weak self] line in self?.append(.output, line) }
        )
        bridge = nil
        if bridgeCancelled || cancelFlag.isCancelled { throw RenderCancelled() }
        guard let downloaded else {
            throw RunError(message: bridgeError ?? "The download step exited with status \(status).")
        }
        return Dictionary(downloaded.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func handleBridge(_ message: BridgeMessage) {
        switch message {
        case .progress(let ev):
            handleDownload(ev)
        case .downloaded(let tracks):
            downloaded = tracks
            for t in tracks {
                if let title = t.matchedVideoTitle, t.audioPath != nil {
                    append(.output, "  #\(t.index) matched “\(title)”")
                }
            }
        case .cancelled:
            bridgeCancelled = true
        case .error(let message, let detail):
            bridgeError = message
            if let detail { append(.output, detail) }
        default:
            break
        }
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
        guard !prepared.isEmpty else { throw RunError(message: "No tracks with audio. Aborting.") }

        // The GPU composites and the Media Engine encodes; a few clips in
        // flight keep both busy.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let workers = max(1, config.renderWorkers ?? min(prepared.count, max(2, min(4, cores / 2))))
        renderTotal = prepared.count
        renderCompleted = 0
        detail = "0 of \(prepared.count) songs rendered"
        append(.info, "Rendering \(prepared.count) clip(s), \(workers) at a time")

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
        guard !clips.isEmpty else { throw RunError(message: "No clips were rendered successfully. Aborting.") }
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
        return Output(videoPath: outputPath, descriptionPath: description.path, descriptionText: description.text)
    }

    // MARK: - Helpers

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
