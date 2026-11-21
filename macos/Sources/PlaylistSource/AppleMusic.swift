import Foundation

/// Apple Music playlist links, amp-api JSON, and developer-token extraction
/// (port of the parsing half of `playlist_video/scraper.py`).
public enum AppleMusic {
    public static let ampAPIBase = "https://amp-api.music.apple.com"
    /// Same desktop user agent the Python scraper sends.
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    /// Artwork is requested at most this many pixels on a side.
    public static let maxArtworkSize = 1200

    public struct PlaylistID: Equatable, Sendable {
        public var storefront: String
        public var id: String
    }

    /// `music.apple.com/<storefront>/playlist/<slug>/<pl.id>`, anywhere in the string.
    public static func parsePlaylistURL(_ string: String) throws(ScrapeError) -> PlaylistID {
        let pattern = /music\.apple\.com\/([a-z]{2})\/playlist\/[^\/]+\/(pl\.[a-zA-Z0-9-]+)/
        guard let match = string.firstMatch(of: pattern) else { throw .badURL }
        return PlaylistID(storefront: String(match.1), id: String(match.2))
    }

    // MARK: - amp-api JSON

    struct Artwork: Decodable {
        var url: String?
        var width: Double?
        var height: Double?
    }

    struct Attributes: Decodable {
        var name: String?
        var artistName: String?
        var albumName: String?
        var artwork: Artwork?
        var durationInMillis: Int?
    }

    struct Item: Decodable {
        var attributes: Attributes?
    }

    /// `/v1/catalog/{sf}/playlists/{id}?include=tracks` response.
    struct PlaylistResponse: Decodable {
        struct Playlist: Decodable {
            struct Relationships: Decodable {
                struct Tracks: Decodable {
                    var data: [Item]
                    var next: String?
                }
                var tracks: Tracks?
            }
            var relationships: Relationships?
        }
        var data: [Playlist]
    }

    /// `/v1/catalog/{sf}/playlists/{id}/tracks` (and `next` pages).
    struct TracksPage: Decodable {
        var data: [Item]?
        var next: String?
    }

    /// Fills Apple's `{w}x{h}` artwork template, capped at 1200 px, like
    /// `_tracks_from_amp_items` (a missing size counts as 1200).
    public static func artworkURL(template: String, width: Double?, height: Double?) -> String {
        func side(_ value: Double?) -> String {
            String(min(Int(value ?? Double(maxArtworkSize)), maxArtworkSize))
        }
        return template
            .replacingOccurrences(of: "{w}", with: side(width))
            .replacingOccurrences(of: "{h}", with: side(height))
    }

    static func tracks(from items: [Item]) -> [PlaylistTrack] {
        items.enumerated().map { i, item in
            let attrs = item.attributes
            var artwork: String?
            if let art = attrs?.artwork, let template = art.url, !template.isEmpty {
                artwork = artworkURL(template: template, width: art.width, height: art.height)
            }
            return PlaylistTrack(
                index: i + 1,
                title: attrs?.name ?? "Unknown Title",
                artist: attrs?.artistName ?? "Unknown Artist",
                album: attrs?.albumName ?? "",
                artworkUrl: artwork,
                durationMs: attrs?.durationInMillis
            )
        }
    }

    /// Parses a playlist response (`?include=tracks`): the embedded items and
    /// the path of the next page, if the playlist is longer than one page.
    static func parsePlaylist(_ data: Data) throws(ScrapeError) -> (items: [Item], next: String?) {
        do {
            let response = try JSONDecoder().decode(PlaylistResponse.self, from: data)
            guard let rel = response.data.first?.relationships?.tracks else {
                throw ScrapeError.unexpectedResponse("no tracks relationship")
            }
            return (rel.data, rel.next)
        } catch let error as ScrapeError {
            throw error
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    static func parseTracksPage(_ data: Data) throws(ScrapeError) -> TracksPage {
        do {
            return try JSONDecoder().decode(TracksPage.self, from: data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }

    /// Convenience for tests and callers holding a whole response.
    public static func tracks(fromPlaylistJSON data: Data) throws(ScrapeError) -> [PlaylistTrack] {
        tracks(from: try parsePlaylist(data).items)
    }

    // MARK: - Developer token

    /// The anonymous MusicKit token, when the page ships it inline (the two
    /// patterns the Python fast path looks for).
    public static func tokenInHTML(_ html: String) -> String? {
        if let m = html.firstMatch(of: /"token":"(eyJ[a-zA-Z0-9_\-\.]+)"/) { return String(m.1) }
        if let m = html.firstMatch(of: /token\s*=\s*"(eyJ[a-zA-Z0-9_\-\.]+)"/) { return String(m.1) }
        return nil
    }

    /// Script URLs on the page, module bundles first (that's where the web
    /// app keeps its token today).
    public static func scriptURLs(inHTML html: String, base: URL) -> [URL] {
        var modules: [URL] = []
        var others: [URL] = []
        for match in html.matches(of: /<script\b([^>]*)\bsrc="([^"]+)"/) {
            guard let url = URL(string: String(match.2), relativeTo: base)?.absoluteURL,
                  url.host?.hasSuffix("apple.com") == true else { continue }
            if match.1.contains("module") { modules.append(url) } else { others.append(url) }
        }
        return modules + others
    }

    /// Picks the Apple Music web player's developer token out of a JS bundle:
    /// a JWT issued by "AMPWebPlay" if there is one, else the first JWT.
    public static func developerToken(inScript script: String) -> String? {
        let jwts = script.matches(of: /eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/).map { String($0.0) }
        return jwts.first { jwtPayload($0)?["iss"] as? String == "AMPWebPlay" } ?? jwts.first
    }

    static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public enum ScrapeError: LocalizedError, Equatable, Sendable {
    case badURL
    case noToken
    case http(Int, String)
    case unexpectedResponse(String)
    case empty
    case timedOut(String)
    case web(String)

    public var errorDescription: String? {
        switch self {
        case .badURL:
            return "That doesn’t look like an Apple Music playlist link (music.apple.com/…/playlist/…/pl.…)."
        case .noToken:
            return "Couldn’t find Apple Music’s web token on the playlist page."
        case .http(let status, let what):
            return status == 404
                ? "Apple Music couldn’t find that playlist. Check that the link is right and the playlist is public."
                : "Apple Music returned HTTP \(status) for \(what)."
        case .unexpectedResponse(let detail):
            return "Apple Music sent an unexpected response (\(detail))."
        case .empty:
            return "The playlist has no songs."
        case .timedOut(let what):
            return "Timed out \(what)."
        case .web(let message):
            return message
        }
    }
}

/// Calls amp-api with an anonymous developer token (no Apple ID needed).
public struct AmpAPIClient: Sendable {
    public var token: String
    public var session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func get(_ url: URL, what: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue(AppleMusic.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScrapeError.http(http.statusCode, what)
        }
        return data
    }

    /// Every track of a playlist, following `next` links (the embedded
    /// relationship stops at ~100 tracks).
    public func playlistTracks(_ playlist: AppleMusic.PlaylistID) async throws -> [PlaylistTrack] {
        let base = AppleMusic.ampAPIBase
        let url = URL(string: "\(base)/v1/catalog/\(playlist.storefront)/playlists/\(playlist.id)?include=tracks&extend=editorialArtwork")!
        let first = try AppleMusic.parsePlaylist(try await get(url, what: "the playlist"))
        var items = first.items
        var next = first.next
        while let path = next {
            try Task.checkCancellation()
            guard let pageURL = URL(string: base + path) else { break }
            let page = try AppleMusic.parseTracksPage(try await get(pageURL, what: "more tracks"))
            items += page.data ?? []
            next = page.next
        }
        let tracks = AppleMusic.tracks(from: items)
        if tracks.isEmpty { throw ScrapeError.empty }
        return tracks
    }
}
