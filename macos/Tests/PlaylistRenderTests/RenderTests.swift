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
        #expect(formatTimestamp(0) == "0:00")
        #expect(formatTimestamp(65) == "1:05")
        #expect(formatTimestamp(3599) == "59:59")
        #expect(formatTimestamp(3661) == "1:01:01")
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

/// A short AAC sine tone for encoder tests.
func writeTone(to url: URL, seconds: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
    ])
    let frames = AVAudioFrameCount(seconds * 44_100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<2 {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) { data[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100) * 0.2) }
    }
    try file.write(from: buffer)
}
