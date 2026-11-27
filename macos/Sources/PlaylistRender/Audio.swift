@preconcurrency import AVFoundation
import Foundation

/// How a clip's soundtrack gets into the video.
///
/// The downloads are already lossy (AAC or Opus from YouTube), so the
/// soundtrack is copied bit-for-bit whenever the MP4 can hold it
/// ("passthrough"): no generation loss, and the file stays as small as the
/// source. Anything else (lossless or exotic formats) is encoded once to
/// AAC-LC at a transparent bitrate.
public enum ClipAudio: Sendable, Equatable {
    /// Copy the source's compressed packets as-is (default when possible).
    case passthrough
    /// Encode to AAC-LC.
    case aac(sampleRate: Double, channels: Int, bitRate: Int)

    /// AAC-LC bitrate used whenever audio has to be (re-)encoded. Apple's
    /// encoder is transparent well below this for stereo.
    static let transparentStereoBitRate = 256_000
}

/// Identity of a compressed audio stream for joining: clips whose
/// signatures match can be concatenated without re-encoding, because a
/// decoder configured for one decodes the others correctly.
struct AudioSignature: Hashable, Sendable, CustomStringConvertible {
    var formatID: AudioFormatID
    var sampleRate: Double
    var channels: UInt32
    /// AAC: the AudioSpecificConfig (object type, rate, channels, SBR/PS
    /// signalling). Other formats: empty (their cookie carries per-file
    /// details like Opus pre-skip that don't affect decoding).
    var config: [UInt8]

    init(formatID: AudioFormatID, sampleRate: Double, channels: UInt32, config: [UInt8]) {
        self.formatID = formatID
        self.sampleRate = sampleRate
        self.channels = channels
        self.config = config
    }

    init(_ format: CMAudioFormatDescription) {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee ?? AudioStreamBasicDescription()
        formatID = asbd.mFormatID
        sampleRate = asbd.mSampleRate
        channels = asbd.mChannelsPerFrame
        if AudioSignature.aacFormats.contains(asbd.mFormatID) {
            var size = 0
            if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size), size > 0 {
                let bytes = [UInt8](UnsafeRawBufferPointer(start: cookie, count: size))
                // Fall back to the whole cookie (stricter) if it isn't an ES descriptor.
                var asc = AudioSignature.audioSpecificConfig(fromESDS: bytes) ?? bytes
                // YouTube pads its config with zero bytes (`1210 0000…`); decoders
                // stop reading before them, so `1210` is the same stream format.
                while asc.count > 2, asc.last == 0 { asc.removeLast() }
                config = asc
            } else {
                config = []
            }
        } else {
            config = []
        }
    }

    static let aacFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
    ]

    /// Plain stereo AAC-LC at 44.1 or 48 kHz: what Apple's encoder produces,
    /// so other clips can be converted to match it.
    var isEncodableAACLC: Bool {
        formatID == kAudioFormatMPEG4AAC && channels == 2 && (sampleRate == 44_100 || sampleRate == 48_000)
            && config.count == 2 && config[0] >> 3 == 2  // AOT 2 (LC), no SBR/PS extension
    }

    var description: String {
        let id = withUnsafeBytes(of: formatID.bigEndian) { String(decoding: $0, as: UTF8.self) }
        return "\(id) \(Int(sampleRate)) Hz \(channels)ch [\(config.map { String(format: "%02x", $0) }.joined())]"
    }

    /// The DecoderSpecificInfo (AudioSpecificConfig) inside an MPEG-4 ES
    /// descriptor (the `esds` payload AVFoundation uses as the AAC cookie).
    static func audioSpecificConfig(fromESDS bytes: [UInt8]) -> [UInt8]? {
        var i = 0
        func descriptor(_ tag: UInt8) -> Int? {  // returns payload length, `i` at payload
            guard i < bytes.count, bytes[i] == tag else { return nil }
            i += 1
            var length = 0
            for _ in 0..<4 {
                guard i < bytes.count else { return nil }
                let b = bytes[i]
                i += 1
                length = length << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            return length
        }
        // Some cookies carry a 4-byte version/flags header (full `esds` box).
        if bytes.first != 0x03, bytes.count > 4, bytes[4] == 0x03 { i = 4 }
        guard descriptor(0x03) != nil, i + 3 <= bytes.count else { return nil }
        let flags = bytes[i + 2]
        i += 3
        if flags & 0x80 != 0 { i += 2 }
        if flags & 0x40 != 0 { guard i < bytes.count else { return nil }; i += 1 + Int(bytes[i]) }
        if flags & 0x20 != 0 { i += 2 }
        guard descriptor(0x04) != nil else { return nil }
        i += 13
        guard let length = descriptor(0x05), length > 0, i + length <= bytes.count else { return nil }
        return Array(bytes[i..<(i + length)])
    }
}

extension Media {
    /// Formats copied into the MP4 untouched. (AVFoundation decodes all of
    /// them, and so does YouTube.)
    static let passthroughFormats: Set<AudioFormatID> = AudioSignature.aacFormats.union([
        kAudioFormatOpus, kAudioFormatMPEGLayer3,
    ])

    /// The audio settings a clip should use for `format` (its first audio track).
    static func audioPlan(for format: CMAudioFormatDescription?) -> ClipAudio {
        if let format, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           passthroughFormats.contains(asbd.mFormatID) {
            return .passthrough
        }
        let rate = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        return .aac(
            sampleRate: rate == 44_100 ? 44_100 : 48_000, channels: 2,
            bitRate: ClipAudio.transparentStereoBitRate
        )
    }

    /// The audio signature of a finished clip, nil if it has no audio.
    static func audioSignature(of path: String) async throws -> AudioSignature? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await track.load(.formatDescriptions).first else { return nil }
        return AudioSignature(format)
    }

    /// Whether every clip's audio can be joined without re-encoding.
    static func audioIsUniform(_ clips: [String]) async throws -> Bool {
        var signatures = Set<AudioSignature?>()
        for clip in clips { signatures.insert(try await audioSignature(of: clip)) }
        return signatures.count <= 1
    }

    /// Makes every clip's audio joinable. Clips already in the dominant
    /// AAC-LC format keep their audio untouched; the others get their audio
    /// converted once to match (video is copied). Returns the clip list to
    /// join (converted clips are new files in the same folder).
    static func normalizeAudio(_ clips: [String]) async throws -> (clips: [String], converted: [String]) {
        var signatures: [AudioSignature?] = []
        var durations: [Double] = []
        for clip in clips {
            signatures.append(try await audioSignature(of: clip))
            durations.append(try await duration(of: clip))
        }
        guard Set(signatures).count > 1 else { return (clips, []) }

        // Keep the AAC-LC format that covers the most running time; with
        // none, convert everything to 48 kHz AAC-LC.
        var time: [AudioSignature: Double] = [:]
        for (signature, seconds) in zip(signatures, durations) {
            if let signature, signature.isEncodableAACLC { time[signature, default: 0] += seconds }
        }
        let keep = time.max { $0.value < $1.value }?.key
        let sampleRate = keep?.sampleRate ?? 48_000

        var converted: [String: String] = [:]  // clip → converted copy (a clip may repeat)
        func convert(_ paths: [String]) async throws {
            let todo = Array(Set(paths).subtracting(converted.keys))
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                for clip in todo {
                    let out = (clip as NSString).deletingPathExtension + ".joinaudio-\(UUID().uuidString).mp4"
                    group.addTask {
                        let settings = ClipAudio.aac(
                            sampleRate: sampleRate, channels: 2,
                            bitRate: conversionBitRate(source: try await audioBitRate(of: clip))
                        )
                        try await reencodeAudio(of: clip, to: out, settings: settings)
                        return (clip, out)
                    }
                }
                for try await (clip, out) in group { converted[clip] = out }
            }
        }
        try await convert(clips.indices.filter { keep == nil || signatures[$0] != keep }.map { clips[$0] })
        var result = clips.map { converted[$0] ?? $0 }
        // Apple's AAC-LC config matches other encoders' byte for byte; if it
        // ever didn't, converting the kept clips too guarantees one format.
        if !(try await audioIsUniform(result)) {
            try await convert(clips)
            result = clips.map { converted[$0] ?? $0 }
        }
        return (result, Array(converted.values))
    }

    /// AAC-LC bitrate for re-encoding a lossy stream of `source` bits/s: twice
    /// the source (an encode at well above the source's rate adds no audible
    /// loss), at least 160 kbps, at most the transparent 256 kbps.
    static func conversionBitRate(source: Double?) -> Int {
        guard let source, source > 0 else { return ClipAudio.transparentStereoBitRate }
        let rate = Int(source * 2 / 32_000) * 32_000
        return min(ClipAudio.transparentStereoBitRate, max(160_000, rate))
    }

    /// The audio track's average bitrate (bits/s), if known.
    static func audioBitRate(of path: String) async throws -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let rate = try await track.load(.estimatedDataRate)
        return rate > 0 ? Double(rate) : nil
    }

    /// Copies a clip's video and converts its audio to `settings`.
    static func reencodeAudio(of clip: String, to output: String, settings: ClipAudio) async throws {
        guard case let .aac(sampleRate, channels, bitRate) = settings else { return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip))
        let clipDuration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let url = URL(fileURLWithPath: output)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        typealias Sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
        var videoPump: (AVAssetReaderOutput.Provider<Sample>, AVAssetWriterInput.SampleBufferReceiver)?
        var audioPump: (AVAssetReaderOutput.Provider<Sample>, AVAssetWriterInput.SampleBufferReceiver)?
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let hint = try await video.load(.formatDescriptions).first
            videoPump = (
                reader.outputProvider(for: AVAssetReaderTrackOutput(track: video, outputSettings: nil)),
                writer.inputReceiver(for: AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint))
            )
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            audioPump = (
                reader.outputProvider(for: AVAssetReaderTrackOutput(
                    track: audio, outputSettings: pcmSettings(sampleRate: sampleRate, channels: channels)
                )),
                writer.inputReceiver(for: AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: aacSettings(sampleRate: sampleRate, channels: channels, bitRate: bitRate)
                ))
            )
        }
        do {
            try reader.start()
            try writer.start()
        } catch {
            throw MediaError("Couldn't convert audio of \(clip): \(error.localizedDescription)")
        }
        writer.startSession(atSourceTime: .zero)
        nonisolated(unsafe) let pumps = (video: videoPump, audio: audioPump)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                if let (source, sink) = pumps.video {
                    group.addTask {
                        while let sample = try await source.next() { try await sink.append(sample) }
                        sink.finish()
                    }
                }
                if let (source, sink) = pumps.audio {
                    group.addTask {
                        var format: CMFormatDescription?
                        var lastEnd = CMTime.invalid
                        while let sample = try await source.next() {
                            format = sample.formatDescription
                            lastEnd = sample.presentationTimeStamp + sample.duration
                            try await sink.append(sample)
                        }
                        // Resampling can come up a few samples short of the
                        // clip; pad with silence so the next clip doesn't
                        // start early in the joined track.
                        if let format, lastEnd.isValid,
                           let pad = silence(format: format, from: lastEnd, until: clipDuration) {
                            try await sink.append(CMReadySampleBuffer(unsafeBuffer: pad))
                        }
                        sink.finish()
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            writer.cancelWriting()
            throw MediaError("Couldn't convert audio of \(clip): \(error.localizedDescription)")
        }
        writer.endSession(atSourceTime: clipDuration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaError("Couldn't convert audio of \(clip): \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// Silent PCM in `format` from `start` up to `end`, or nil when nothing
    /// is missing.
    static func silence(format: CMFormatDescription, from start: CMTime, until end: CMTime) -> CMSampleBuffer? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0 else { return nil }
        let frames = Int(((end - start).seconds * asbd.mSampleRate).rounded(.up))
        guard frames > 0, frames < Int(asbd.mSampleRate) else { return nil }
        let length = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: start, packetDescriptions: nil, sampleBufferOut: &sample
        )
        return sample
    }

    static func pcmSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    static func aacSettings(sampleRate: Double, channels: Int, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
    }
}
