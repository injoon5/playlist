import AppKit
import Foundation
import PlaylistSource

// Exercises PlaylistSource against the real services:
//
//   swift run playlist-source tools
//   swift run playlist-source fetch <playlist-url> [fast|web|auto]
//   swift run playlist-source download <playlist-url> <workdir> [count] [workers] [cancel-after-seconds]
//
// WKWebView needs a running main run loop, so the work runs in a main-actor
// task while NSApplication (with no Dock icon) runs the loop.

@MainActor
func run(_ args: [String]) async throws -> Int32 {
    guard let command = args.first else {
        print("usage: playlist-source tools | fetch URL [fast|web|auto] | download URL WORKDIR [COUNT] [WORKERS] [CANCEL_AFTER_S]")
        return 2
    }
    switch command {
    case "tools":
        let tools = ToolLocator.standard().locate()
        for tool in Tool.allCases {
            let found = tools.located[tool]
            print("\(tool.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(found.map { "\($0.path)  [\($0.source.rawValue)]" } ?? "not found")")
        }
        if let problem = tools.problem { print("problem: \(problem.localizedDescription)") }
        return tools.problem == nil ? 0 : 1

    case "fetch":
        guard args.count >= 2 else { return 2 }
        let mode = args.count >= 3 ? args[2] : "auto"
        let start = ContinuousClock.now
        let tracks: [PlaylistTrack]
        switch mode {
        case "fast": tracks = try await PlaylistScraper.fetchTracks(args[1], method: .fast)
        case "web": tracks = try await PlaylistScraper.fetchTracks(args[1], method: .webView)
        default: tracks = try await PlaylistScraper.fetchTracks(args[1], fastFirst: false)
        }
        let elapsed = ContinuousClock.now - start
        print("\(mode): \(tracks.count) tracks in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
        for t in tracks.prefix(5) {
            print("  \(t.index ?? 0). \(t.label) — \(t.album) [\(t.durationMs.map { "\($0 / 1000)s" } ?? "?")] \(t.artworkUrl ?? "-")")
        }
        if tracks.count > 5 { print("  …") }
        return 0

    case "download":
        guard args.count >= 3 else { return 2 }
        let count = args.count >= 4 ? Int(args[3]) ?? 2 : 2
        let workers = args.count >= 5 ? Int(args[4]) ?? 2 : 2
        let tools = ToolLocator.standard().locate()
        if let problem = tools.problem { throw problem }
        print("yt-dlp: \(tools.ytDlp?.path ?? "-"), ffmpeg: \(tools.ffmpeg?.path ?? "-"), js: \(tools.jsRuntime?.path ?? "-")")
        let tracks = Array(try await PlaylistScraper.fetchTracks(args[1], method: .fast).prefix(count))
        let workdir = URL(fileURLWithPath: args[2])
        let (events, continuation) = AsyncStream<DownloadEvent>.makeStream()
        let downloader = MediaDownloader(tools: tools)
        let start = ContinuousClock.now
        let job = Task.detached {
            defer { continuation.finish() }
            return try await downloader.downloadAll(tracks, workers: workers, workdir: workdir, events: continuation)
        }
        if args.count >= 6, let seconds = Double(args[5]) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                print("cancelling (\(ProcessRegistry.shared.runningCount) child processes running)")
                job.cancel()
            }
        }
        var lastPercent: [Int: Int] = [:]
        for await event in events {
            switch event {
            case .log(let line): print("log: \(line)")
            case .progress(let ev):
                if let f = ev.fraction, ev.trackStatus == "downloading", let slot = ev.slotId {
                    let pct = Int(f * 100)
                    if pct / 25 != (lastPercent[slot] ?? -1) / 25 || pct == 100 {
                        print("  slot \(slot) #\(ev.trackIndex ?? 0) \(pct)%")
                    }
                    lastPercent[slot] = pct
                } else if let status = ev.trackStatus {
                    print("  #\(ev.trackIndex ?? 0) \(status): \(ev.message)")
                }
            }
        }
        let results: [DownloadedTrack]
        do {
            results = try await job.value
        } catch is CancellationError {
            print("cancelled after \(ContinuousClock.now - start); child processes still registered: \(ProcessRegistry.shared.runningCount)")
            try await Task.sleep(for: .seconds(4))
            print("4 s later: \(ProcessRegistry.shared.runningCount)")
            return 130
        }
        print("done in \(ContinuousClock.now - start)")
        for (track, result) in zip(tracks, results) {
            let expected = Double(track.durationMs ?? 0) / 1000
            print("""
            #\(result.index) \(track.label)
              audio:   \(result.audioPath ?? "none")
              artwork: \(result.artworkPath ?? "none")
              matched: \(result.matchedVideoTitle ?? "-")
              duration: \(result.durationSec.map { String(format: "%.1fs", $0) } ?? "?") (Apple Music \(String(format: "%.1fs", expected)))
            """)
        }
        return results.allSatisfy { $0.audioPath != nil } ? 0 : 1

    default:
        print("unknown command \(command)")
        return 2
    }
}

WebPlaylistReader.trace = { print("web: \($0)") }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let arguments = Array(CommandLine.arguments.dropFirst())
Task { @MainActor in
    do {
        exit(try await run(arguments))
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
app.run()
