"""Apple Music playlist scraping (fast HTML/amp-api path + headless-browser
fallback) and the manual tracks-from-JSON escape hatch."""

import json
import re
from typing import List, Optional, Tuple

import requests

from .models import Track

_PLAYLIST_URL_RE = re.compile(
    r"music\.apple\.com/([a-z]{2})/playlist/[^/]+/(pl\.[a-zA-Z0-9-]+)"
)
_AMP_API_BASE = "https://amp-api.music.apple.com"
_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"


def _parse_playlist_url(playlist_url: str) -> Tuple[str, str]:
    m = _PLAYLIST_URL_RE.search(playlist_url)
    if not m:
        raise ValueError("Could not parse storefront/playlist id from URL")
    return m.group(1), m.group(2)


def _tracks_from_amp_items(items: list) -> List[Track]:
    """Shared parser: amp-api track items -> Track objects."""
    tracks: List[Track] = []
    for item in items:
        attrs = item.get("attributes", {})
        artwork = attrs.get("artwork", {})
        artwork_url = None
        if artwork.get("url"):
            w = artwork.get("width", 1200)
            h = artwork.get("height", 1200)
            artwork_url = artwork["url"].replace("{w}", str(min(w, 1200))).replace("{h}", str(min(h, 1200)))
        tracks.append(
            Track(
                title=attrs.get("name", "Unknown Title"),
                artist=attrs.get("artistName", "Unknown Artist"),
                album=attrs.get("albumName", ""),
                artwork_url=artwork_url,
                duration_ms=attrs.get("durationInMillis"),
            )
        )
    for i, t in enumerate(tracks):
        t.index, t.total = i + 1, len(tracks)
    return tracks


def fetch_apple_music_tracks(playlist_url: str) -> List[Track]:
    """
    Fast-path scraper for an Apple Music playlist page.

    Extracts the anonymous MusicKit JS token embedded in the page's raw HTML,
    then calls Apple's amp-api directly. This works only when Apple still ships
    the token inline in the initial HTML — they don't always. If this raises,
    use fetch_apple_music_tracks_browser() instead, which is slower but far
    more reliable since it lets a real browser run Apple's own JS.
    """
    storefront, playlist_id = _parse_playlist_url(playlist_url)

    headers = {"User-Agent": _USER_AGENT}
    page = requests.get(playlist_url, headers=headers, timeout=20)
    page.raise_for_status()
    html = page.text

    token_match = re.search(r'"token":"(eyJ[a-zA-Z0-9_\-\.]+)"', html)
    if not token_match:
        # some builds embed it as a bare JS string assignment
        token_match = re.search(r'token\s*=\s*"(eyJ[a-zA-Z0-9_\-\.]+)"', html)
    if not token_match:
        raise RuntimeError("Could not find MusicKit token in the playlist page's raw HTML.")
    token = token_match.group(1)

    api_headers = {
        "Authorization": f"Bearer {token}",
        "Origin": "https://music.apple.com",
        "User-Agent": _USER_AGENT,
    }
    api_url = (
        f"{_AMP_API_BASE}/v1/catalog/{storefront}/playlists/"
        f"{playlist_id}?include=tracks&extend=editorialArtwork"
    )
    resp = requests.get(api_url, headers=api_headers, timeout=20)
    resp.raise_for_status()
    data = resp.json()

    try:
        tracks_rel = data["data"][0]["relationships"]["tracks"]
        items = list(tracks_rel["data"])
    except (KeyError, IndexError) as e:
        raise RuntimeError(f"Unexpected amp-api response shape: {e}")

    # The embedded relationship caps at ~100 tracks; follow `next` links so
    # long playlists aren't silently truncated on the fast path.
    next_path = tracks_rel.get("next")
    while next_path:
        resp = requests.get(_AMP_API_BASE + next_path, headers=api_headers, timeout=20)
        resp.raise_for_status()
        page_data = resp.json()
        items.extend(page_data.get("data", []))
        next_path = page_data.get("next")

    tracks = _tracks_from_amp_items(items)
    if not tracks:
        raise RuntimeError("Playlist returned zero tracks.")
    return tracks


def fetch_apple_music_tracks_browser(playlist_url: str) -> List[Track]:
    """
    Robust fallback: drive a real headless browser (Playwright) so Apple
    Music's own web app boots normally and authenticates itself. We then
    call the same amp-api endpoint the app uses, from inside the page's own
    JS context — using MusicKit's own live token — which sidesteps both the
    "token isn't in the raw HTML" problem and CORS entirely.

    Requires:
        pip install playwright
        playwright install chromium --with-deps
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise RuntimeError(
            "Playwright isn't installed. Run:\n"
            "  pip install playwright\n"
            "  playwright install chromium --with-deps"
        )

    storefront, playlist_id = _parse_playlist_url(playlist_url)

    items: list = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            page = browser.new_page(
                user_agent=f"{_USER_AGENT} (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                ignore_https_errors=True,
            )
            page.goto(playlist_url, wait_until="networkidle", timeout=60000)
            page.wait_for_function(
                "window.MusicKit && MusicKit.getInstance && MusicKit.getInstance().developerToken",
                timeout=30000,
            )

            offset, limit = 0, 100
            while True:
                batch = page.evaluate(
                    """async ({storefront, playlistId, offset, limit}) => {
                        const token = MusicKit.getInstance().developerToken;
                        const mut = MusicKit.getInstance().musicUserToken || '';
                        const resp = await fetch(
                            `https://amp-api.music.apple.com/v1/catalog/${storefront}/playlists/${playlistId}/tracks?limit=${limit}&offset=${offset}`,
                            { headers: { Authorization: `Bearer ${token}`, 'Music-User-Token': mut, Origin: 'https://music.apple.com' } }
                        );
                        if (!resp.ok) return { error: resp.status };
                        return await resp.json();
                    }""",
                    {"storefront": storefront, "playlistId": playlist_id, "offset": offset, "limit": limit},
                )
                if not batch or batch.get("error"):
                    raise RuntimeError(f"amp-api request failed inside browser: {batch}")
                batch_items = batch.get("data", [])
                items.extend(batch_items)
                if len(batch_items) < limit:
                    break
                offset += limit
        finally:
            browser.close()

    tracks = _tracks_from_amp_items(items)
    if not tracks:
        raise RuntimeError("Playlist returned zero tracks (browser method).")
    return tracks


def get_manual_tracks(json_path: str) -> List[Track]:
    """
    Fallback when Apple Music scraping fails.

    Expects a JSON file that is a list of objects:
        [
          {"title": "Song Name", "artist": "Artist", "album": "Album",
           "artwork_url": "https://... (optional)"},
          ...
        ]
    """
    with open(json_path, "r", encoding="utf-8") as f:
        raw = json.load(f)
    tracks = [
        Track(
            title=d["title"],
            artist=d.get("artist", "Unknown Artist"),
            album=d.get("album", ""),
            artwork_url=d.get("artwork_url"),
        )
        for d in raw
    ]
    for i, t in enumerate(tracks):
        t.index, t.total = i + 1, len(tracks)
    return tracks


def fetch_playlist_tracks(
    playlist_url: str,
    force_browser_scrape: bool = True,
) -> List[Track]:
    """Scrape an Apple Music playlist.

    Default is headless Chromium (Playwright). Pass force_browser_scrape=False
    to try the fast HTML/amp-api path first, falling back to Chromium on failure.
    """
    if force_browser_scrape:
        return fetch_apple_music_tracks_browser(playlist_url)
    tracks: Optional[List[Track]] = None
    try:
        tracks = fetch_apple_music_tracks(playlist_url)
    except Exception:
        tracks = None
    if tracks is None:
        tracks = fetch_apple_music_tracks_browser(playlist_url)
    return tracks
