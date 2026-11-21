import Foundation
import Synchronization
import Testing
@testable import PlaylistSource

/// The download phase against fake `yt-dlp` / `ffprobe` scripts: no network.
@Suite("Download phase")
struct DownloaderTests {
    /// Search results: "ccc…" claims 200 s but is really 300 s (rejected
    /// after download), "bbb…" is right, "aaa…" is far off. "Blocked" songs
    /// fail every player client with a bot check; "Nothing" songs have no results.
    static let fakeYtDlp = #"""
    #!/bin/sh
    echo "$@" >> "$(dirname "$0")/calls.log"
    case "$1" in
      ytsearch5:*Nothing*) exit 0 ;;
      ytsearch5:*)
        printf 'aaaaaaaaaaa\t900\tExtended mix\n'
        printf 'ccccccccccc\t200\tLying duration\n'
        printf 'bbbbbbbbbbb\t201\tRight Song (Official Audio)\n'
        exit 0 ;;
    esac
    target="$1"; shift
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in -o) out="$2"; shift ;; esac
      shift
    done
    case "$out" in
      *Blocked*) echo "[youtube] x: Downloading webpage"; echo "ERROR: [youtube] x: Sign in to confirm you're not a bot"; exit 1 ;;
    esac
    id="${target##*=}"
    case "$target" in ytsearch1:*) id="searched" ;; esac
    path=$(printf '%s' "$out" | sed 's/%(ext)s/m4a/')
    echo "YTDLP_THUMB::NA"
    echo "YTDLP_TITLE::Video $id"
    echo "YTDLP_PROGRESS::25/100/NA"
    echo "YTDLP_PROGRESS::50/NA/100"
    printf '%s' "$id" > "$path"
    echo "YTDLP_PATH::$path"
    """#

    static let fakeFFprobe = #"""
    #!/bin/sh
    for last; do :; done
    case "$(cat "$last")" in
      ccccccccccc) echo 300.0 ;;
      *) echo 201.5 ;;
    esac
    """#

    struct Fixture {
        let dir: URL
        let tools: ToolPaths

        init() throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "pg-dl-\(UUID().uuidString)")
            let bin = dir.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for (name, script) in [("yt-dlp", DownloaderTests.fakeYtDlp), ("ffprobe", DownloaderTests.fakeFFprobe), ("ffmpeg", "#!/bin/sh\n")] {
                let url = bin.appending(path: name)
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            tools = ToolLocator(
                overrides: [.ytDlp: bin.appending(path: "yt-dlp").path, .ffmpeg: bin.appending(path: "ffmpeg").path],
                projectRoots: []
            ).locate()
        }

        var calls: [String] {
            ((try? String(contentsOf: dir.appending(path: "bin/calls.log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    @Test func downloadsRanksRejectsAndReports() async throws {
        let fx = try Fixture()
        defer { try? FileManager.default.removeItem(at: fx.dir) }
        #expect(fx.tools.ffprobe?.path == fx.dir.appending(path: "bin/ffprobe").path)

        let tracks = [
            PlaylistTrack(index: 1, title: "Right Song", artist: "Artist", album: "A", durationMs: 200_000),
            PlaylistTrack(index: 2, title: "Blocked", artist: "Artist", album: "B", durationMs: 200_000),
            PlaylistTrack(index: 3, title: "Nothing", artist: "Artist", album: "C", durationMs: nil),
        ]
        let workdir = fx.dir.appending(path: "work")
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream()
        let job = Task {
            defer { continuation.finish() }
            return try await MediaDownloader(tools: fx.tools).downloadAll(tracks, workers: 2, workdir: workdir, events: continuation)
        }
        var events: [ProgressEvent] = []
        var logs: [String] = []
        for await event in stream {
            switch event {
            case .progress(let ev): events.append(ev)
            case .log(let line): logs.append(line)
            }
        }
        let results = try await job.value

        // 1: "ccc" ranked first (exact flat duration), rejected by ffprobe, then "bbb".
        #expect(results[0].matchedVideoTitle == "Video bbbbbbbbbbb")
        #expect(results[0].durationSec == 201.5)
        #expect(results[0].audioPath == workdir.appending(path: "001_Artist_Right Song_bbbbbbbbbbb.m4a").path)
        #expect(!FileManager.default.fileExists(atPath: workdir.appending(path: "001_Artist_Right Song_ccccccccccc.m4a").path))
        #expect(logs.contains { $0.contains("duration mismatch for 'Artist - Right Song' (expected ~200s, got 300s, hit: Video ccccccccccc)") })

        // 2: every candidate × every client blocked → skipped with the hint.
        #expect(results[1].audioPath == nil)
        #expect(logs.contains { $0.hasPrefix("  ! download failed for 'Artist - Blocked'") && $0.hasSuffix("(all player-client fallbacks failed)") })
        // 3 candidates × 4 player clients, in fallback order per candidate.
        let blockedCalls = fx.calls.filter { $0.contains("002_Artist_Blocked") }
        #expect(blockedCalls.count == 3 * YTDLP.clientFallbacks.count)
        #expect(blockedCalls.prefix(4).map { $0.firstMatch(of: /player_client=(\w+)/).map { String($0.1) } ?? "" } == YTDLP.clientFallbacks)

        // 3: no search results → `ytsearch1:` fallback, saved without an id suffix.
        #expect(results[2].audioPath == workdir.appending(path: "003_Artist_Nothing.m4a").path)
        #expect(fx.calls.contains { $0.hasPrefix("ytsearch1:Artist - Nothing audio") })

        // Statuses: every track pending first, then a final status each.
        #expect(events.prefix(3).allSatisfy { $0.trackStatus == "pending" })
        let finals = Dictionary(events.filter { ["ok", "skipped", "failed", "cancelled"].contains($0.trackStatus ?? "") }
            .map { ($0.trackIndex ?? 0, $0.trackStatus ?? "") }, uniquingKeysWith: { $1 })
        #expect(finals == [1: "ok", 2: "skipped", 3: "ok"])
        #expect(events.last?.completed == 3)
        // Per-slot progress: fractions on slots 0/1 only, and each slot is released.
        let ticks = events.filter { $0.trackStatus == "downloading" }
        #expect(!ticks.isEmpty && ticks.allSatisfy { ($0.slotId ?? -1) < 2 && $0.fraction != nil })
        #expect(ticks.contains { $0.fraction == 0.25 })
        let releases = events.filter { $0.slotId != nil && $0.trackStatus == nil }
        #expect(releases.count == 3)
    }

    @Test func cancellingStopsEverything() async throws {
        let fx = try Fixture()
        defer { try? FileManager.default.removeItem(at: fx.dir) }
        // A yt-dlp that hangs.
        let slow = fx.dir.appending(path: "bin/yt-dlp")
        try "#!/bin/sh\nsleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let tracks = (1...4).map { (i: Int) in PlaylistTrack(index: i, title: "T\(i)", artist: "A", album: "") }
        let job = Task {
            try await MediaDownloader(tools: fx.tools).downloadAll(tracks, workers: 2, workdir: fx.dir.appending(path: "w"))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(ProcessRegistry.shared.runningCount >= 2)
        let start = ContinuousClock.now
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
