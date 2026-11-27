import Foundation
import PlaylistRender

/// Renders single frames of a track's clip to PNG, for checking the Swift
/// renderer against the Python one.
///
///   render-frame --title T --artist A [--album AL] [--artwork PATH]
///                [--background PATH] [--duration 200] [--size 1920x1080]
///                [--transition 0.6] --out DIR --t 0.3 --t 5 ...
///
///   render-frame ... --encode OUT.mp4 --audio AUDIO [--fps 30] [--codec hevc|h264]
///                [--quality 0.65] [--fast 1]
///       Encodes the whole clip through the same VideoToolbox path the app uses
///       (`--fast 1`: the Media Engine's speed mode) and prints fps and size.
///
///   render-frame --join OUT.mp4 --clips A.mp4,B.mp4,...
///       Joins finished clips the way the app does (audio normalized if needed).

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: render-frame --title T --artist A [--album AL] [--artwork PATH] [--background PATH]
                        [--duration SECONDS] [--size WxH] [--transition SECONDS] --out DIR --t SECONDS...
           render-frame ... --encode OUT.mp4 --audio AUDIO [--fps 30] [--codec hevc|h264]
                            [--quality 0.65] [--fast 1]
           render-frame --join OUT.mp4 --clips A.mp4,B.mp4,...

    """.utf8))
    exit(2)
}

var options: [String: String] = [:]
var times: [Double] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    guard arg.hasPrefix("--"), let value = args.next() else { usage() }
    let key = String(arg.dropFirst(2))
    if key == "t" {
        guard let t = Double(value) else { usage() }
        times.append(t)
    } else {
        options[key] = value
    }
}

if let joinOut = options["join"] {
    guard let clips = options["clips"]?.split(separator: ",").map(String.init), !clips.isEmpty else { usage() }
    let start = Date()
    try await Media.concat(clips, to: joinOut)
    print(String(format: "%@: joined %d clips in %.1fs", joinOut, clips.count, Date().timeIntervalSince(start)))
    exit(0)
}

guard let title = options["title"], let artist = options["artist"] else { usage() }
let size = (options["size"] ?? "1920x1080").lowercased().split(separator: "x").compactMap { Int($0) }
guard size.count == 2 else { usage() }

let input = TrackRenderInput(
    title: title,
    artist: artist,
    album: options["album"] ?? "",
    artworkPath: options["artwork"],
    backgroundPath: options["background"],
    duration: Double(options["duration"] ?? "200") ?? 200,
    width: size[0],
    height: size[1],
    transitionDuration: Double(options["transition"] ?? "0.6") ?? 0.6
)

if let encodeOut = options["encode"] {
    guard let source = options["audio"] else { usage() }
    // Same as the app: formats AVFoundation can't open (Opus in Ogg/WebM) are remuxed first.
    let scratch = FileManager.default.temporaryDirectory.appending(path: "render-frame-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let audio = try await Media.readableAudio(source, workdir: scratch, environment: ProcessInfo.processInfo.environment)
    var job = input
    if options["duration"] == nil { job.duration = try await Media.duration(of: audio) }
    let fps = Int(options["fps"] ?? "30") ?? 30
    let codec = VideoCodec(rawValue: options["codec"] ?? "hevc") ?? .hevc
    print("Encoder: \(codec.summary); compositing on \(GPU.device?.name ?? "the CPU")")
    let start = Date()
    try await Media.renderClip(
        ClipJob(
            input: job, audioPath: audio, outputPath: encodeOut, fps: fps, codec: codec,
            quality: options["quality"].flatMap(Double.init), prioritizeSpeed: options["fast"] == "1"
        ),
        cancel: CancellationFlag()
    ) { _ in }
    let elapsed = Date().timeIntervalSince(start)
    let frames = TrackRenderer.frameCount(duration: job.duration, fps: fps)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: encodeOut)[.size] as? Int) ?? 0
    print(String(
        format: "%@: %d frames in %.1fs (%.0f fps), %.2f MB (%.0f kbps overall)", encodeOut, frames, elapsed,
        Double(frames) / elapsed, Double(bytes) / 1e6, Double(bytes) * 8 / job.duration / 1000
    ))
    try? FileManager.default.removeItem(at: scratch)  // exit skips the defer
    exit(0)
}

guard let out = options["out"], !times.isEmpty else { usage() }
let outDir = URL(fileURLWithPath: out)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let renderer = TrackRenderer(input)
for t in times.sorted() {
    let url = outDir.appending(path: String(format: "swift_t%07.3f.png", t))
    try Imaging.writePNG(renderer.image(at: t), to: url)
    print(url.path)
}
