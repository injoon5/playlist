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
///       Encodes the whole clip through the same AVFoundation path the app uses.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: render-frame --title T --artist A [--album AL] [--artwork PATH] [--background PATH]
                        [--duration SECONDS] [--size WxH] [--transition SECONDS] --out DIR --t SECONDS...
           render-frame ... --encode OUT.mp4 --audio AUDIO [--fps 30] [--codec hevc|h264]

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
    guard let audio = options["audio"] else { usage() }
    var job = input
    if options["duration"] == nil { job.duration = try await Media.duration(of: audio) }
    let fps = Int(options["fps"] ?? "30") ?? 30
    let codec = VideoCodec(rawValue: options["codec"] ?? "hevc") ?? .hevc
    print("Encoder: \(codec.summary); compositing on \(GPU.device?.name ?? "the CPU")")
    let start = Date()
    try await Media.renderClip(
        ClipJob(input: job, audioPath: audio, outputPath: encodeOut, fps: fps, codec: codec),
        cancel: CancellationFlag()
    ) { _ in }
    let elapsed = Date().timeIntervalSince(start)
    let frames = TrackRenderer.frameCount(duration: job.duration, fps: fps)
    print(String(format: "%@: %d frames in %.1fs (%.0f fps)", encodeOut, frames, elapsed, Double(frames) / elapsed))
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
