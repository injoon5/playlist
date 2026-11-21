import AVFoundation
import Foundation
import Synchronization

/// Per-track media: audio through yt-dlp, artwork over HTTP (port of
/// `playlist_video/downloader.py`), plus the parallel download phase
/// (`pipeline._download_phase`).
public struct MediaDownloader: Sendable {
    public var tools: ToolPaths
    public var session: URLSession
    /// Flat search; a timeout counts as "no results" (as in Python).
    public var searchTimeout: Duration = .seconds(60)
    /// One download attempt (one candidate × one player client).
    public var attemptTimeout: Duration = .seconds(15 * 60)

    public init(tools: ToolPaths, session: URLSession = .shared) {
        self.tools = tools
        self.session = session
    }

    public enum DownloadError: LocalizedError {
        case missingTool(Tool)

        public var errorDescription: String? {
            switch self {
            case .missingTool(let tool):
                return "\(tool.rawValue) isn’t installed. Install it with: \(ToolPaths.installCommand)"
            }
        }
    }

    // MARK: - Whole phase

    /// Downloads every track with `workers` in parallel, reporting
    /// pending → downloading (with slot + fraction) → ok / skipped / failed /
    /// cancelled for each, like the Python download phase. Returns results
    /// in track order. Throws `CancellationError` when the task is cancelled
    /// (which also stops every yt-dlp process).
    public func downloadAll(
        _ tracks: [PlaylistTrack],
        workers: Int,
        workdir: URL,
        events: AsyncStream<DownloadEvent>.Continuation? = nil
    ) async throws -> [DownloadedTrack] {
        let total = tracks.count
        let indexed = tracks.enumerated().map { i, t in (index: t.index ?? i + 1, track: t) }
        for (index, track) in indexed {
            events?.yield(.progress(ProgressEvent(
                phase: "download", completed: 0, total: total, message: "pending",
                trackIndex: index, trackLabel: track.label, trackStatus: DownloadStatus.pending.rawValue
            )))
        }
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)

        let workerCount = max(1, workers)
        let completed = Mutex(0)
        var results: [Int: DownloadedTrack] = [:]

        enum Outcome: Sendable {
            case finished(DownloadedTrack)
            case failed(String)
            case cancelled
        }

        await withTaskGroup(of: (slot: Int, index: Int, label: String, outcome: Outcome).self) { group in
            var freeSlots = Array(0..<workerCount)
            var next = 0
            while true {
                while next < indexed.count, !freeSlots.isEmpty, !Task.isCancelled {
                    let slot = freeSlots.removeFirst()
                    let (index, track) = indexed[next]
                    next += 1
                    group.addTask {
                        let label = track.label
                        let throttle = Mutex(ContinuousClock.Instant?.none)
                        let report: @Sendable (Double) -> Void = { fraction in
                            let now = ContinuousClock.now
                            let send = throttle.withLock { last -> Bool in
                                if fraction < 1, let previous = last, now - previous < .milliseconds(50) { return false }
                                last = now
                                return true
                            }
                            guard send else { return }
                            events?.yield(.progress(ProgressEvent(
                                phase: "download", completed: completed.withLock { $0 }, total: total,
                                message: "Downloading \(label)", trackIndex: index, trackLabel: label,
                                trackStatus: DownloadStatus.downloading.rawValue, slotId: slot, fraction: fraction
                            )))
                        }
                        report(0)
                        let outcome: Outcome
                        do {
                            let result = try await downloadTrack(
                                track, index: index, workdir: workdir, onFraction: report,
                                log: { events?.yield(.log($0)) }
                            )
                            outcome = .finished(result)
                        } catch {
                            outcome = Task.isCancelled || error is CancellationError
                                ? .cancelled : .failed(error.localizedDescription)
                        }
                        // The slot is free again (Python's `finally`).
                        events?.yield(.progress(ProgressEvent(
                            phase: "download", completed: completed.withLock { $0 }, total: total, message: "",
                            trackIndex: index, trackLabel: label, slotId: slot
                        )))
                        return (slot, index, label, outcome)
                    }
                }
                guard let finished = await group.next() else { break }
                freeSlots.append(finished.slot)
                let done = completed.withLock { count in
                    count += 1
                    return count
                }
                let status: DownloadStatus
                switch finished.outcome {
                case .finished(let result):
                    results[finished.index] = result
                    // No usable YouTube match is "skipped", as in Python.
                    status = result.audioPath == nil ? .skipped : .ok
                case .failed(let message):
                    events?.yield(.log("  [\(done)/\(total)] \(finished.label): failed (\(message))"))
                    status = .failed
                case .cancelled:
                    status = .cancelled
                }
                events?.yield(.progress(ProgressEvent(
                    phase: "download", completed: done, total: total,
                    message: "\(finished.label): \(status.rawValue)",
                    trackIndex: finished.index, trackLabel: finished.label, trackStatus: status.rawValue,
                    fraction: status == .ok ? 1 : nil
                )))
            }
        }
        try Task.checkCancellation()
        return indexed.map { results[$0.index] ?? DownloadedTrack(index: $0.index) }
    }

    // MARK: - One track

    /// Artwork, then audio, then artwork again if the first try failed or
    /// there was no artwork URL and the video's thumbnail filled one in
    /// (`download_track_media`).
    public func downloadTrack(
        _ track: PlaylistTrack,
        index: Int,
        workdir: URL,
        onFraction: @escaping @Sendable (Double) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> DownloadedTrack {
        try Task.checkCancellation()
        var result = DownloadedTrack(index: index)
        result.artworkPath = await downloadArtwork(track.artworkUrl, index: index, workdir: workdir, log: log)
        let audio = try await downloadAudio(track, index: index, workdir: workdir, onFraction: onFraction, log: log)
        if let audio {
            result.audioPath = audio.path
            result.matchedVideoTitle = audio.title
            result.durationSec = audio.duration
        }
        if result.artworkPath == nil, let url = track.artworkUrl ?? audio?.thumbnail {
            result.artworkPath = await downloadArtwork(url, index: index, workdir: workdir, log: log)
        }
        return result
    }

    struct AudioResult: Sendable {
        var path: String
        var title: String?
        var thumbnail: String?
        var duration: Double?
    }

    /// Search, try candidates best-first, reject duration mismatches.
    /// Returns nil when nothing usable was found.
    func downloadAudio(
        _ track: PlaylistTrack, index: Int, workdir: URL,
        onFraction: @escaping @Sendable (Double) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> AudioResult? {
        let label = track.label
        guard let ytDlp = tools.ytDlp else {
            log("  ! download failed for '\(label)': \(DownloadError.missingTool(.ytDlp).localizedDescription)")
            return nil
        }
        let query = YTDLP.searchQuery(artist: track.artist, title: track.title)
        let safe = YTDLP.safeName(index: index, artist: track.artist, title: track.title)

        var candidates: [YTDLP.Candidate]
        do {
            candidates = try await search(query, ytDlp: ytDlp)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // yt-dlp couldn't even start: give up on this song (Python returns None too).
            log("  ! download failed for '\(label)': \(error.localizedDescription)")
            return nil
        }
        if candidates.isEmpty { candidates = [.searchFallback] }
        var lastError: String?

        for candidate in YTDLP.rank(candidates, expectedMs: track.durationMs) {
            try Task.checkCancellation()
            let target: String
            let template: String
            if candidate.isSearchFallback {
                target = "ytsearch1:\(query)"
                template = workdir.appending(path: "\(safe).%(ext)s").path
            } else {
                // Unique name per candidate so retries don't collide.
                target = YTDLP.watchURL(candidate.id)
                template = workdir.appending(path: "\(safe)_\(candidate.id).%(ext)s").path
            }
            let attempt = try await download(target, outputTemplate: template, ytDlp: ytDlp, onFraction: onFraction)
            guard let path = attempt.path else {
                lastError = attempt.error ?? "unknown yt-dlp failure"
                continue
            }
            let actual = await probeDuration(path)
            if YTDLP.durationMismatch(expectedMs: track.durationMs, actualSec: actual) {
                let expected = Double(track.durationMs ?? 0) / 1000
                let got = actual ?? 0
                let hit = attempt.title ?? (candidate.title.isEmpty ? nil : candidate.title)
                log("  ! duration mismatch for '\(label)' (expected ~\(Int(expected.rounded()))s, got \(Int(got.rounded()))s\(hit.map { ", hit: \($0)" } ?? "")) — trying next candidate")
                try? FileManager.default.removeItem(atPath: path)
                lastError = "duration mismatch: expected ~\(Int(expected.rounded()))s, got \(Int(got.rounded()))s — likely wrong YouTube hit"
                continue
            }
            let title = attempt.title ?? (candidate.title.isEmpty ? nil : candidate.title)
            return AudioResult(path: path, title: title, thumbnail: attempt.thumbnail, duration: actual)
        }
        log("  ! download failed for '\(label)': \(lastError ?? "no results")\(YTDLP.failureHint(lastError))")
        return nil
    }

    func search(_ query: String, ytDlp: URL) async throws -> [YTDLP.Candidate] {
        let result = try await ChildProcess.run(
            ytDlp, YTDLP.searchArguments(query: query, runtimes: .init(tools)),
            environment: tools.environment, timeout: searchTimeout
        )
        if result.timedOut { return [] }
        return YTDLP.parseSearchOutput(result.lines)
    }

    struct Attempt: Sendable {
        var path: String?
        var thumbnail: String?
        var title: String?
        var error: String?
    }

    /// One video (or `ytsearch1:`) through each player client until one works.
    func download(
        _ target: String, outputTemplate: String, ytDlp: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> Attempt {
        var lastError: String?
        let ffmpegDir = tools.ffmpeg?.deletingLastPathComponent().path
        for client in YTDLP.clientFallbacks {
            try Task.checkCancellation()
            let seen = Mutex(Attempt())
            let args = YTDLP.downloadArguments(
                target: target, client: client, outputTemplate: outputTemplate,
                ffmpegLocation: ffmpegDir, runtimes: .init(tools)
            )
            let result: ProcessResult
            do {
                result = try await ChildProcess.run(
                    ytDlp, args, environment: tools.environment, timeout: attemptTimeout
                ) { line in
                    switch YTDLP.classify(line) {
                    case .thumbnail(let v): seen.withLock { $0.thumbnail = v }
                    case .title(let v): seen.withLock { $0.title = v }
                    case .path(let v): seen.withLock { $0.path = v }
                    case .progress(let f): onFraction(f)
                    case .progressUnknown, .other: break
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
                continue
            }
            if result.timedOut {
                lastError = "yt-dlp timed out"
                continue
            }
            var attempt = seen.withLock { $0 }
            if let path = attempt.path, FileManager.default.fileExists(atPath: path) {
                onFraction(1)
                attempt.error = nil
                return attempt
            }
            lastError = YTDLP.lastError(in: result.lines)
        }
        return Attempt(error: lastError)
    }

    /// Container duration in seconds via ffprobe (AVFoundation if ffprobe is
    /// missing), or nil.
    public func probeDuration(_ path: String) async -> Double? {
        if let ffprobe = tools.ffprobe {
            let args = ["-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", path]
            if let result = try? await ChildProcess.run(ffprobe, args, environment: tools.environment, timeout: .seconds(30)),
               result.status == 0,
               let value = result.lines.lazy.compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }).first {
                return value
            }
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = duration.seconds
        return seconds > 0 ? seconds : nil
    }

    /// Saves artwork as `art_NNN.jpg` (`download_artwork`).
    func downloadArtwork(_ urlString: String?, index: Int, workdir: URL, log: @Sendable (String) -> Void) async -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let path = workdir.appending(path: String(format: "art_%03d.jpg", index))
            try data.write(to: path)
            return path.path
        } catch {
            if !Task.isCancelled { log("  ! artwork download failed: \(error.localizedDescription)") }
            return nil
        }
    }
}
