// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaylistGen",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "PlaylistGen", targets: ["PlaylistGen"]),
        .executable(name: "render-frame", targets: ["RenderFrame"]),
        .library(name: "PlaylistRender", targets: ["PlaylistRender"]),
        .library(name: "PlaylistSource", targets: ["PlaylistSource"]),
        .executable(name: "playlist-source", targets: ["PlaylistSourceCLI"]),
    ],
    dependencies: [
        // Progress bar on the Dock icon while rendering.
        .package(url: "https://github.com/sindresorhus/DockProgress", from: "4.1.0"),
    ],
    targets: [
        // Frame drawing (Core Graphics + Core Image on Metal) and AVFoundation/VideoToolbox
        // encoding — a port of playlist_video/frames.py, backgrounds.py, text.py, transitions.py.
        .target(
            name: "PlaylistRender",
            path: "Sources/PlaylistRender"
        ),
        // Apple Music scraping (URLSession + a hidden WKWebView) and downloads
        // through the yt-dlp / ffmpeg command-line tools — a port of
        // playlist_video/scraper.py and downloader.py. No Python needed.
        .target(
            name: "PlaylistSource",
            path: "Sources/PlaylistSource"
        ),
        // The AppKit + SwiftUI app.
        .executableTarget(
            name: "PlaylistGen",
            dependencies: ["PlaylistRender", "PlaylistSource", "DockProgress"],
            path: "Sources/PlaylistGen"
        ),
        // Renders single frames to PNG (or a whole clip), for checking the look against the Python renderer.
        .executableTarget(
            name: "RenderFrame",
            dependencies: ["PlaylistRender"],
            path: "Sources/RenderFrame"
        ),
        // Loads a playlist and downloads songs from the command line, for
        // checking PlaylistSource against the real services.
        .executableTarget(
            name: "PlaylistSourceCLI",
            dependencies: ["PlaylistSource"],
            path: "Sources/PlaylistSourceCLI"
        ),
        .testTarget(
            name: "PlaylistSourceTests",
            dependencies: ["PlaylistSource"],
            path: "Tests/PlaylistSourceTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PlaylistRenderTests",
            dependencies: ["PlaylistRender"],
            path: "Tests/PlaylistRenderTests"
        ),
        .testTarget(
            name: "PlaylistGenTests",
            dependencies: ["PlaylistGen"],
            path: "Tests/PlaylistGenTests"
        ),
    ]
)
