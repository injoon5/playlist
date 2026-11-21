import CoreGraphics
import CryptoKit
import Foundation
import Observation
import PlaylistRender

/// What a preview frame depends on; a change rebuilds the renderer.
struct PreviewKey: Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    var artworkURL: String?
    var background: String?
    var duration: Double
    var transition: Double
    var width: Int
    var height: Int
}

/// A rendered frame, handed from the render queue to the UI.
struct PreviewFrame: @unchecked Sendable {
    let image: CGImage
}

/// Owns one TrackRenderer on a serial queue (renderers aren't thread-safe).
final class PreviewEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PlaylistGen.preview", qos: .userInitiated)
    private var key: PreviewKey?
    private var renderer: TrackRenderer?

    func frame(for key: PreviewKey, artworkPath: String?, at t: Double) async -> PreviewFrame? {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.key != key || self.renderer == nil {
                    self.renderer = TrackRenderer(TrackRenderInput(
                        title: key.title, artist: key.artist, album: key.album,
                        artworkPath: artworkPath, backgroundPath: key.background,
                        duration: key.duration, width: key.width, height: key.height,
                        transitionDuration: key.transition
                    ))
                    self.key = key
                }
                continuation.resume(returning: self.renderer.map { PreviewFrame(image: $0.image(at: t)) })
            }
        }
    }
}

@MainActor @Observable
final class PreviewModel {
    private(set) var frame: PreviewFrame?
    private(set) var isRendering = false
    var time: Double = 1.5
    var isPlaying = false {
        didSet { if isPlaying != oldValue { isPlaying ? play() : stopPlayback() } }
    }
    private(set) var key: PreviewKey?

    private let engine = PreviewEngine()
    private var playTask: Task<Void, Never>?

    /// Preview size: the output aspect ratio, at most 1920 wide.
    static func previewSize(for settings: RunSettings) -> (Int, Int) {
        let (w, h) = settings.size
        guard w > 1920 else { return (w, h) }
        return (1920, Int((Double(h) * 1920 / Double(w)).rounded()))
    }

    func update(key: PreviewKey?) async {
        self.key = key
        guard let key else {
            frame = nil
            isPlaying = false
            return
        }
        time = min(time, key.duration)
        await render()
    }

    func render() async {
        guard let key else { return }
        isRendering = true
        defer { isRendering = false }
        let artwork = await ArtworkCache.shared.localPath(for: key.artworkURL)
        guard self.key == key else { return }
        if let frame = await engine.frame(for: key, artworkPath: artwork, at: time), self.key == key {
            self.frame = frame
        }
    }

    private func play() {
        playTask?.cancel()
        playTask = Task { [weak self] in
            let fps = 24.0
            var last = Date()
            while !Task.isCancelled {
                guard let self, let key = self.key else { return }
                let now = Date()
                self.time += now.timeIntervalSince(last)
                last = now
                if self.time >= key.duration { self.time = 0 }
                await self.render()
                try? await Task.sleep(for: .seconds(1 / fps))
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
    }
}

/// Downloads Apple Music artwork for previews, cached on disk by URL.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private var inFlight: [String: Task<String?, Never>] = [:]

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PlaylistGen/Artwork")
    }

    func localPath(for urlString: String?) async -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let name = Insecure.MD5.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
        let dest = directory.appending(path: name + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) { return dest.path }
        if let task = inFlight[urlString] { return await task.value }
        let dir = directory
        let task = Task<String?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                return dest.path
            } catch {
                return nil
            }
        }
        inFlight[urlString] = task
        let result = await task.value
        inFlight[urlString] = nil
        return result
    }
}
