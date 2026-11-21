import Foundation
import PlaylistSource
import Testing
@testable import PlaylistGen

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

    @Test func inFlightSlotsCountTowardDownloadProgress() {
        var p = OverallProgress()
        p.apply(download: ProgressEvent(
            phase: "download", completed: 0, total: 2, message: "",
            trackIndex: 1, trackStatus: "downloading", slotId: 0, fraction: 0.5
        ))
        #expect(abs(p.value - 0.45 * 0.25) < 1e-9)
        // The slot is released (no status, no fraction): its partial share goes away,
        // but the bar never moves back.
        p.apply(download: ProgressEvent(phase: "download", completed: 0, total: 2, message: "", trackIndex: 1, slotId: 0))
        #expect(abs(p.value - 0.45 * 0.25) < 1e-9)
    }

    @Test func aspectAndSizeMapToResolutions() {
        var s = RunSettings()
        s.aspect = .macBook
        #expect(s.resolution == "1920x1200")
        s.sizeTier = .uhd
        #expect(s.resolution == "3840x2400")
        s.aspect = .wide
        #expect(s.resolution == "3840x2160" && s.sizeTier == .uhd)
    }

    @Test @MainActor func reloadKeepsEditsOrderAndSelection() {
        func t(_ title: String) -> PlaylistTrack { PlaylistTrack(index: nil, title: title, artist: "A", album: "", artworkUrl: nil, durationMs: nil) }
        var b = TrackRow(track: t("B"))
        b.track.title = "B (edited)"
        b.included = false
        let a = TrackRow(track: t("A"))
        // User order: B, A. Reloaded playlist: A, B, C (C is new).
        let merged = AppModel.merge([t("A"), t("B"), t("C")], into: [b, a])
        #expect(merged.map(\.original.title) == ["B", "A", "C"])
        #expect(merged[0].track.title == "B (edited)" && merged[0].included == false)
        // A song removed from the playlist drops out.
        #expect(AppModel.merge([t("A")], into: [b, a]).map(\.original.title) == ["A"])
    }

    @Test func settingsParseResolution() {
        var s = RunSettings()
        s.resolution = "3840x2160"
        #expect(s.size.width == 3840 && s.size.height == 2160)
        s.resolution = "junk"
        #expect(s.size.width == 1920)
    }
}

@Suite("Defaults and backgrounds")
struct DefaultsTests {
    @Test func firstLaunchMatchesConfigPy() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["bg1.jpeg", "bg2.jpeg", "bg3.jpeg"] {
            try Data().write(to: dir.appending(path: name))
        }
        let s = RunSettings.firstLaunch(backgroundsDir: dir)
        #expect(s.resolution == "1920x1080")
        #expect(s.fps == 30)
        #expect(s.workers == 6)
        #expect(s.renderWorkers == 4)
        #expect(s.gpu == "auto")
        #expect(s.shuffle == false)
        #expect(s.transitionDuration == 0.6)
        #expect(s.fastScrape == false)  // web view first, like the Python default
        #expect(s.backgrounds == [dir.appending(path: "bg1.jpeg").path, dir.appending(path: "bg2.jpeg").path])
        #expect(RunSettings.firstLaunch(backgroundsDir: nil).backgrounds.isEmpty)
    }

    @Test func repositoryBackgroundsMapToBundledCopies() {
        let bundled = ["/Applications/Playlist Gen.app/Contents/Resources/Backgrounds/bg1.jpeg",
                       "/Applications/Playlist Gen.app/Contents/Resources/Backgrounds/bg2.jpeg"]
        #expect(BundledBackgrounds.equivalent(of: "/Users/me/playlist-gen/assets/backgrounds/bg2.jpeg", in: bundled) == bundled[1])
        #expect(BundledBackgrounds.equivalent(of: "/Users/me/Pictures/bg2.jpeg", in: bundled) == nil)
        #expect(BundledBackgrounds.equivalent(of: "/Users/me/playlist-gen/assets/backgrounds/bg9.jpeg", in: bundled) == nil)
    }

    @Test func bundledBackgroundsAreFound() throws {
        // `swift test` runs from the repository, so the development fallback applies.
        let dir = try #require(BundledBackgrounds.directory)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "bg1.jpeg").path))
    }
}
