import Foundation

/// Reads an Apple Music playlist's tracklist (port of `fetch_playlist_tracks`).
///
/// Two readers:
/// - **Web view** (default, like the Python default of headless Chromium):
///   loads the playlist page in a hidden WKWebView, lets Apple's own web app
///   boot, takes the developer token it uses and pages through amp-api from
///   inside the page. See `WebPlaylistReader`.
/// - **Fast**: fetches the page with URLSession, finds the token in the HTML
///   (or, where Apple ships it today, in the page's JS bundle) and calls
///   amp-api directly.
///
/// Whichever goes first, the other is the fallback.
public enum PlaylistScraper {
    public enum Method: String, Sendable {
        case fast, webView
    }

    /// Scrape with fallback. `fastFirst` is the "Try the fast playlist reader first" setting.
    @MainActor
    public static func fetchTracks(
        _ playlistURL: String, fastFirst: Bool, webTimeout: Duration = .seconds(60)
    ) async throws -> [PlaylistTrack] {
        let order: [Method] = fastFirst ? [.fast, .webView] : [.webView, .fast]
        var firstError: Error?
        for method in order {
            do {
                return try await fetchTracks(playlistURL, method: method, webTimeout: webTimeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch ScrapeError.badURL {
                throw ScrapeError.badURL
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? ScrapeError.empty
    }

    /// One reader, no fallback.
    @MainActor
    public static func fetchTracks(
        _ playlistURL: String, method: Method, webTimeout: Duration = .seconds(60)
    ) async throws -> [PlaylistTrack] {
        switch method {
        case .fast: return try await fetchFast(playlistURL)
        case .webView: return try await WebPlaylistReader.fetchTracks(playlistURL, timeout: webTimeout)
        }
    }

    // MARK: - Fast path

    public static func fetchFast(_ playlistURL: String, session: URLSession = .shared) async throws -> [PlaylistTrack] {
        let playlist = try AppleMusic.parsePlaylistURL(playlistURL)
        guard let pageURL = URL(string: playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ScrapeError.badURL
        }
        let html = try await getText(pageURL, session: session, what: "the playlist page")
        let token: String
        if let inline = AppleMusic.tokenInHTML(html) {
            token = inline
        } else {
            token = try await tokenFromScripts(html: html, base: pageURL, session: session)
        }
        return try await AmpAPIClient(token: token, session: session).playlistTracks(playlist)
    }

    /// Apple no longer inlines the token in the HTML; the web app's module
    /// bundle carries it. Only the first few scripts are worth checking.
    static func tokenFromScripts(html: String, base: URL, session: URLSession) async throws -> String {
        for url in AppleMusic.scriptURLs(inHTML: html, base: base).prefix(3) {
            try Task.checkCancellation()
            guard let script = try? await getText(url, session: session, what: "the web app script") else { continue }
            if let token = AppleMusic.developerToken(inScript: script) { return token }
        }
        throw ScrapeError.noToken
    }

    static func getText(_ url: URL, session: URLSession, what: String) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(AppleMusic.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScrapeError.http(http.statusCode, what)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
