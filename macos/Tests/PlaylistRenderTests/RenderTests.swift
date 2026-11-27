import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import PlaylistRender

@Suite("Timing and easing")
struct TimingTests {
    @Test func easingEndpointsAndMidpoint() {
        #expect(easeInOutCubic(0) == 0)
        #expect(easeInOutCubic(1) == 1)
        #expect(easeInOutCubic(0.5) == 0.5)
        #expect(easeInOutCubic(-1) == 0)
        #expect(easeInOutCubic(2) == 1)
    }

    @Test func marqueeHoldsThenSlidesAndWraps() {
        let tile = 280.0  // 10 s slide at 28 px/s
        let rest = marqueeState(t: 1, tileWidth: tile)
        #expect(rest.offset == 0 && rest.slideElapsed == nil)

        let sliding = marqueeState(t: marqueeHoldSeconds + 5, tileWidth: tile)
        #expect(abs(sliding.offset - 140) < 1e-9)
        #expect(abs((sliding.slideRemaining ?? 0) - 5) < 1e-9)

        // One full period later it's back at rest.
        let period = marqueeHoldSeconds + tile / marqueeSpeed
        #expect(marqueeState(t: period + 1, tileWidth: tile).offset == 0)
    }

    @Test func marqueeOffsetIsSubPixel() {
        // At 30 fps consecutive frames move < 1 px; Python truncated this to whole pixels.
        let a = marqueeState(t: 10, tileWidth: 2000).offset
        let b = marqueeState(t: 10 + 1.0 / 30, tileWidth: 2000).offset
        #expect(abs((b - a) - 28.0 / 30) < 1e-9)
    }

    @Test func leftFadeEasesInAndOut() {
        #expect(marqueeLeftFadeAmount(marqueeState(t: 1, tileWidth: 1000)) == 0)
        let midSlide = marqueeState(t: marqueeHoldSeconds + 5, tileWidth: 1000)
        #expect(marqueeLeftFadeAmount(midSlide) == 1)
        let justStarted = marqueeState(t: marqueeHoldSeconds + 0.05, tileWidth: 1000)
        #expect(marqueeLeftFadeAmount(justStarted) < 0.1)
    }

    @Test func fadeProfileEdges() {
        let rest = marqueeFadeProfile(width: 100, fadeWidth: 10, leftAmount: 0)
        #expect(rest[0] == 1)
        #expect(rest[99] == 0)
        #expect(rest[50] == 1)
        let full = marqueeFadeProfile(width: 100, fadeWidth: 10, leftAmount: 1)
        #expect(full[0] == 0)
        #expect(abs(full[5] - 0.5) < 1e-9)
    }

    @Test func frameCountUsesBankersRounding() {
        // Python's round(): 0.5 rounds to even.
        #expect(TrackRenderer.frameCount(duration: 2.5 / 30, fps: 30) == 2)
        #expect(TrackRenderer.frameCount(duration: 3.5 / 30, fps: 30) == 4)
        #expect(TrackRenderer.frameCount(duration: 0, fps: 30) == 1)
    }

    @Test func clockLabelsTruncate() {
        #expect(TrackRenderer.clock(0) == "0:00")
        #expect(TrackRenderer.clock(65.9) == "1:05")
        #expect(TrackRenderer.clock(-3) == "0:00")
    }

    @Test func chapterTimestamps() {
        #expect(YouTubeChapters.timestamp(0, long: false) == "00:00")
        #expect(YouTubeChapters.timestamp(65.9, long: false) == "01:05")
        #expect(YouTubeChapters.timestamp(3599, long: false) == "59:59")
        #expect(YouTubeChapters.timestamp(0, long: true) == "00:00:00")
        #expect(YouTubeChapters.timestamp(3661, long: true) == "01:01:01")
    }
}

@Suite("Backgrounds")
struct BackgroundTests {
    @Test func blocksAreContiguousAndBalanced() {
        #expect(Background.assign(["a", "b"], trackCount: 5) == ["a", "a", "a", "b", "b"])
        #expect(Background.assign(["a", "b", "c"], trackCount: 3) == ["a", "b", "c"])
        #expect(Background.assign([String](), trackCount: 2) == [nil, nil])
    }

    @Test func gradientSeedMatchesPython() {
        // Values from playlist_video.backgrounds.make_gradient_texture.
        let g = Background.gradient(width: 1920, height: 1080, seedText: "아이유 (IU)밤편지")
        #expect(abs(g.top.r - 0.19565) < 1e-9)
        #expect(abs(g.top.g - 0.26) < 1e-9)
        #expect(abs(g.top.b - 0.117) < 1e-9)
        let t = Background.gradient(width: 1920, height: 1080, seedText: "Taylor SwiftLove Story")
        #expect(abs(t.top.r - 0.26) < 1e-9 && abs(t.top.g - 0.1265333333) < 1e-9)
        #expect(g.marginWidth == 288 && g.marginHeight == 162)
    }
}

@Suite("Renderer")
struct RendererTests {
    private func input(title: String) -> TrackRenderInput {
        TrackRenderInput(
            title: title, artist: "아이유 (IU)", album: "Palette", artworkPath: nil, backgroundPath: nil,
            duration: 10, width: 640, height: 360, transitionDuration: 0.6
        )
    }

    private func pixelSum(_ image: CGImage) -> Int {
        let ctx = Imaging.makeContext(width: image.width, height: image.height)
        ctx.drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = UnsafeRawBufferPointer(start: ctx.data, count: ctx.bytesPerRow * ctx.height)
        return bytes.reduce(0) { $0 + Int($1) }
    }

    @Test func framesHaveExpectedSize() {
        let image = TrackRenderer(input(title: "밤편지")).image(at: 5)
        #expect(image.width == 640 && image.height == 360)
    }

    @Test func transitionDipsToBlack() {
        let renderer = TrackRenderer(input(title: "Short"))
        // Frame 0 is black (only the opaque alpha channel is non-zero).
        #expect(pixelSum(renderer.image(at: 0)) == 640 * 360 * 255)
        #expect(pixelSum(renderer.image(at: 5)) > 640 * 360 * 255)
    }

    @Test func encodesClipWithAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "render-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "tone.m4a")
        try writeTone(to: audio, seconds: 2)
        var clip = input(title: "A Very Long Title That Has To Scroll Across The Artwork Column")
        clip.duration = try await Media.duration(of: audio.path)
        let out = dir.appending(path: "clip.mp4").path
        try await Media.renderClip(ClipJob(input: clip, audioPath: audio.path, outputPath: out, fps: 30), cancel: CancellationFlag()) { _ in }
        let duration = try await Media.duration(of: out)
        #expect(abs(duration - 2) < 0.1)

        let joined = dir.appending(path: "joined.mp4").path
        try await Media.concat([out, out], to: joined)
        #expect(abs(try await Media.duration(of: joined) - 4) < 0.2)
    }

    @Test func layoutScalesWithHeight() {
        let small = Layout(width: 1920, height: 1080)
        #expect(small.artSize == 453)
        #expect(small.blockX == 733)
        let big = Layout(width: 3840, height: 2160)
        #expect(big.artSize == 907)
    }
}

@Suite("Audio")
struct AudioTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "audio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func clip(_ audio: URL, seconds: Double, to out: URL) async throws {
        let input = TrackRenderInput(
            title: "Tone", artist: "Test", album: "", artworkPath: nil, backgroundPath: nil,
            duration: seconds, width: 320, height: 180, transitionDuration: 0.3
        )
        try await Media.renderClip(
            ClipJob(input: input, audioPath: audio.path, outputPath: out.path, fps: 30), cancel: CancellationFlag()
        ) { _ in }
    }

    /// Compressed packets of the first audio track, in order.
    private func packets(_ url: URL, limit: Int) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        try reader.start()
        var result: [Data] = []
        while result.count < limit, let ready = try await output.next() {
            let packet: Data? = ready.withUnsafeSampleBuffer { sample in
                guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
                let total = CMBlockBufferGetDataLength(block)
                var data = Data(count: total)
                data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
                return data
            }
            guard let packet else { break }
            result.append(packet)
        }
        reader.cancelReading()
        return result
    }

    private func audioTrackInfo(_ url: URL) async throws -> (signature: AudioSignature, duration: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        return (AudioSignature(format), try await track.load(.timeRange).duration.seconds)
    }

    /// An AAC-LC file like a YouTube download: lossless tone → one AAC encode
    /// (the clip's fallback path), priming declared in the edit list.
    private func aacSource(in dir: URL, seconds: Double, sampleRate: Double) async throws -> URL {
        let lossless = dir.appending(path: "tone-\(Int(sampleRate)).caf")
        try writeTone(to: lossless, seconds: seconds, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 16,
        ], sampleRate: sampleRate)
        let aac = dir.appending(path: "tone-\(Int(sampleRate)).mp4")
        try await clip(lossless, seconds: seconds, to: aac)
        return aac
    }

    @Test func aacIsCopiedBitExactAndTrimmedToTheVideo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await aacSource(in: dir, seconds: 3, sampleRate: 44_100)
        let out = dir.appending(path: "clip.mp4")
        try await clip(source, seconds: 2.5, to: out)

        let (signature, audioDuration) = try await audioTrackInfo(out)
        let (sourceSignature, _) = try await audioTrackInfo(source)
        #expect(signature == sourceSignature)
        #expect(signature.isEncodableAACLC && signature.sampleRate == 44_100)
        // Sample-accurate: the audio ends with the last video frame.
        #expect(abs(audioDuration - 2.5) < 0.001, "audio \(audioDuration)")
        #expect(abs(try await Media.duration(of: out.path) - 2.5) < 0.001)
        // No re-encode: the packets are the source's.
        let copied = try await packets(out, limit: 40)
        let original = try await packets(source, limit: 40)
        #expect(!copied.isEmpty && copied.reduce(0) { $0 + $1.count } > 0)
        #expect(copied.reduce(Data(), +).prefix(4000) == original.reduce(Data(), +).prefix(4000))
    }

    @Test func losslessSourceIsEncodedOnceToAAC() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "tone.caf")
        try writeTone(to: source, seconds: 2, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 16,
        ], sampleRate: 48_000)
        let out = dir.appending(path: "clip.mp4")
        try await clip(source, seconds: 2, to: out)
        let (signature, duration) = try await audioTrackInfo(out)
        #expect(signature.isEncodableAACLC && signature.sampleRate == 48_000)
        #expect(abs(duration - 2) < 0.001)
    }

    @Test func mixedFormatsAreNormalizedForTheJoin() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try await aacSource(in: dir, seconds: 2, sampleRate: 44_100)
        let b = try await aacSource(in: dir, seconds: 2, sampleRate: 48_000)
        let clipA = dir.appending(path: "clip_a.mp4"), clipB = dir.appending(path: "clip_b.mp4")
        try await clip(a, seconds: 1.5, to: clipA)
        try await clip(b, seconds: 1.2, to: clipB)
        #expect(try await !Media.audioIsUniform([clipA.path, clipB.path]))

        let joined = dir.appending(path: "joined.mp4")
        try await Media.concat([clipA.path, clipB.path, clipA.path], to: joined.path)
        let asset = AVURLAsset(url: joined)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let formats = try await track.load(.formatDescriptions)
        // One stream format: every description decodes the same way.
        #expect(Set(formats.map(AudioSignature.init)).count == 1)
        #expect(AudioSignature(formats[0]).sampleRate == 44_100)  // the longer format was kept
        let total = 1.5 + 1.2 + 1.5
        #expect(abs(try await Media.duration(of: joined.path) - total) < 0.002)
        let audioTotal = try await track.load(.timeRange)
        #expect(abs(audioTotal.duration.seconds - total) < 0.002, "audio \(audioTotal.start.seconds) + \(audioTotal.duration.seconds)")
        // Temporary conversions are cleaned up.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("joinaudio") }
        #expect(leftovers.isEmpty)
    }

    @Test func audioSpecificConfigIsReadFromESDS() {
        // AVFoundation cookies from a YouTube AAC-LC download (config padded
        // with zeros), Apple's encoder, and a YouTube HE-AAC download.
        func bytes(_ hex: String) -> [UInt8] {
            stride(from: 0, to: hex.count, by: 2).map { i in
                UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
            }
        }
        let youtube = bytes("0380808030000100048080802240150000000001770300017703058080801012100000000000000000000000000000068080800102")
        let apple = bytes("038080802200000004808080144014001800000261f00001f40005808080021210068080800102")
        let he = bytes("0380808039000100048080802b40150000000000bb7f0000bb7f05808080192b920800000000000000000000000000000000000000000000068080800102")
        #expect(AudioSignature.audioSpecificConfig(fromESDS: apple) == [0x12, 0x10])
        #expect(AudioSignature.audioSpecificConfig(fromESDS: youtube)?.prefix(2) == [0x12, 0x10])
        #expect(AudioSignature.audioSpecificConfig(fromESDS: he)?.prefix(3) == [0x2b, 0x92, 0x08])
        #expect(AudioSignature.audioSpecificConfig(fromESDS: [0x12, 0x10]) == nil)
    }
}

@Suite("Video encoder")
struct VideoEncoderTests {
    @Test func keyFrameLandsOnFirstSteadyFrame() {
        func input(duration: Double, transition: Double) -> TrackRenderInput {
            TrackRenderInput(
                title: "T", artist: "A", album: "", artworkPath: nil, backgroundPath: nil,
                duration: duration, width: 320, height: 180, transitionDuration: transition
            )
        }
        #expect(VideoEncoder.keyFrames(for: input(duration: 200, transition: 0.6), fps: 30) == [0, 18])
        #expect(VideoEncoder.keyFrames(for: input(duration: 200, transition: 0), fps: 30) == [0])
        // Very short clip: the fade shrinks with it.
        #expect(VideoEncoder.keyFrames(for: input(duration: 0.5, transition: 0.6), fps: 30) == [0, 6])
    }

    @Test func clipHasKeyFramesAtStartAfterFadeAndNoneElse() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "keyframe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "tone.m4a")
        try writeTone(to: audio, seconds: 3)
        let out = dir.appending(path: "clip.mp4")
        let input = TrackRenderInput(
            title: "Keyframes", artist: "Test", album: "", artworkPath: nil, backgroundPath: nil,
            duration: 3, width: 320, height: 180, transitionDuration: 0.3
        )
        try await Media.renderClip(
            ClipJob(input: input, audioPath: audio.path, outputPath: out.path, fps: 30), cancel: CancellationFlag()
        ) { _ in }

        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        try reader.start()
        var sync: [Double] = []
        var count = 0
        while let ready = try await output.next() {
            let (samples, isSync) = ready.withUnsafeSampleBuffer { sample in
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                return (CMSampleBufferGetNumSamples(sample), attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true)
            }
            guard samples > 0 else { continue }
            count += 1
            if isSync { sync.append(ready.presentationTimeStamp.seconds) }
        }
        #expect(count == 90)
        #expect(sync.sorted() == [0, 0.3])
    }
}

@Suite("Render caches")
struct RenderCacheTests {
    @Test func cachedOverlaysMatchFreshRenders() {
        let input = TrackRenderInput(
            title: "A Very Long Title That Has To Scroll Across The Artwork Column", artist: "Artist",
            album: "An Album Name Long Enough To Scroll Too", artworkPath: nil, backgroundPath: nil,
            duration: 30, width: 640, height: 360, transitionDuration: 0.6
        )
        let sequential = TrackRenderer(input)
        // Walk through label changes and the marquee's left-fade ramps.
        for t in stride(from: 2.0, through: 4.5, by: 1.0 / 30) { _ = sequential.image(at: t) }
        for t in [4.5, 4.9, 5.0, 12.25] {
            let cached = sequential.image(at: t)
            let fresh = TrackRenderer(input).image(at: t)
            #expect(cached.dataProvider?.data as Data? == fresh.dataProvider?.data as Data?, "t=\(t)")
        }
    }
}

/// A short sine tone for encoder tests (AAC 44.1 kHz unless `settings` say otherwise).
func writeTone(to url: URL, seconds: Double, settings: [String: Any]? = nil, sampleRate: Double = 44_100) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: settings ?? [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
    ])
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<2 {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) { data[i] = Float(sin(Double(i) * 2 * .pi * 440 / sampleRate) * 0.2) }
    }
    try file.write(from: buffer)
}

@Suite("YouTube chapters")
struct ChapterTests {
    @Test func formatsLikeYouTubeExpects() {
        let chapters = YouTubeChapters([
            .init(title: "Blueming", artist: "IU", start: 0),
            .init(title: "Ditto <Remix>", artist: "NewJeans", start: 230.07),
            .init(title: "Line\nBreak", artist: "", start: 415.6),
        ], totalDuration: 665.7)
        #expect(chapters.text == "00:00 Blueming - IU\n03:50 Ditto ‹Remix› - NewJeans\n06:55 Line Break\n")
        #expect(chapters.problems.isEmpty)
    }

    @Test func longVideosUseHoursOnEveryLine() {
        let chapters = YouTubeChapters([
            .init(title: "A", artist: "X", start: 0),
            .init(title: "B", artist: "X", start: 1800),
            .init(title: "C", artist: "X", start: 3725),
        ], totalDuration: 4000)
        #expect(chapters.text == "00:00:00 A - X\n00:30:00 B - X\n01:02:05 C - X\n")
    }

    @Test func reportsWhatYouTubeWouldReject() {
        let two = YouTubeChapters([.init(title: "A", artist: "", start: 0), .init(title: "B", artist: "", start: 60)], totalDuration: 120)
        #expect(two.problems.count == 1)
        let short = YouTubeChapters([
            .init(title: "A", artist: "", start: 0), .init(title: "Tiny", artist: "", start: 60),
            .init(title: "C", artist: "", start: 65),
        ], totalDuration: 200)
        #expect(short.problems.first?.contains("Tiny") == true)
    }
}
