import Foundation
import WebKit

/// The robust reader (replaces the Python Playwright/Chromium fallback):
/// loads the playlist page in a hidden WKWebView so Apple Music's web app
/// boots and authenticates itself, then pages through amp-api from inside the
/// page with the app's own developer token.
///
/// The token is captured two ways, whichever comes first:
/// - a document-start user script wraps `fetch` and `XMLHttpRequest` and
///   reports the `Authorization: Bearer …` header of any amp-api request;
/// - polling `MusicKit.getInstance().developerToken` (what the Python
///   version waited for).
///
/// Must run on the main actor (WebKit). Works without a window or a visible
/// app; it only needs the main run loop to be running.
@MainActor
public final class WebPlaylistReader: NSObject {
    private static let handlerName = "playlistGen"
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Optional trace of what the reader did (token source, fetch route).
    public static var trace: ((String) -> Void)?

    private var webView: WKWebView?
    private var capturedToken: String?
    private var loadError: Error?
    private var pageLoaded = false

    /// Hooks fetch/XHR before any page script runs.
    private static let captureScript = """
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.\(handlerName).postMessage(m); } catch (e) {} };
      const authOf = (h) => {
        if (!h) return null;
        try {
          if (typeof Headers !== 'undefined' && h instanceof Headers) return h.get('Authorization');
          if (Array.isArray(h)) { const p = h.find(x => String(x[0]).toLowerCase() === 'authorization'); return p ? p[1] : null; }
          for (const k in h) { if (k.toLowerCase() === 'authorization') return h[k]; }
        } catch (e) {}
        return null;
      };
      const report = (url, auth) => {
        if (typeof url === 'string' && url.indexOf('amp-api') !== -1 && auth && /^Bearer\\s+eyJ/.test(auth)) {
          post({ kind: 'token', token: String(auth).replace(/^Bearer\\s+/, '') });
        }
      };
      const origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          try {
            const url = typeof input === 'string' ? input : (input && input.url) || String(input);
            let auth = authOf(init && init.headers);
            if (!auth && input && input.headers) auth = authOf(input.headers);
            report(url, auth);
          } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }
      const open = XMLHttpRequest.prototype.open;
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__playlistGenURL = String(url);
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        try { if (String(name).toLowerCase() === 'authorization') report(this.__playlistGenURL, String(value)); } catch (e) {}
        return setHeader.apply(this, arguments);
      };
    })();
    """

    private static let musicKitTokenScript = """
    (() => {
      try {
        const mk = window.MusicKit;
        const inst = mk && mk.getInstance && mk.getInstance();
        return (inst && inst.developerToken) || null;
      } catch (e) { return null; }
    })()
    """

    /// The request the Python browser path made (/tracks, pages of 100), but
    /// following amp-api's `next` links: Python asked for another page
    /// whenever one came back full, and amp-api answers 404 past the end, so
    /// a playlist of exactly 100 songs failed.
    private static let fetchTracksScript = """
    const out = [];
    let path = `/v1/catalog/${storefront}/playlists/${playlistId}/tracks?limit=100`;
    for (let pages = 0; path && pages < 200; pages++) {
      const resp = await fetch(`https://amp-api.music.apple.com${path}`, { headers: { Authorization: `Bearer ${token}` } });
      if (!resp.ok) {
        if (resp.status === 404 && out.length > 0) break;
        return JSON.stringify({ error: resp.status });
      }
      const page = await resp.json();
      const items = page.data || [];
      out.push(...items);
      path = items.length > 0 ? page.next : null;
    }
    return JSON.stringify({ data: out });
    """

    /// Loads the page, waits (up to `timeout`) for the developer token, then
    /// fetches every track.
    public static func fetchTracks(_ playlistURL: String, timeout: Duration = .seconds(60)) async throws -> [PlaylistTrack] {
        let playlist = try AppleMusic.parsePlaylistURL(playlistURL)
        guard let url = URL(string: playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ScrapeError.badURL
        }
        let reader = WebPlaylistReader()
        defer { reader.tearDown() }
        let token = try await reader.developerToken(loading: url, timeout: timeout)
        return try await reader.tracks(playlist, token: token)
    }

    /// Just the token (the web app's anonymous developer token).
    public static func developerToken(for playlistURL: String, timeout: Duration = .seconds(60)) async throws -> String {
        guard let url = URL(string: playlistURL) else { throw ScrapeError.badURL }
        let reader = WebPlaylistReader()
        defer { reader.tearDown() }
        return try await reader.developerToken(loading: url, timeout: timeout)
    }

    private func developerToken(loading url: URL, timeout: Duration) async throws -> String {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Hidden web views are throttled by default; this one has work to do.
        config.preferences.inactiveSchedulingPolicy = .none
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        controller.add(self, name: Self.handlerName)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: url, timeoutInterval: 30))

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if let loadError { throw loadError }
            if let capturedToken {
                Self.trace?("token from an amp-api request header after \(clock.now - (deadline - timeout))")
                return capturedToken
            }
            if pageLoaded, let token = try? await webView.evaluateJavaScript(Self.musicKitTokenScript) as? String,
               token.hasPrefix("eyJ") {
                Self.trace?("token from MusicKit.getInstance() after \(clock.now - (deadline - timeout))")
                return token
            }
        }
        throw ScrapeError.timedOut("waiting for Apple Music’s web player to start")
    }

    private func tracks(_ playlist: AppleMusic.PlaylistID, token: String) async throws -> [PlaylistTrack] {
        guard let webView else { throw ScrapeError.web("The web view went away.") }
        do {
            let result = try await webView.callAsyncJavaScript(
                Self.fetchTracksScript,
                arguments: ["storefront": playlist.storefront, "playlistId": playlist.id, "token": token],
                contentWorld: .page
            )
            guard let json = result as? String else { throw ScrapeError.unexpectedResponse("no JSON from the page") }
            let data = Data(json.utf8)
            if let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? Int {
                throw ScrapeError.http(error, "the playlist’s tracks")
            }
            let tracks = AppleMusic.tracks(from: try AppleMusic.parseTracksPage(data).data ?? [])
            if tracks.isEmpty { throw ScrapeError.empty }
            Self.trace?("tracks fetched inside the page")
            return tracks
        } catch let error as ScrapeError {
            throw error
        } catch {
            // The in-page request failed outright (e.g. a CSP change): use the
            // same token from outside the page.
            try Task.checkCancellation()
            Self.trace?("in-page fetch failed (\(error.localizedDescription)); using URLSession with the page's token")
            return try await AmpAPIClient(token: token).playlistTracks(playlist)
        }
    }

    private func tearDown() {
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        self.webView = nil
    }
}

extension WebPlaylistReader: WKScriptMessageHandler {
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["kind"] as? String == "token",
              let token = body["token"] as? String, token.hasPrefix("eyJ"), capturedToken == nil else { return }
        capturedToken = token
    }
}

extension WebPlaylistReader: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 400 {
            loadError = ScrapeError.http(http.statusCode, "the playlist page")
            return .cancel
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if loadError == nil, (error as NSError).code != NSURLErrorCancelled { loadError = error }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if loadError == nil, (error as NSError).code != NSURLErrorCancelled { loadError = error }
    }
}
