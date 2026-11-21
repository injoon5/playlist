import Foundation
import Testing
@testable import PlaylistGen

@Suite("Bridge protocol")
struct BridgeProtocolTests {
    @Test func parsesTracks() throws {
        let line = #"{"type": "tracks", "tracks": [{"index": 1, "title": "밤편지", "artist": "IU", "album": "Palette", "artwork_url": "https://x/a.jpg", "duration_ms": 253000}]}"#
        guard case .tracks(let tracks)? = BridgeMessage.parse(line) else {
            Issue.record("not parsed")
            return
        }
        #expect(tracks.count == 1)
        #expect(tracks[0].title == "밤편지")
        #expect(tracks[0].artworkUrl == "https://x/a.jpg")
        #expect(tracks[0].durationMs == 253000)
    }

    @Test func parsesProgressWithNulls() {
        let line = #"{"type": "progress", "phase": "download", "completed": 0, "total": 3, "message": "", "track_index": 2, "track_label": "A - B", "track_status": "downloading", "slot_id": 1, "fraction": 0.25}"#
        guard case .progress(let ev)? = BridgeMessage.parse(line) else {
            Issue.record("not parsed")
            return
        }
        #expect(ev.slotId == 1 && ev.fraction == 0.25 && ev.trackIndex == 2)
    }

    @Test func parsesDownloadedAndErrors() {
        let downloaded = #"{"type": "downloaded", "tracks": [{"index": 1, "audio_path": "/a.m4a", "artwork_path": null, "matched_video_title": "x"}]}"#
        guard case .downloaded(let tracks)? = BridgeMessage.parse(downloaded) else {
            Issue.record("not parsed")
            return
        }
        #expect(tracks[0].audioPath == "/a.m4a" && tracks[0].artworkPath == nil)

        guard case .error(let message, _)? = BridgeMessage.parse(#"{"type": "error", "message": "boom"}"#) else {
            Issue.record("not parsed")
            return
        }
        #expect(message == "boom")
    }

    @Test func ignoresNonProtocolLines() {
        #expect(BridgeMessage.parse("Resolved 30 packages in 2ms") == nil)
        #expect(BridgeMessage.parse("{not json") == nil)
    }

    @Test func downloadRequestUsesSnakeCase() throws {
        let request = DownloadRequest(
            tracks: [BridgeTrack(index: 1, title: "T", artist: "A", album: "", artworkUrl: "u", durationMs: 5)],
            workers: 4, workdir: "/tmp/w"
        )
        let data = try request.encodedLine()
        #expect(data.last == 0x0A)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""artwork_url":"u""#))
        #expect(json.contains(#""duration_ms":5"#))
        #expect(json.contains(#""workdir":"\/tmp\/w""#))
    }
}

@Suite("Progress")
struct ProgressTests {
    @Test func overallNeverGoesBackwards() {
        var p = OverallProgress()
        p.apply(download: ProgressEvent(phase: "download", completed: 1, total: 2, message: "", fraction: nil))
        let afterOne = p.value
        #expect(abs(afterOne - 0.225) < 1e-9)
        // A "pending" event with completed=0 must not pull the bar back.
        p.apply(download: ProgressEvent(phase: "download", completed: 0, total: 2, message: ""))
        #expect(p.value == afterOne)
        p.render(completed: 1, inFlight: 0.5, total: 3)
        #expect(abs(p.value - 0.7) < 1e-9)
        p.advance(to: 1)
        #expect(p.value == 1)
    }

    @Test func settingsParseResolution() {
        var s = RunSettings()
        s.resolution = "3840x2160"
        #expect(s.size.width == 3840 && s.size.height == 2160)
        s.resolution = "junk"
        #expect(s.size.width == 1920)
    }
}

extension BridgeMessage: Equatable {
    public static func == (lhs: BridgeMessage, rhs: BridgeMessage) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}

extension ProgressEvent {
    init(phase: String, completed: Int, total: Int, message: String, fraction: Double? = nil) {
        self.init(phase: phase, completed: completed, total: total, message: message,
                  trackIndex: nil, trackLabel: nil, trackStatus: nil, slotId: nil, fraction: fraction)
    }
}
