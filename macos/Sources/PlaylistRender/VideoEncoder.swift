@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// A VideoToolbox compression session (the Media Engine) whose output is
/// passed through to an AVAssetWriter input (see `output`).
///
/// Driving VideoToolbox directly, rather than letting AVAssetWriter encode,
/// lets the clip choose where keyframes go: the first frame is black (the
/// fade-in), so the picture is otherwise built up by P-frames during the fade
/// and kept at that quality until the next scheduled keyframe. Forcing one
/// keyframe as soon as the picture is steady, then keeping the GOP long,
/// gives a sharper picture *and* a smaller file for this mostly static video.
final class VideoEncoder: @unchecked Sendable {
    private let session: VTCompressionSession
    private let lock = NSLock()
    /// Frames submitted but not yet written; bounds memory and keeps the
    /// renderer from running far ahead of the encoder.
    private let capacity: DispatchSemaphore
    private var failure: Error?

    /// Encoded frames in decode order, for the writer. Frames encoded before
    /// the writer starts (the first one, which tells it the stream's format)
    /// wait here; compressed frames are small, so the buffer is unbounded.
    let output: AsyncStream<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    private let outputContinuation: AsyncStream<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>.Continuation

    /// Format of the encoded stream, known once the first frame is out.
    private(set) var formatDescription: CMFormatDescription?

    init(job: ClipJob) throws {
        (output, outputContinuation) = AsyncStream.makeStream()
        let width = job.input.width, height = job.input.height
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: job.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw MediaError("Couldn't start the video encoder (\(status))") }
        self.session = session
        for (key, value) in Self.properties(job) {
            let status = VTSessionSetProperty(session, key: key as CFString, value: value as CFTypeRef)
            // Optional tuning keys may be unsupported by some encoders; core ones aren't.
            if status != noErr, Self.required.contains(key) {
                VTCompressionSessionInvalidate(session)
                throw MediaError("The video encoder rejected \(key) (\(status))")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        capacity = DispatchSemaphore(value: 12)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    private static let required: Set<String> = [
        kVTCompressionPropertyKey_Quality as String,
        kVTCompressionPropertyKey_MaxKeyFrameInterval as String,
    ]

    /// Measured on 1080p30 clips against a ProRes 4444 reference: the
    /// Media Engine is the bottleneck either way, and these settings keep
    /// text edges and photo grain while spending few bits on static frames.
    static func properties(_ job: ClipJob) -> [String: Any] {
        var properties: [String: Any] = [
            kVTCompressionPropertyKey_Quality as String: job.quality ?? job.codec.defaultQuality,
            // Long GOP: the picture barely changes, so keyframes are most of
            // the bits (YouTube re-encodes anyway). See `keyFrames`.
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: job.fps * Self.keyFrameSeconds,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String: Self.keyFrameSeconds,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: job.fps,
            kVTCompressionPropertyKey_RealTime as String: false,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: job.prioritizeSpeed,
            kVTCompressionPropertyKey_ColorPrimaries as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        switch job.codec {
        case .hevc:
            properties[kVTCompressionPropertyKey_ProfileLevel as String] = kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264:
            properties[kVTCompressionPropertyKey_ProfileLevel as String] = kVTProfileLevel_H264_High_AutoLevel
            properties[kVTCompressionPropertyKey_H264EntropyMode as String] = kVTH264EntropyMode_CABAC
        }
        return properties
    }

    /// Longest stretch without a keyframe.
    static let keyFrameSeconds = 60

    /// Frames that should be keyframes besides the scheduled ones: the first
    /// steady frame after the fade-in.
    static func keyFrames(for input: TrackRenderInput, fps: Int) -> Set<Int> {
        guard let steady = TrackRenderer.firstSteadyTime(of: input) else { return [0] }
        let frame = Int((steady * Double(fps) - 1e-9).rounded(.up))
        return frame > 0 && Double(frame) / Double(fps) < input.duration ? [0, frame] : [0]
    }

    var pixelBufferPool: CVPixelBufferPool? { VTCompressionSessionGetPixelBufferPool(session) }

    /// Submits one frame. Blocks while too many frames are in flight (a soft
    /// limit: if the encoder ever holds more frames than that before emitting
    /// one, waiting times out instead of deadlocking).
    func encode(_ buffer: CVPixelBuffer, frame: Int, fps: Int, keyFrame: Bool) throws {
        _ = capacity.wait(timeout: .now() + 1)
        if let failure = lock.withLock({ failure }) {
            capacity.signal()
            throw failure
        }
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: options, infoFlagsOut: nil
        ) { [self] status, _, sample in
            defer { capacity.signal() }
            guard status == noErr else {
                record(MediaError("The video encoder failed on frame \(frame) (\(status))"))
                return
            }
            guard let sample else { return }  // dropped frame: nothing to write
            deliver(sample)
        }
        if status != noErr {
            capacity.signal()
            throw MediaError("The video encoder rejected frame \(frame) (\(status))")
        }
    }

    /// Waits for every submitted frame to come out of the encoder.
    func flush() throws {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if let failure = lock.withLock({ failure }) { throw failure }
    }

    /// Ends `output` once no more frames will be submitted.
    func finishOutput() {
        outputContinuation.finish()
    }

    private func record(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    private func deliver(_ sample: CMSampleBuffer) {
        lock.withLock {
            if formatDescription == nil { formatDescription = CMSampleBufferGetFormatDescription(sample) }
        }
        // VideoToolbox hands over each sample once and keeps no reference.
        nonisolated(unsafe) let owned = sample
        outputContinuation.yield(CMReadySampleBuffer(unsafeBuffer: owned))
    }
}
