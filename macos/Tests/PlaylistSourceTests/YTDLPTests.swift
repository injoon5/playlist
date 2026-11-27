import Foundation
import Testing
@testable import PlaylistSource

@Suite("yt-dlp search and matching")
struct MatchingTests {
    typealias C = YTDLP.Candidate

    @Test func parsesFlatSearchOutput() {
        let lines = [
            "mmslS5G22P0\t209.0\tOlivia Rodrigo - stupid song (Full Official Audio) [HQ]",
            "abcDEF_-123\tNA\tLive stream",
            "xyz12345678\t187\tTitle\twith a tab",
            "ERROR: [youtube] Unable to download API page: HTTP Error 429",
            "",
            "noTitle1234\t200",
        ]
        let parsed = YTDLP.parseSearchOutput(lines)
        #expect(parsed == [
            C(id: "mmslS5G22P0", duration: 209, title: "Olivia Rodrigo - stupid song (Full Official Audio) [HQ]"),
            C(id: "abcDEF_-123", duration: nil, title: "Live stream"),
            C(id: "xyz12345678", duration: 187, title: "Title\twith a tab"),
            C(id: "noTitle1234", duration: 200, title: ""),
        ])
    }

    @Test func ranksWithinToleranceClosestFirst() {
        let candidates = [
            C(id: "long", duration: 600, title: "1 hour loop"),
            C(id: "near", duration: 215, title: ""),
            C(id: "unknown", duration: nil, title: ""),
            C(id: "exact", duration: 210, title: ""),
            C(id: "edge", duration: 250, title: ""),  // +19 %: still in
        ]
        let ranked = YTDLP.rank(candidates, expectedMs: 210_000)
        #expect(ranked.map(\.id) == ["exact", "near", "edge", "long", "unknown"])
    }

    @Test func keepsSearchOrderWithoutAUsableDuration() {
        let candidates = [C(id: "a", duration: 30, title: ""), C(id: "b", duration: 900, title: "")]
        #expect(YTDLP.rank(candidates, expectedMs: nil).map(\.id) == ["a", "b"])
        #expect(YTDLP.rank(candidates, expectedMs: 0).map(\.id) == ["a", "b"])
        // Nothing within tolerance: search order.
        #expect(YTDLP.rank(candidates, expectedMs: 200_000).map(\.id) == ["a", "b"])
    }

    @Test func durationMismatch() {
        #expect(YTDLP.durationMismatch(expectedMs: 200_000, actualSec: 300))
        #expect(YTDLP.durationMismatch(expectedMs: 200_000, actualSec: 150))
        #expect(!YTDLP.durationMismatch(expectedMs: 200_000, actualSec: 239))
        #expect(!YTDLP.durationMismatch(expectedMs: 200_000, actualSec: 161))
        #expect(!YTDLP.durationMismatch(expectedMs: nil, actualSec: 10))
        #expect(!YTDLP.durationMismatch(expectedMs: 200_000, actualSec: nil))
        #expect(!YTDLP.durationMismatch(expectedMs: 0, actualSec: 10))
    }

    @Test func safeFileNames() {
        #expect(YTDLP.safeName(index: 3, artist: "AC/DC", title: "T.N.T. (Live)?") == "003_AC_DC_T.N.T. _Live__")
        #expect(YTDLP.safeName(index: 12, artist: "아이유", title: "밤편지") == "012_아이유_밤편지")
        let long = YTDLP.safeName(index: 1, artist: String(repeating: "a", count: 200), title: "b")
        #expect(long.unicodeScalars.count == 120)
    }

    @Test func commandLinesMatchPython() {
        let search = YTDLP.searchArguments(query: "IU - 밤편지 audio")
        #expect(search == [
            "ytsearch5:IU - 밤편지 audio", "--flat-playlist", "--print", "%(id)s\t%(duration)s\t%(title)s",
            "--no-warnings", "--js-runtimes", "deno", "--js-runtimes", "node",
        ])
        let args = YTDLP.downloadArguments(
            target: YTDLP.watchURL("abc"), client: "ios", outputTemplate: "/w/x_abc.%(ext)s",
            ffmpegLocation: "/opt/homebrew/bin", runtimes: .init(deno: "/opt/homebrew/bin/deno")
        )
        #expect(args.first == "https://www.youtube.com/watch?v=abc")
        for expected in [
            ["-f", "bestaudio/best"], ["--audio-format", "best"], ["--audio-quality", "0"],
            ["--extractor-args", "youtube:player_client=ios"], ["-o", "/w/x_abc.%(ext)s"],
            ["--js-runtimes", "deno:/opt/homebrew/bin/deno"], ["--js-runtimes", "node"],
            ["--ffmpeg-location", "/opt/homebrew/bin"],
            ["--print", "after_move:YTDLP_PATH::%(filepath)s"],
        ] {
            #expect(args.indices.contains { Array(args[$0...].prefix(expected.count)) == expected }, "missing \(expected)")
        }
        for flag in ["--extract-audio", "--no-playlist", "--no-simulate", "--newline", "--progress", "--no-warnings"] {
            #expect(args.contains(flag))
        }
        #expect(YTDLP.clientFallbacks.first == "default")  // the only one YouTube serves reliably (Nov 2026)
    }
}

@Suite("yt-dlp output")
struct OutputParsingTests {
    @Test func progressTemplate() {
        #expect(YTDLP.parseProgressTemplate("YTDLP_PROGRESS::512/1024/NA") == 0.5)
        #expect(YTDLP.parseProgressTemplate("YTDLP_PROGRESS::300/NA/1200") == 0.25)
        #expect(YTDLP.parseProgressTemplate("YTDLP_PROGRESS::300/NA/NA") == nil)
        #expect(YTDLP.parseProgressTemplate("YTDLP_PROGRESS::2048/1024/NA") == 1)
        #expect(YTDLP.parseProgressTemplate("YTDLP_PROGRESS::300/0/NA") == nil)
    }

    @Test func defaultProgressLines() {
        #expect(YTDLP.parsePercent("[download]  45.2% of    3.21MiB at  1.20MiB/s ETA 00:01") == 0.452)
        #expect(YTDLP.parsePercent("[download] 100% of 3.21MiB in 00:00:02") == 1)
        #expect(YTDLP.parsePercent("[ExtractAudio] Destination: x.m4a") == nil)
        #expect(YTDLP.parsePercent("[download] Destination: /tmp/x.m4a") == nil)
    }

    @Test func classifiesMarkers() {
        #expect(YTDLP.classify("YTDLP_TITLE::Olivia Rodrigo - stupid song") == .title("Olivia Rodrigo - stupid song"))
        #expect(YTDLP.classify("YTDLP_THUMB::NA") == .other("YTDLP_THUMB::NA"))
        #expect(YTDLP.classify("YTDLP_THUMB::https://i.ytimg.com/vi/x/maxresdefault.jpg") == .thumbnail("https://i.ytimg.com/vi/x/maxresdefault.jpg"))
        #expect(YTDLP.classify("YTDLP_PATH::/tmp/w/001_A_B_id.m4a") == .path("/tmp/w/001_A_B_id.m4a"))
        #expect(YTDLP.classify("YTDLP_PROGRESS::1/4/NA") == .progress(0.25))
        #expect(YTDLP.classify("YTDLP_PROGRESS::1/NA/NA") == .progressUnknown)
        #expect(YTDLP.classify("[download]  10.0% of 1MiB") == .progress(0.1))
        #expect(YTDLP.classify("[youtube] Extracting URL") == .other("[youtube] Extracting URL"))
    }

    @Test func errorsAndHints() {
        let lines = [
            "YTDLP_TITLE::x", "[youtube] abc: Downloading webpage",
            "ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser",
            "YTDLP_PROGRESS::1/2/NA",
        ]
        let error = YTDLP.lastError(in: lines)
        #expect(error.hasPrefix("ERROR: [youtube] abc: Sign in to confirm"))
        #expect(YTDLP.failureHint(error) == " (all player-client fallbacks failed)")
        #expect(YTDLP.failureHint("ERROR: Requested format is not available") == " (all player-client fallbacks failed)")
        #expect(YTDLP.failureHint("ERROR: Video unavailable") == "")
        #expect(YTDLP.failureHint(nil) == "")
        #expect(YTDLP.lastError(in: ["YTDLP_TITLE::x"]) == "unknown yt-dlp failure")
    }
}
