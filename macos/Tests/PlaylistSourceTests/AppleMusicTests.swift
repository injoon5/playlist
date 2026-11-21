import Foundation
import Testing
@testable import PlaylistSource

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("Apple Music links")
struct PlaylistURLTests {
    @Test func parsesStorefrontAndID() throws {
        let id = try AppleMusic.parsePlaylistURL("https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb")
        #expect(id == AppleMusic.PlaylistID(storefront: "us", id: "pl.f4d106fed2bd41149aaacabb233eb5eb"))
    }

    @Test func toleratesQueryStringsAndUserPlaylists() throws {
        let id = try AppleMusic.parsePlaylistURL("  https://music.apple.com/kr/playlist/%EB%B0%A4/pl.u-AkAmPlyUxXMPl0?l=en-GB ")
        #expect(id.storefront == "kr")
        #expect(id.id == "pl.u-AkAmPlyUxXMPl0")
    }

    @Test func rejectsOtherLinks() {
        #expect(throws: ScrapeError.badURL) { try AppleMusic.parsePlaylistURL("https://music.apple.com/us/album/palette/1234") }
        #expect(throws: ScrapeError.badURL) { try AppleMusic.parsePlaylistURL("https://open.spotify.com/playlist/37i9dQZF1DX") }
        #expect(throws: ScrapeError.badURL) { try AppleMusic.parsePlaylistURL("") }
    }
}

@Suite("amp-api parsing")
struct AmpAPITests {
    @Test func parsesPlaylistLikePython() throws {
        let tracks = try AppleMusic.tracks(fromPlaylistJSON: fixture("amp-playlist"))
        #expect(tracks.count == 4)
        #expect(tracks.map(\.index) == [1, 2, 3, 4])

        let first = tracks[0]
        #expect(first.title == "stupid song")
        #expect(first.artist == "Olivia Rodrigo")
        #expect(first.album == "you seem pretty sad for a girl so in love")
        #expect(first.durationMs == 209_680)
        // 4000×4000 is capped at 1200.
        #expect(first.artworkUrl == "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/1d/1b/f9/26UMGIM39303.rgb.jpg/1200x1200bb.jpg")

        #expect(tracks[1].title == "밤편지" && tracks[1].artist == "아이유 (IU)")
        // Smaller artwork keeps its size.
        #expect(tracks[1].artworkUrl == "https://is1-ssl.mzstatic.com/image/thumb/Music/palette.jpg/600x600bb.jpg")

        // Missing fields get Python's defaults.
        #expect(tracks[2].album == "")
        #expect(tracks[2].artworkUrl == nil)
        #expect(tracks[2].durationMs == nil)
        #expect(tracks[3].title == "Unknown Title" && tracks[3].artist == "Unknown Artist")
        #expect(tracks[3].artworkUrl == "https://example.mzstatic.com/nosize/1200x1200bb.jpg")
    }

    @Test func exposesNextPageAndParsesPages() throws {
        let playlist = try AppleMusic.parsePlaylist(fixture("amp-playlist"))
        #expect(playlist.next == "/v1/catalog/us/playlists/pl.f4d106fed2bd41149aaacabb233eb5eb/tracks?offset=100")
        let page = try AppleMusic.parseTracksPage(fixture("amp-tracks-page"))
        #expect(page.next?.hasSuffix("offset=200") == true)
        let all = AppleMusic.tracks(from: playlist.items + (page.data ?? []))
        #expect(all.count == 5)
        #expect(all[4].title == "Track 101" && all[4].index == 5)
        #expect(all[4].artworkUrl == "https://is1-ssl.mzstatic.com/image/thumb/p2/1200x1200bb.jpg")
    }

    @Test func unexpectedShapesThrow() {
        #expect(throws: ScrapeError.self) { try AppleMusic.parsePlaylist(Data(#"{"data": []}"#.utf8)) }
        #expect(throws: ScrapeError.self) { try AppleMusic.parsePlaylist(Data("<html>".utf8)) }
    }

    @Test func artworkTemplating() {
        let t = "https://x/{w}x{h}bb.jpg"
        #expect(AppleMusic.artworkURL(template: t, width: 4000, height: 3000) == "https://x/1200x1200bb.jpg")
        #expect(AppleMusic.artworkURL(template: t, width: 640, height: 480) == "https://x/640x480bb.jpg")
        #expect(AppleMusic.artworkURL(template: t, width: nil, height: 800) == "https://x/1200x800bb.jpg")
        #expect(AppleMusic.artworkURL(template: "https://x/fixed.jpg", width: 100, height: 100) == "https://x/fixed.jpg")
    }
}

@Suite("Developer token")
struct TokenTests {
    // header {"typ":"JWT","alg":"ES256","kid":"WebPlayKid"} . payload {"iss":"AMPWebPlay"} . sig
    static let webPlay = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6IldlYlBsYXlLaWQifQ.eyJpc3MiOiJBTVBXZWJQbGF5In0.c2ln"
    // payload {"iss":"OTHER"}
    static let other = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJPVEhFUiJ9.c2ln"

    @Test func findsInlineTokens() {
        #expect(AppleMusic.tokenInHTML(#"<script>{"token":"eyJabc.def-ghi_jk"}</script>"#) == "eyJabc.def-ghi_jk")
        #expect(AppleMusic.tokenInHTML(#"var token = "eyJxyz.1.2";"#) == "eyJxyz.1.2")
        #expect(AppleMusic.tokenInHTML("<html>no token here</html>") == nil)
    }

    @Test func prefersTheWebPlayTokenInScripts() {
        let script = #"const a="\#(Self.other)",Do="2646.4.0-external",$a="\#(Self.webPlay)";"#
        #expect(AppleMusic.developerToken(inScript: script) == Self.webPlay)
        #expect(AppleMusic.developerToken(inScript: #"x="\#(Self.other)""#) == Self.other)
        #expect(AppleMusic.developerToken(inScript: "nothing") == nil)
    }

    @Test func listsAppleScriptsModulesFirst() {
        let html = """
        <script src="/assets/legacy.js"></script>
        <script src="https://evil.example.com/x.js"></script>
        <script type="module" crossorigin src="/assets/index~B8RKPfmaCI.js"></script>
        """
        let urls = AppleMusic.scriptURLs(inHTML: html, base: URL(string: "https://music.apple.com/us/playlist/x/pl.1")!)
        #expect(urls.map(\.absoluteString) == [
            "https://music.apple.com/assets/index~B8RKPfmaCI.js",
            "https://music.apple.com/assets/legacy.js",
        ])
    }
}
