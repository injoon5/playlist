// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaylistGen",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "PlaylistGen", targets: ["PlaylistGen"]),
        .executable(name: "render-frame", targets: ["RenderFrame"]),
        .library(name: "PlaylistRender", targets: ["PlaylistRender"]),
    ],
    targets: [
        // Frame drawing (Core Graphics + Core Image on Metal) and AVFoundation/VideoToolbox
        // encoding — a port of playlist_video/frames.py, backgrounds.py, text.py, transitions.py.
        .target(
            name: "PlaylistRender",
            path: "Sources/PlaylistRender"
        ),
        // The AppKit + SwiftUI app.
        .executableTarget(
            name: "PlaylistGen",
            dependencies: ["PlaylistRender"],
            path: "Sources/PlaylistGen"
        ),
        // Renders single frames to PNG (or a whole clip), for checking the look against the Python renderer.
        .executableTarget(
            name: "RenderFrame",
            dependencies: ["PlaylistRender"],
            path: "Sources/RenderFrame"
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
