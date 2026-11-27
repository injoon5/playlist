@preconcurrency import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// Native encoding with AVFoundation + VideoToolbox (the Media Engine on
/// Apple silicon): frames are rendered by Core Image on the GPU into
/// IOSurface-backed pixel buffers and handed straight to the hardware
/// encoder; the downloaded audio is copied into the clip untouched (see
/// Audio.swift); clips are joined with a passthrough export. Port of the
/// ffmpeg-based playlist_video/encoding.py and render.py.

public enum VideoCodec: String, Sendable, CaseIterable {
    /// HEVC: smaller files at the same quality (default).
    case hevc
    /// H.264: plays everywhere.
    case h264

    public var summary: String {
        switch self {
        case .hevc: "HEVC (VideoToolbox), constant quality"
        case .h264: "H.264 (VideoToolbox), constant quality"
        }
    }

    /// VideoToolbox constant quality (ffmpeg's `-q:v 65`). Lower settings
    /// visibly soften photo backgrounds (VMAF −2…−7 at 0.6…0.55); the size
    /// savings come from keyframe placement instead (see VideoEncoder).
    public var defaultQuality: Double { 0.65 }
}

public struct ClipJob: Sendable {
    public var input: TrackRenderInput
    public var audioPath: String
    public var outputPath: String
    public var fps: Int
    public var codec: VideoCodec
    /// VideoToolbox constant quality, 0…1 (nil: the codec's tuned default).
    public var quality: Double?
    /// Trade file size for speed: the Media Engine's fast mode encodes ~1.6×
    /// faster but needs noticeably more bits for the same picture.
    public var prioritizeSpeed: Bool
    /// Soundtrack handling; nil copies the source untouched when it can.
    public var audio: ClipAudio?

    public init(
        input: TrackRenderInput, audioPath: String, outputPath: String, fps: Int,
        codec: VideoCodec = .hevc, quality: Double? = nil, prioritizeSpeed: Bool = false, audio: ClipAudio? = nil
    ) {
        self.input = input
        self.audioPath = audioPath
        self.outputPath = outputPath
        self.fps = fps
        self.codec = codec
        self.quality = quality
        self.prioritizeSpeed = prioritizeSpeed
        self.audio = audio
    }
}

public struct RenderCancelled: Error {
    public init() {}
}

public struct MediaError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thread-safe cancellation flag shared between the UI and render jobs.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            defer { onCancel.removeAll() }
            return onCancel
        }
        handlers.forEach { $0() }
    }

    /// Runs `handler` on cancel (immediately if already cancelled).
    func whenCancelled(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            onCancel.append(handler)
            return false
        }
        if runNow { handler() }
    }
}

public enum Media {
    /// Duration of an audio or video file, in seconds.
    public static func duration(of path: String) async throws -> Double {
        let seconds = try await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw MediaError("Couldn't read the duration of \(path)") }
        return seconds
    }

    /// Whether AVFoundation can decode this file's audio (yt-dlp sometimes
    /// hands back containers older macOS versions can't open).
    public static func canDecodeAudio(_ path: String) async -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return false }
        return (try? await asset.load(.isReadable)) ?? false
    }

    /// Containers that are always copied into an MP4 first, even when
    /// AVFoundation opens them: macOS 27 reads Ogg Opus but estimates its
    /// duration (236.4 s for a 230.05 s song), which would leave seconds of
    /// silent video at the end of the clip. MP4 has an exact index.
    static let remuxedContainers: Set<String> = ["opus", "ogg", "oga", "webm", "weba", "mka", "mkv"]

    /// Makes audio AVFoundation can't read (or can't time exactly) readable
    /// with ffmpeg (already installed for yt-dlp), without a lossy step where
    /// possible. Returns a path AVFoundation can read.
    public static func readableAudio(_ path: String, workdir: URL, environment: [String: String]) async throws -> String {
        let needsRemux = remuxedContainers.contains((path as NSString).pathExtension.lowercased())
        let decodable = await canDecodeAudio(path)
        if decodable, !needsRemux { return path }
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let ffmpeg = dirs.map({ ($0 as NSString).appendingPathComponent("ffmpeg") })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            if decodable { return path }  // better an estimated length than nothing
            throw MediaError("Can't read \((path as NSString).lastPathComponent), and ffmpeg isn't installed to convert it.")
        }
        // First copy the stream into an MP4 (Opus from WebM/Ogg, AAC from
        // other containers): lossless, and the clip then passes it through.
        let remuxed = workdir.appending(path: UUID().uuidString + ".mp4").path
        if await runFFmpeg(ffmpeg, ["-i", path, "-vn", "-map", "0:a:0", "-c:a", "copy", remuxed]),
           await canDecodeAudio(remuxed) {
            return remuxed
        }
        try? FileManager.default.removeItem(atPath: remuxed)
        // Otherwise decode to lossless ALAC; the clip then encodes it once with
        // Apple's AAC encoder (no extra lossy ffmpeg generation in between).
        let lossless = workdir.appending(path: UUID().uuidString + ".m4a").path
        guard await runFFmpeg(ffmpeg, ["-i", path, "-vn", "-map", "0:a:0", "-c:a", "alac", lossless]) else {
            throw MediaError("ffmpeg couldn't convert \(path)")
        }
        return lossless
    }

    private static func runFFmpeg(_ ffmpeg: String, _ arguments: [String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-loglevel", "error"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { p in c.resume(returning: p.terminationReason == .exit && p.terminationStatus == 0) }
            do { try process.run() } catch { c.resume(returning: false) }
        }
    }

    // MARK: - Clips

    /// Render and encode one clip. `progress` gets the fraction of frames written.
    public static func renderClip(
        _ job: ClipJob, cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if cancel.isCancelled { throw RenderCancelled() }
        let url = URL(fileURLWithPath: job.outputPath)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // moov up front, like +faststart

        // A per-clip flag: a failure stops this clip only; a run cancel stops all.
        let clipCancel = CancellationFlag()
        cancel.whenCancelled { clipCancel.cancel() }

        // Video: VideoToolbox encodes, the writer only muxes. The first frame
        // is encoded up front because the writer needs the stream's format.
        let frames = TrackRenderer.frameCount(duration: job.input.duration, fps: job.fps)
        let end = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(job.fps))
        let encoder = try VideoEncoder(job: job)
        let feeder = ClipFeeder(
            renderer: TrackRenderer(job.input), encoder: encoder,
            keyFrames: VideoEncoder.keyFrames(for: job.input, fps: job.fps),
            frames: frames, fps: job.fps, end: end, cancel: clipCancel, progress: progress
        )
        try feeder.encodeFirstFrame()
        guard let videoFormat = encoder.formatDescription else {
            throw MediaError("The video encoder produced no output")
        }
        let video = writer.inputReceiver(
            for: AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        )

        // Audio: copy the download's packets untouched when the MP4 can hold
        // them (AAC/Opus from YouTube: no generation loss, source bitrate);
        // otherwise encode once to AAC-LC. Packets past the clip's end are
        // trimmed sample-accurately by the edit list `endSession` writes.
        let asset = AVURLAsset(url: URL(fileURLWithPath: job.audioPath))
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaError("No audio track in \(job.audioPath)")
        }
        let sourceFormat = try await audioTrack.load(.formatDescriptions).first
        var plan = job.audio ?? audioPlan(for: sourceFormat)
        var audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormat)
        if plan == .passthrough, !writer.canAdd(audio) {
            plan = audioPlan(for: nil)
        }
        let readerOutput: AVAssetReaderTrackOutput
        switch plan {
        case .passthrough:
            readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        case let .aac(sampleRate, channels, bitRate):
            readerOutput = AVAssetReaderTrackOutput(
                track: audioTrack, outputSettings: pcmSettings(sampleRate: sampleRate, channels: channels)
            )
            audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: aacSettings(sampleRate: sampleRate, channels: channels, bitRate: bitRate)
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let audioSource = reader.outputProvider(for: readerOutput)
        let audioSink = writer.inputReceiver(for: audio)

        do {
            try reader.start()
        } catch {
            throw MediaError("Couldn't read audio: \(error.localizedDescription)")
        }
        do {
            try writer.start()
        } catch {
            throw MediaError("Couldn't start encoding: \(error.localizedDescription)")
        }
        writer.startSession(atSourceTime: .zero)

        let failure = await feeder.run(video: video, audio: audioSink, audioSource: audioSource)
        if cancel.isCancelled || failure != nil {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: url)
            if let failure, !cancel.isCancelled { throw failure }
            throw RenderCancelled()
        }
        // Like ffmpeg's -shortest: the clip ends with the last video frame.
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        reader.cancelReading()  // the rest of the song isn't needed
        guard writer.status == .completed else {
            throw MediaError("Encoding failed: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    // MARK: - Joining

    /// Join finished clips without re-encoding (the concat demuxer's job in Python).
    ///
    /// Clips whose audio formats differ (e.g. HE-AAC and AAC-LC downloads in
    /// one playlist) can't share one MP4 audio track, so the odd ones out get
    /// their audio converted first (`normalizeAudio`); the rest stay bit-exact.
    public static func concat(_ clips: [String], to output: String) async throws {
        let (clips, converted) = try await normalizeAudio(clips)
        defer { for path in converted { try? FileManager.default.removeItem(atPath: path) } }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError("Couldn't create the composition") }

        var cursor = CMTime.zero
        for path in clips {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: v, at: cursor)
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                // Audio may run a hair longer than video; never past the clip end.
                let audioDuration = try await a.load(.timeRange).duration
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: a, at: cursor)
            }
            cursor = cursor + duration
        }

        let url = URL(fileURLWithPath: output)
        try? FileManager.default.removeItem(at: url)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError("Couldn't create the export session")
        }
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: url, as: .mp4)
    }

    /// Ready-to-paste YouTube chapters, `{timestamp} {title} - {artist}`,
    /// written next to the video as `<name>_description.txt`.
    public static func writeDescription(
        entries: [(title: String, artist: String, clipPath: String)], videoPath: String
    ) async throws -> (path: String, text: String) {
        var lines: [String] = []
        var t = 0.0
        for entry in entries {
            lines.append("\(formatTimestamp(t)) \(entry.title) - \(entry.artist)")
            t += try await duration(of: entry.clipPath)
        }
        let text = lines.joined(separator: "\n") + "\n"
        let path = (videoPath as NSString).deletingPathExtension + "_description.txt"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, text)
    }
}

/// Renders and encodes video frames on a serial queue while two tasks feed
/// the writer the encoded video and the audio; AVAssetWriter interleaves them,
/// suspending whichever input is ahead.
private final class ClipFeeder: @unchecked Sendable {
    private let renderer: TrackRenderer
    private let encoder: VideoEncoder
    private let keyFrames: Set<Int>
    private let frames: Int
    private let fps: Int
    private let end: CMTime
    private let cancel: CancellationFlag
    private let progress: @Sendable (Double) -> Void
    private let videoQueue = DispatchQueue(label: "PlaylistRender.video", qos: .userInitiated)
    private let lock = NSLock()
    private var failure: Error?
    private var frame = 0
    private var lastReported = -1.0

    init(
        renderer: TrackRenderer, encoder: VideoEncoder, keyFrames: Set<Int>, frames: Int, fps: Int, end: CMTime,
        cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void
    ) {
        self.renderer = renderer
        self.encoder = encoder
        self.keyFrames = keyFrames
        self.frames = frames
        self.fps = fps
        self.end = end
        self.cancel = cancel
        self.progress = progress
    }

    /// Encodes frame 0 and waits for it, so the stream's format is known.
    func encodeFirstFrame() throws {
        try encodeNextFrame()
        try encoder.flush()
    }

    typealias Sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

    /// Returns the first error, if any, once both inputs are finished.
    func run(
        video: sending AVAssetWriterInput.SampleBufferReceiver,
        audio: sending AVAssetWriterInput.SampleBufferReceiver,
        audioSource: sending AVAssetReaderOutput.Provider<Sample>
    ) async -> Error? {
        nonisolated(unsafe) let video = video, audio = audio, audioSource = audioSource
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.renderVideo() }
            group.addTask { await self.writeVideo(video) }
            group.addTask { await self.writeAudio(audio, from: audioSource) }
        }
        return lock.withLock { failure }
    }

    private func fail(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
        cancel.cancel()
    }

    /// Renders and encodes the remaining frames on `videoQueue` (GPU and
    /// encoder waits block, so they stay off the cooperative pool).
    private func renderVideo() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            videoQueue.async { [self] in
                do {
                    while frame < frames, !cancel.isCancelled { try encodeNextFrame() }
                    try encoder.flush()
                } catch {
                    fail(error)
                }
                encoder.finishOutput()
                done.resume()
            }
        }
    }

    /// Hands encoded frames to the writer as it's ready for them.
    private func writeVideo(_ video: AVAssetWriterInput.SampleBufferReceiver) async {
        do {
            for await sample in encoder.output {
                if cancel.isCancelled { break }
                try await video.append(sample)
            }
        } catch {
            fail(MediaError("The writer rejected a video frame: \(error.localizedDescription)"))
        }
        video.finish()
    }

    /// Renders the next frame on the GPU straight into one of the encoder's
    /// IOSurface buffers and submits it (blocks while the encoder is full).
    private func encodeNextFrame() throws {
        guard let pool = encoder.pixelBufferPool else { throw MediaError("The encoder has no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw MediaError("Couldn't allocate a frame buffer") }
        let t = min(Double(frame) / Double(fps), renderer.input.duration)
        autoreleasepool {
            renderer.render(at: t, into: buffer)
        }
        try encoder.encode(buffer, frame: frame, fps: fps, keyFrame: keyFrames.contains(frame))
        frame += 1
        let fraction = Double(frame) / Double(frames)
        if fraction - lastReported >= 0.005 || frame == frames {
            lastReported = fraction
            progress(fraction)
        }
    }

    private func writeAudio(
        _ audio: AVAssetWriterInput.SampleBufferReceiver, from source: AVAssetReaderOutput.Provider<Sample>
    ) async {
        // Passed-through packets are timed in media time, which includes the
        // encoder's priming; read a little past the end so the last frame is
        // complete and let the edit list written by `endSession` cut the
        // audio sample-accurately at the last video frame.
        let cutoff = end + CMTime(seconds: 0.5, preferredTimescale: 48_000)
        do {
            while !cancel.isCancelled, let sample = try await source.next(), sample.presentationTimeStamp < cutoff {
                try await audio.append(sample)
            }
        } catch {
            fail(MediaError("Couldn't copy the audio: \(error.localizedDescription)"))
        }
        audio.finish()
    }
}

/// m:ss, switching to h:mm:ss past one hour.
public func formatTimestamp(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}
