@preconcurrency import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// Native encoding with AVFoundation + VideoToolbox (the Media Engine on
/// Apple silicon): frames are rendered by Core Image on the GPU into
/// IOSurface-backed pixel buffers and handed straight to the hardware
/// encoder; audio is decoded and re-encoded to AAC by AVFoundation; clips
/// are joined with a passthrough export. Port of the ffmpeg-based
/// playlist_video/encoding.py and render.py.

public enum VideoCodec: String, Sendable, CaseIterable {
    /// HEVC: smaller files at the same quality (default).
    case hevc
    /// H.264: plays everywhere.
    case h264

    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }

    public var summary: String {
        switch self {
        case .hevc: "HEVC (VideoToolbox), constant quality"
        case .h264: "H.264 (VideoToolbox), constant quality"
        }
    }
}

public struct ClipJob: Sendable {
    public var input: TrackRenderInput
    public var audioPath: String
    public var outputPath: String
    public var fps: Int
    public var codec: VideoCodec
    /// VideoToolbox constant quality, 0…1 (ffmpeg's `-q:v 65` == 0.65).
    public var quality: Double

    public init(
        input: TrackRenderInput, audioPath: String, outputPath: String, fps: Int,
        codec: VideoCodec = .hevc, quality: Double = 0.65
    ) {
        self.input = input
        self.audioPath = audioPath
        self.outputPath = outputPath
        self.fps = fps
        self.codec = codec
        self.quality = quality
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
    /// hands back Opus/WebM, which it can't).
    public static func canDecodeAudio(_ path: String) async -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return false }
        return (try? await asset.load(.isReadable)) ?? false
    }

    /// Converts unsupported audio to AAC with ffmpeg (already installed for
    /// yt-dlp). Returns a path AVFoundation can read.
    public static func readableAudio(_ path: String, workdir: URL, environment: [String: String]) async throws -> String {
        if await canDecodeAudio(path) { return path }
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let ffmpeg = dirs.map({ ($0 as NSString).appendingPathComponent("ffmpeg") })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw MediaError("Can't read \((path as NSString).lastPathComponent), and ffmpeg isn't installed to convert it.")
        }
        let out = workdir.appending(path: UUID().uuidString + ".m4a").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-loglevel", "error", "-i", path, "-vn", "-c:a", "aac", "-b:a", "256k", out]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        guard process.terminationStatus == 0 else { throw MediaError("ffmpeg couldn't convert \(path)") }
        return out
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

        let w = job.input.width, h = job.input.height
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: job.codec.avCodec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: job.quality,
                AVVideoMaxKeyFrameIntervalKey: job.fps * 10,
                AVVideoExpectedSourceFrameRateKey: job.fps,
                kVTCompressionPropertyKey_RealTime as String: false,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: false,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(video)

        // Audio: decode the download, re-encode as 48 kHz stereo AAC so every
        // clip concatenates cleanly.
        let asset = AVURLAsset(url: URL(fileURLWithPath: job.audioPath))
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaError("No audio track in \(job.audioPath)")
        }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(readerOutput)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(audio)

        guard reader.startReading() else {
            throw MediaError("Couldn't read audio: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard writer.startWriting() else {
            throw MediaError("Couldn't start encoding: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = TrackRenderer.frameCount(duration: job.input.duration, fps: job.fps)
        let end = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(job.fps))
        // A per-clip flag: a failure stops this clip only; a run cancel stops all.
        let clipCancel = CancellationFlag()
        cancel.whenCancelled { clipCancel.cancel() }
        let feeder = ClipFeeder(
            renderer: TrackRenderer(job.input), adaptor: adaptor, video: video, audio: audio,
            readerOutput: readerOutput, frames: frames, fps: job.fps, end: end,
            cancel: clipCancel, progress: progress
        )

        let failure = await feeder.run()
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
        guard writer.status == .completed else {
            throw MediaError("Encoding failed: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    // MARK: - Joining

    /// Join finished clips without re-encoding (the concat demuxer's job in Python).
    public static func concat(_ clips: [String], to output: String) async throws {
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

/// Feeds video frames and audio samples to the writer from their own serial
/// queues, as AVAssetWriter needs both inputs to advance together.
private final class ClipFeeder: @unchecked Sendable {
    private let renderer: TrackRenderer
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let readerOutput: AVAssetReaderTrackOutput
    private let frames: Int
    private let fps: Int
    private let end: CMTime
    private let cancel: CancellationFlag
    private let progress: @Sendable (Double) -> Void
    private let videoQueue = DispatchQueue(label: "PlaylistRender.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "PlaylistRender.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var failure: Error?
    private var frame = 0
    private var lastReported = -1.0

    init(
        renderer: TrackRenderer, adaptor: AVAssetWriterInputPixelBufferAdaptor, video: AVAssetWriterInput,
        audio: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput, frames: Int, fps: Int, end: CMTime,
        cancel: CancellationFlag, progress: @escaping @Sendable (Double) -> Void
    ) {
        self.renderer = renderer
        self.adaptor = adaptor
        self.video = video
        self.audio = audio
        self.readerOutput = readerOutput
        self.frames = frames
        self.fps = fps
        self.end = end
        self.cancel = cancel
        self.progress = progress
    }

    /// Returns the first error, if any, once both inputs are finished.
    func run() async -> Error? {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.feedVideo() }
            group.addTask { await self.feedAudio() }
        }
        return lock.withLock { failure }
    }

    private func fail(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
        cancel.cancel()
    }

    private func feedVideo() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            video.requestMediaDataWhenReady(on: videoQueue) { [self] in
                guard !finished else { return }
                while video.isReadyForMoreMediaData {
                    if cancel.isCancelled || frame >= frames {
                        finished = true
                        video.markAsFinished()
                        done.resume()
                        return
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        fail(MediaError("The encoder has no pixel buffer pool"))
                        continue
                    }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else {
                        fail(MediaError("Couldn't allocate a frame buffer"))
                        continue
                    }
                    let t = min(Double(frame) / Double(fps), renderer.input.duration)
                    autoreleasepool {
                        renderer.render(at: t, into: buffer)
                    }
                    let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                    if !adaptor.append(buffer, withPresentationTime: time) {
                        fail(MediaError("The encoder rejected frame \(frame)"))
                        continue
                    }
                    frame += 1
                    let fraction = Double(frame) / Double(frames)
                    if fraction - lastReported >= 0.005 || frame == frames {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
        }
    }

    private func feedAudio() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            audio.requestMediaDataWhenReady(on: audioQueue) { [self] in
                guard !finished else { return }
                while audio.isReadyForMoreMediaData {
                    guard !cancel.isCancelled, let sample = readerOutput.copyNextSampleBuffer(),
                          CMSampleBufferGetPresentationTimeStamp(sample) < end else {
                        finished = true
                        audio.markAsFinished()
                        done.resume()
                        return
                    }
                    if !audio.append(sample) {
                        fail(MediaError("The audio encoder rejected a sample"))
                    }
                }
            }
        }
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
