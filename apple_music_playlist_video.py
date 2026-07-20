# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "yt-dlp[default]",
#     "moviepy<2",
#     "pillow",
#     "requests",
#     "numpy",
#     "playwright",
#     "tqdm",
#     "proglog",
# ]
# ///
#!/usr/bin/env python3
"""
apple_music_playlist_video.py

Turn an Apple Music playlist into a single video. Runs on macOS.

Usage:
    uv run apple_music_playlist_video.py
    # edit CONFIG below first, or pass CLI flags to override.

System requirements (once):
    brew install ffmpeg deno         # ffmpeg for encoding, deno for yt-dlp's JS challenge
    uv run playwright install chromium   # Chromium scrape is the default path

GPU encoding: on macOS this uses VideoToolbox automatically when GPU="auto" —
HEVC (hevc_videotoolbox) with constant-quality mode (-q:v) on Apple Silicon
when the ffmpeg build has it, which is ~35-45% smaller than H.264 at the same
perceptual quality with no encode-speed cost (same hardware media engine).
H.264 VideoToolbox is the fallback. On Linux with an NVIDIA GPU it uses
NVENC. Elsewhere it falls back to libx264 (software) with no configuration
needed. Output is always an mp4 container either way (HEVC clips are tagged
hvc1 so QuickTime/Safari play them natively; YouTube accepts HEVC uploads).

Rendering is parallelized per-track across CPU cores (each track's frames +
encode happen in its own process — see render_track_to_file), then the
finished per-track clips are stitched with a lossless ffmpeg concat (no
re-encode). This is what actually uses all of an Apple Silicon machine's
cores, since a single moviepy write_videofile call is single-process/GIL-
bound for the PIL/numpy frame work.
"""

# ============================================================================
# CONFIG - edit these, then run:  uv run apple_music_playlist_video.py
# ============================================================================
PLAYLIST_URL = "https://music.apple.com/us/playlist/YOUR-PLAYLIST-ID"
OUTPUT = "output/playlist_video.mp4"
RESOLUTION = "3840x2160"
LIMIT = 3            # None to process the whole playlist
# Background: local path, http(s) URL, a list of either (split into contiguous blocks
# across the tracklist, switching at track/transition boundaries), or None for auto
# (blurred artwork / gradient, per track). Sample images live in assets/backgrounds/.
BACKGROUND_IMAGE = [
    "assets/backgrounds/bg1.jpeg",
    "assets/backgrounds/bg2.jpeg",
]
# BACKGROUND_IMAGE = None
SHUFFLE = True
WORKERS = 6          # tracks downloaded in parallel; network-bound, safe to raise
RENDER_WORKERS = 4   # tracks rendered (frames + encode) in parallel; CPU-bound — set to your actual core count
FPS = 30             # every moving thing here (marquee ~28 px/s, slow gradient pan, eased
                     # fades) moves around 1 px/frame or less at 30fps, so 30 is visually
                     # indistinguishable from 60 while halving frame-generation work,
                     # ffmpeg pipe traffic, AND encoded frame count. Set 60 if you insist.
GPU = "auto"         # "auto" | "on" | "off"  ("auto" picks VideoToolbox on macOS)
TRANSITION_DURATION = 0.6   # 0 to disable fade-through-black between tracks
COOKIES_FILE = None  # path to a cookies.txt if yt-dlp hits YouTube's bot check
# ============================================================================



import argparse
import hashlib
import json
import math
import os
import random
import re
import shutil
import platform
import queue as thread_queue
import subprocess
import sys
import tempfile
import textwrap
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from multiprocessing import Manager
from typing import Callable, List, Optional, Tuple

import requests
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

def _open_render_pool(render_workers: int, quiet: bool):
    """
    Prefer ProcessPool + Manager queues. Fall back to threads when spawn fails
    (common under Textual on macOS: ValueError "bad value(s) in fds_to_keep").
    Returns (pool, position_pool, progress_queue, cleanup).
    """
    def _thread_pool():
        position_pool = thread_queue.Queue()
        progress_queue = thread_queue.Queue() if quiet else None
        for slot in range(render_workers):
            position_pool.put(slot)
        pool = ThreadPoolExecutor(max_workers=render_workers)

        def cleanup() -> None:
            pool.shutdown(wait=True)

        return pool, position_pool, progress_queue, cleanup

    # Quiet/TUI path: Textual holds non-inheritable FDs that break process spawn.
    if quiet:
        return _thread_pool()

    manager = None
    try:
        manager = Manager()
        position_pool = manager.Queue()
        progress_queue = manager.Queue() if quiet else None
        for slot in range(render_workers):
            position_pool.put(slot)
        pool = ProcessPoolExecutor(max_workers=render_workers)

        def cleanup() -> None:
            pool.shutdown(wait=True)
            manager.shutdown()

        return pool, position_pool, progress_queue, cleanup
    except (ValueError, OSError, PermissionError) as e:
        if manager is not None:
            try:
                manager.shutdown()
            except Exception:
                pass
        if not quiet:
            print(f"  ! Process pool unavailable ({e}); falling back to threads")
        return _thread_pool()


# moviepy / yt_dlp are imported lazily inside main() so that
# `--help` and small utilities work even if they aren't installed yet.


# ==============================================================================
# Data model
# ==============================================================================

@dataclass
class Track:
    title: str
    artist: str
    album: str
    artwork_url: Optional[str] = None
    duration_ms: Optional[int] = None
    index: int = 0
    total: int = 0

    # filled in during processing
    audio_path: Optional[str] = None
    artwork_path: Optional[str] = None
    duration_sec: Optional[float] = None


@dataclass
class PipelineConfig:
    playlist_url: Optional[str] = None
    output: str = "output/playlist_video.mp4"
    resolution: str = "1920x1080"
    fps: int = 30
    limit: Optional[int] = None
    background_images: Optional[List[str]] = None
    shuffle: bool = True
    workers: int = 4
    render_workers: Optional[int] = None
    gpu: str = "auto"
    transition_duration: float = 0.6
    cookies_file: Optional[str] = None
    tracks_json: Optional[str] = None
    workdir: Optional[str] = None
    font_dir: Optional[str] = None
    force_browser_scrape: bool = True  # Chromium by default; False = try fast HTML first
    preset: Optional[str] = None
    crf: Optional[int] = None
    quiet: bool = False
    # Pre-fetched / user-selected tracks from the TUI. When set, scrape is skipped.
    tracks: Optional[List[Track]] = None


@dataclass
class ProgressEvent:
    phase: str  # fetch | download | render | concat | done
    completed: int
    total: int
    message: str
    track_index: Optional[int] = None
    track_label: Optional[str] = None
    track_status: Optional[str] = None
    slot_id: Optional[int] = None
    fraction: Optional[float] = None


@dataclass
class PipelineResult:
    output_path: str
    description_path: str
    tracks: List[Track]
    description_text: str


ProgressCallback = Callable[[ProgressEvent], None]


def track_label(track: Track) -> str:
    return f"{track.artist} - {track.title}"


def _emit(on_progress: Optional[ProgressCallback], event: ProgressEvent) -> None:
    if on_progress is not None:
        on_progress(event)


# ==============================================================================
# Step 1: Apple Music playlist scraping
# ==============================================================================

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
    m = re.search(r"music\.apple\.com/([a-z]{2})/playlist/[^/]+/(pl\.[a-zA-Z0-9-]+)", playlist_url)
    if not m:
        raise ValueError("Could not parse storefront/playlist id from URL")
    storefront, playlist_id = m.group(1), m.group(2)

    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
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
        "User-Agent": headers["User-Agent"],
    }
    api_url = (
        f"https://amp-api.music.apple.com/v1/catalog/{storefront}/playlists/"
        f"{playlist_id}?include=tracks&extend=editorialArtwork"
    )
    resp = requests.get(api_url, headers=api_headers, timeout=20)
    resp.raise_for_status()
    data = resp.json()

    try:
        items = data["data"][0]["relationships"]["tracks"]["data"]
    except (KeyError, IndexError) as e:
        raise RuntimeError(f"Unexpected amp-api response shape: {e}")

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

    m = re.search(r"music\.apple\.com/([a-z]{2})/playlist/[^/]+/(pl\.[a-zA-Z0-9-]+)", playlist_url)
    if not m:
        raise ValueError("Could not parse storefront/playlist id from URL")
    storefront, playlist_id = m.group(1), m.group(2)

    items: list = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
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
                browser.close()
                raise RuntimeError(f"amp-api request failed inside browser: {batch}")
            batch_items = batch.get("data", [])
            items.extend(batch_items)
            if len(batch_items) < limit:
                break
            offset += limit

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


# ==============================================================================
# Step 2: audio download (yt-dlp) + artwork download
# ==============================================================================

# YouTube's bot-check ("Sign in to confirm you're not a bot") hits datacenter
# IPs — Colab included — far more than home connections. The android/ios
# clients use a different auth flow than the default web client and often
# aren't flagged even when web is; tv_embedded is a third fallback. Order
# matters: cheapest/most-likely-to-work first.
YT_DLP_CLIENT_FALLBACKS = ["android", "ios", "tv_embedded", "web"]

# Error substrings worth retrying with a different player_client: both the
# bot-check AND "requested format is not available" are client-specific —
# each client exposes a different, sometimes broken/restricted format list
# for a given video, not just a different auth flow.
_RETRYABLE_PATTERNS = ["sign in to confirm", "not a bot", "requested format is not available"]


def _parse_ytdlp_percent(line: str) -> Optional[float]:
    """Extract 0..1 from a yt-dlp progress line like '[download]  45.2% of …'."""
    if "[download]" not in line or "%" not in line:
        return None
    match = re.search(r"(\d+(?:\.\d+)?)\s*%", line)
    if not match:
        return None
    return min(1.0, max(0.0, float(match.group(1)) / 100.0))


def download_audio(
    track: Track,
    workdir: str,
    cookies_file: Optional[str] = None,
    on_fraction: Optional[Callable[[float], None]] = None,
) -> Optional[str]:
    """
    Shells out to the yt-dlp CLI rather than using the Python API. The CLI is
    yt-dlp's primary, far more battle-tested interface — new features (like
    the js_runtimes/EJS challenge-solving machinery YouTube now requires) tend
    to land there first and get exercised far more than the Python API's
    equivalent option shapes, which is where an unexplained internal
    'NoneType' object has no attribute 'get' kept surfacing.
    """
    query = f"ytsearch1:{track.artist} - {track.title} audio"
    safe_name = re.sub(r"[^\w\-. ]", "_", f"{track.index:03d}_{track.artist}_{track.title}")[:120]
    out_template = os.path.join(workdir, f"{safe_name}.%(ext)s")

    last_error: Optional[str] = None
    for client in YT_DLP_CLIENT_FALLBACKS:
        cmd = [
            "yt-dlp", query,
            "-f", "bestaudio/best",
            "--extract-audio", "--audio-format", "best", "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
            "--js-runtimes", "deno",
            "--js-runtimes", "node",
            "--extractor-args", f"youtube:player_client={client}",
            "-o", out_template,
            "--print", "video:YTDLP_THUMB::%(thumbnail)s",
            "--print", "after_move:YTDLP_PATH::%(filepath)s",
            "--no-warnings",
            "--newline",
        ]
        if cookies_file:
            cmd += ["--cookies", cookies_file]

        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except FileNotFoundError:
            last_error = "yt-dlp CLI not found on PATH — pip install \"yt-dlp[default]\""
            break
        except Exception as e:
            last_error = str(e)
            continue

        thumb, filepath = None, None
        collected: List[str] = []
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                collected.append(line.rstrip("\n"))
                if line.startswith("YTDLP_THUMB::"):
                    val = line[len("YTDLP_THUMB::"):].strip()
                    if val and val.upper() != "NA":
                        thumb = val
                elif line.startswith("YTDLP_PATH::"):
                    val = line[len("YTDLP_PATH::"):].strip()
                    if val:
                        filepath = val
                elif on_fraction is not None:
                    pct = _parse_ytdlp_percent(line)
                    if pct is not None:
                        on_fraction(pct)
            try:
                proc.wait(timeout=180)
            except subprocess.TimeoutExpired:
                proc.kill()
                last_error = "yt-dlp timed out"
                continue
        except Exception as e:
            proc.kill()
            last_error = str(e)
            continue

        if filepath and os.path.exists(filepath):
            if not track.artwork_url and thumb:
                track.artwork_url = thumb
            if on_fraction is not None:
                on_fraction(1.0)
            return filepath

        stderr_lines = [l for l in collected if l.strip() and not l.startswith("YTDLP_")]
        last_error = stderr_lines[-1] if stderr_lines else "unknown yt-dlp failure"
        continue

    hint = ""
    if last_error and any(p in str(last_error).lower() for p in _RETRYABLE_PATTERNS):
        hint = " (all player-client fallbacks failed — pass --cookies-file with an exported cookies.txt)"
    print(f"  ! download failed for '{track.artist} - {track.title}': {last_error}{hint}")
    return None


def download_artwork(track: Track, workdir: str) -> Optional[str]:
    if not track.artwork_url:
        return None
    try:
        r = requests.get(track.artwork_url, timeout=20)
        r.raise_for_status()
        path = os.path.join(workdir, f"art_{track.index:03d}.jpg")
        with open(path, "wb") as f:
            f.write(r.content)
        return path
    except Exception as e:
        print(f"  ! artwork download failed: {e}")
        return None


# ==============================================================================
# Step 3: fonts
# ==============================================================================

_FONT_CACHE = {}

def load_font(size: int, bold: bool = False, font_dir: Optional[str] = None) -> ImageFont.FreeTypeFont:
    key = (size, bold, font_dir)
    if key in _FONT_CACHE:
        return _FONT_CACHE[key]

    candidates = []
    if font_dir:
        candidates += [
            os.path.join(font_dir, "Pretendard-Bold.otf" if bold else "Pretendard-Regular.otf"),
        ]
    candidates += [
        "/usr/share/fonts/truetype/pretendard/Pretendard-Bold.otf" if bold else "/usr/share/fonts/truetype/pretendard/Pretendard-Regular.otf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "C:\\Windows\\Fonts\\arialbd.ttf" if bold else "C:\\Windows\\Fonts\\arial.ttf",
    ]
    for path in candidates:
        if path and os.path.exists(path):
            font = ImageFont.truetype(path, size)
            _FONT_CACHE[key] = font
            return font

    font = ImageFont.load_default()
    _FONT_CACHE[key] = font
    return font


def try_download_pretendard(dest_dir: str) -> Optional[str]:
    """Best-effort download of Pretendard (nicer default typography, full Korean
    glyph coverage — useful since Apple Music track/artist names are often Korean).
    Tries jsDelivr first, falls back to raw.githubusercontent. Fails silently."""
    files = {
        "Pretendard-Regular.otf": [
            "https://cdn.jsdelivr.net/gh/fonts-archive/Pretendard/Pretendard-Regular.otf",
            "https://raw.githubusercontent.com/fonts-archive/Pretendard/main/Pretendard-Regular.otf",
        ],
        "Pretendard-Bold.otf": [
            "https://cdn.jsdelivr.net/gh/fonts-archive/Pretendard/Pretendard-Bold.otf",
            "https://raw.githubusercontent.com/fonts-archive/Pretendard/main/Pretendard-Bold.otf",
        ],
    }
    os.makedirs(dest_dir, exist_ok=True)
    ok = True
    for fname, urls in files.items():
        dest = os.path.join(dest_dir, fname)
        if os.path.exists(dest):
            continue
        downloaded = False
        for url in urls:
            try:
                r = requests.get(url, timeout=15)
                r.raise_for_status()
                with open(dest, "wb") as f:
                    f.write(r.content)
                downloaded = True
                break
            except Exception:
                continue
        if not downloaded:
            ok = False
    return dest_dir if ok else None


# ==============================================================================
# Step 4: background generation
# ==============================================================================

def make_gradient_texture(size, seed_text: str):
    """
    Deterministic-per-track diagonal gradient, built oversized (with margin)
    so it can be panned frame-to-frame for a slow drifting motion instead of
    sitting dead still. Vectorized with numpy so it's cheap to generate once
    per track (panning itself is just a crop, so it's cheap per-frame too).
    """
    import numpy as np
    import colorsys

    w, h = size
    margin_w = int(w * 0.15)
    margin_h = int(h * 0.15)
    big_w, big_h = w + 2 * margin_w, h + 2 * margin_h

    seed = int(hashlib.md5(seed_text.encode()).hexdigest(), 16)
    hue = (seed % 360) / 360.0
    hue2 = (hue + 0.12) % 1.0
    r1, g1, b1 = colorsys.hsv_to_rgb(hue, 0.55, 0.26)
    r2, g2, b2 = colorsys.hsv_to_rgb(hue2, 0.65, 0.15)

    xs = np.linspace(0, 1, big_w)
    ys = np.linspace(0, 1, big_h)
    grid_x, grid_y = np.meshgrid(xs, ys)
    blend = (grid_x + grid_y) / 2.0  # diagonal blend, 0..1

    r = (r1 + (r2 - r1) * blend) * 255
    g = (g1 + (g2 - g1) * blend) * 255
    b = (b1 + (b2 - b1) * blend) * 255
    arr = np.stack([r, g, b], axis=-1).astype("uint8")
    img = Image.fromarray(arr, mode="RGB").filter(ImageFilter.GaussianBlur(3))
    return img, margin_w, margin_h


def gradient_pan_frame(big_img: Image.Image, margin_w: int, margin_h: int, size, t: float, duration: float) -> Image.Image:
    """Slow Lissajous-style drift within the gradient's margin — smooth, never jarring."""
    w, h = size
    period = max(duration, 18.0)
    phase = (t / period) * 2 * math.pi
    dx = int(margin_w * (0.5 + 0.5 * math.sin(phase)))
    dy = int(margin_h * (0.5 + 0.5 * math.cos(phase * 0.85)))
    return big_img.crop((dx, dy, dx + w, dy + h))


def make_blurred_artwork_bg(artwork_path: str, size) -> Image.Image:
    art = Image.open(artwork_path).convert("RGB")
    w, h = size
    scale = max(w / art.width, h / art.height) * 1.15
    art = art.resize((int(art.width * scale), int(art.height * scale)), Image.LANCZOS)
    left = (art.width - w) // 2
    top = (art.height - h) // 2
    art = art.crop((left, top, left + w, top + h))
    art = art.filter(ImageFilter.GaussianBlur(40))
    # darken so text stays readable
    overlay = Image.new("RGB", size, (0, 0, 0))
    return Image.blend(art, overlay, 0.45)


def resolve_background_image(background_image: Optional[str], workdir: str, index: int = 0) -> Optional[str]:
    """
    A single --background-image entry: local file path or an http(s) URL.
    URLs get downloaded once up front into workdir and the local path is
    used from then on; a local path is returned as-is (after checking it
    actually exists, so a bad path fails fast with a clear message instead
    of silently falling back to the gradient background later). `index`
    disambiguates the downloaded filename when multiple images are given.
    """
    if not background_image:
        return None
    if background_image.startswith("http://") or background_image.startswith("https://"):
        print(f"Downloading background image from {background_image} ...")
        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
        resp = requests.get(background_image, headers=headers, timeout=30)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "")
        ext = ".jpg"
        for candidate in (".png", ".jpg", ".jpeg", ".webp"):
            if candidate.strip(".") in content_type or background_image.split("?")[0].lower().endswith(candidate):
                ext = candidate
                break
        path = os.path.join(workdir, f"background_{index}{ext}")
        with open(path, "wb") as f:
            f.write(resp.content)
        # fail fast if it isn't actually a readable image, rather than
        # surfacing a confusing error deep inside every track's render
        Image.open(path).verify()
        return path
    if not os.path.exists(background_image):
        raise FileNotFoundError(f"--background-image path does not exist: {background_image}")
    return background_image


def resolve_background_images(background_images, workdir: str) -> List[str]:
    """
    Normalizes the --background-image / BACKGROUND_IMAGE setting — which may
    be None, a single path/URL string, or a list of them — into a resolved
    list of local file paths (empty list if none were given).
    """
    if not background_images:
        return []
    if isinstance(background_images, str):
        background_images = [background_images]
    resolved = []
    for i, img in enumerate(background_images):
        path = resolve_background_image(img, workdir, index=i)
        print(f"Loaded background image {i + 1}/{len(background_images)}: {path}")
        resolved.append(path)
    return resolved


def assign_track_backgrounds(tracks: list, images: List[str]) -> List[Optional[str]]:
    """
    Splits `images` into len(images) contiguous blocks across the tracklist
    (sizes as equal as possible — track count // image count per block, with
    any remainder going to the earlier blocks), so the background switches
    exactly once per block boundary, i.e. at a track transition. Returns one
    entry per track (None for every track if no images were given, which
    falls back to the normal per-track auto background).
    """
    n = len(tracks)
    if not images or n == 0:
        return [None] * n
    k = len(images)
    return [images[i * k // n] for i in range(n)]


def prepare_background(size, background_image: Optional[str], artwork_path: Optional[str], seed_text: str):
    """
    Returns ("static", Image) for a custom background image or blurred artwork
    (both stay still), or ("gradient", (big_img, margin_w, margin_h)) for the
    default generated gradient, which pans over time.
    """
    if background_image and os.path.exists(background_image):
        img = Image.open(background_image).convert("RGB")
        w, h = size
        scale = max(w / img.width, h / img.height)
        img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
        left, top = (img.width - w) // 2, (img.height - h) // 2
        return "static", img.crop((left, top, left + w, top + h))
    if artwork_path and os.path.exists(artwork_path):
        return "static", make_blurred_artwork_bg(artwork_path, size)
    return "gradient", make_gradient_texture(size, seed_text)


# ==============================================================================
# Step 5: info-screen frame rendering
# ==============================================================================

def rounded_mask(size, radius, supersample=4):
    """
    Anti-aliased rounded-corner mask: draw the rounded rect at `supersample`x
    resolution, then downscale with LANCZOS. Drawing directly at target size
    gives PIL's rounded_rectangle a hard, aliased (jagged/staircased) curve;
    supersampling + downscaling produces a smooth soft-edged corner instead.
    """
    ss = max(1, supersample)
    big = Image.new("L", (size[0] * ss, size[1] * ss), 0)
    d = ImageDraw.Draw(big)
    d.rounded_rectangle([0, 0, size[0] * ss, size[1] * ss], radius=radius * ss, fill=255)
    return big.resize(size, Image.LANCZOS)


def ease_in_out_cubic(u: float) -> float:
    """
    The one easing curve used everywhere motion happens in this video (marquee
    scroll, track transitions) — same curve throughout reads as one consistent,
    considered motion language rather than a grab-bag of different animation
    feels. Cubic in/out: slow-fast-slow, the standard "polished UI" ease.
    """
    u = min(max(u, 0.0), 1.0)
    return 4 * u ** 3 if u < 0.5 else 1 - ((-2 * u + 2) ** 3) / 2


TEXT_TEXTURE_PAD = 10  # margin baked into every text texture for the shadow's blur to fall off in;
                        # callers must offset the paste position by -TEXT_TEXTURE_PAD to keep the
                        # visible glyph flush with the artwork/bar's left edge, not inset by the padding


def render_text_texture(text: str, font, fill_rgba, shadow: bool = True) -> Image.Image:
    """Render one line of text at its full natural width (never truncated) onto
    a tight, transparent RGBA canvas, with a soft drop shadow baked in so it
    stays legible over any background — including a user's own custom image —
    without darkening the picture itself. Used both for text that fits as-is
    and as the source strip a marquee crops a moving window out of, so the
    shadow scrolls right along with the text."""
    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    bbox = tmp.textbbox((0, 0), text, font=font)
    text_w = max(1, bbox[2] - bbox[0])
    text_h = max(1, bbox[3] - bbox[1])
    pad = TEXT_TEXTURE_PAD
    img = Image.new("RGBA", (text_w + pad * 2, text_h + pad * 2), (0, 0, 0, 0))

    if shadow:
        shadow_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow_layer)
        sd.text((pad - bbox[0], pad - bbox[1] + 2), text, font=font, fill=(0, 0, 0, 190))
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(3))
        img.alpha_composite(shadow_layer)

    d = ImageDraw.Draw(img)
    d.text((pad - bbox[0], pad - bbox[1]), text, font=font, fill=fill_rgba)
    return img


def tabular_digit_width(font) -> float:
    """Widest single-digit glyph in this font, used as a fixed advance width
    so numeric labels don't jitter horizontally as digits of different
    natural widths tick over (manual tabular figures — PIL's basic text
    layout has no 'tnum' OpenType feature toggle without libraqm)."""
    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    return max(tmp.textlength(d, font=font) for d in "0123456789")


def tabular_text_width(text: str, font, digit_w: float, draw: ImageDraw.ImageDraw) -> float:
    return sum(digit_w if ch.isdigit() else draw.textlength(ch, font=font) for ch in text)


def draw_tabular_text(draw: ImageDraw.ImageDraw, xy, text: str, font, fill, digit_w: float) -> None:
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += digit_w if ch.isdigit() else draw.textlength(ch, font=font)


MARQUEE_HOLD_SECONDS = 2.6  # how long the marquee sits still (flush left) before each scroll
MARQUEE_FADE_IN_SECONDS = 0.35  # how long the left-edge fade takes to ease in once sliding starts
MARQUEE_FADE_OUT_SECONDS = 0.5  # how long before arrival the left-edge fade eases back out, so the
                                # text settles into its resting position with a clean, unblurred left
                                # edge (safe: the tile's trailing gap means nothing visible is crossing
                                # the left edge during the final stretch of the slide)


def marquee_state(t: float, tile_w: float, speed_px_per_sec: float = 28.0, hold_seconds: float = MARQUEE_HOLD_SECONDS):
    """
    Scroll position for time t across one tile width, plus how long the slide
    has been running and how long until it arrives back at rest (both None
    while at rest). Holds at position 0 for hold_seconds, then slides
    right-to-left at constant speed straight through the tile (text + gap),
    arriving back at position 0 exactly as the tile wraps — the loop is
    seamless (position 0 and position tile_w are the same pixel under
    modulo) — and holds there again before repeating.
    """
    slide_time = max(tile_w / speed_px_per_sec, 0.6)
    period = hold_seconds + slide_time
    phase = t % period
    if phase < hold_seconds:
        return 0.0, None, None
    slide_elapsed = phase - hold_seconds
    return speed_px_per_sec * slide_elapsed, slide_elapsed, slide_time - slide_elapsed


def build_directional_fade_profile(width: int, fade_width: int, fade_left: bool, fade_right: bool) -> np.ndarray:
    """
    1D (width,) alpha profile (0..255 as float), fading toward transparent at
    the left and/or right edge — only on the sides requested — full opacity
    everywhere else. Broadcastable across any row height, and cheap to
    interpolate between two variants (see _marquee_strip's fade-in).
    """
    fade_width = max(1, min(fade_width, width // 2))
    x = np.arange(width)
    profile = np.ones(width)
    if fade_left:
        profile = np.minimum(profile, np.clip(x / fade_width, 0, 1))
    if fade_right:
        profile = np.minimum(profile, np.clip((width - 1 - x) / fade_width, 0, 1))
    return profile * 255.0


def build_marquee_tile(text_tex: Image.Image, gap_px: int) -> Image.Image:
    """
    One repeat unit for a continuously scrolling marquee: the text texture
    followed by a transparent gap, endlessly tiled via modulo indexing at
    render time (see _marquee_strip in build_track_clip). Because the loop
    point is just wrapping around within this one tile — never a reset of
    position — the scroll never stops or jumps; the gap is what reads as a
    small breathing space between repeats while the motion itself never stops.
    """
    tile_w = text_tex.width + gap_px
    tile = Image.new("RGBA", (tile_w, text_tex.height), (0, 0, 0, 0))
    tile.alpha_composite(text_tex, (0, 0))
    return tile


def compute_layout(size, font_dir):
    """
    Single source of truth for every position, so the foreground layer and the
    per-frame progress bar never disagree about where things are.
    The whole block (artwork + title + meta + bar) is vertically centered
    on the canvas as one unit.
    """
    w, h = size

    art_size = int(h * 0.42)
    # title and meta share the same size — title stands out purely through
    # weight (bold, full white) and opacity, not size
    text_font_size = int(h * 0.032)
    time_font_size = int(h * 0.022)

    title_font = load_font(text_font_size, bold=True, font_dir=font_dir)
    meta_font = load_font(text_font_size, bold=False, font_dir=font_dir)
    time_font = load_font(time_font_size, bold=False, font_dir=font_dir)

    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    title_h = tmp.textbbox((0, 0), "Ag", font=title_font)[3]
    meta_h = tmp.textbbox((0, 0), "Ag", font=meta_font)[3]
    time_h = tmp.textbbox((0, 0), "Ag", font=time_font)[3]

    gap_art_title = int(h * 0.04)
    gap_title_meta = int(h * 0.004)   # tight — title and meta read as one block
    gap_meta_bar = int(h * 0.035)
    bar_h = 6
    gap_bar_label = 14

    block_height = (
        art_size + gap_art_title + title_h + gap_title_meta + meta_h
        + gap_meta_bar + bar_h + gap_bar_label + time_h
    )
    art_y = int((h - block_height) / 2)

    block_x = int(w * 0.5 - art_size / 2)
    title_y = art_y + art_size + gap_art_title
    meta_y = title_y + title_h + gap_title_meta
    bar_y = meta_y + meta_h + gap_meta_bar
    label_y = bar_y + bar_h + gap_bar_label

    return {
        "art_size": art_size,
        "block_x": block_x,
        "art_y": art_y,
        "title_y": title_y,
        "meta_y": meta_y,
        "bar_x": block_x,
        "bar_w": art_size,
        "bar_y": bar_y,
        "bar_h": bar_h,
        "label_y": label_y,
        "title_font": title_font,
        "meta_font": meta_font,
        "time_font": time_font,
        "time_digit_w": tabular_digit_width(time_font),
    }


def render_foreground_layer(track: Track, size, font_dir) -> dict:
    """
    Everything that does NOT change over time and sits ON TOP of the background:
    artwork (with a proper soft drop shadow), plus title/artist/album text —
    baked in statically if it fits within the artwork's width, or handed back
    as a separate full-width texture (for build_track_clip to marquee-scroll
    per frame) if it doesn't.
    """
    layout = compute_layout(size, font_dir)
    fg = Image.new("RGBA", size, (0, 0, 0, 0))

    art_size = layout["art_size"]
    block_x = layout["block_x"]
    art_y = layout["art_y"]
    viewport_w = art_size  # text scrolls/fits within the same width as the artwork

    if track.artwork_path and os.path.exists(track.artwork_path):
        art = Image.open(track.artwork_path).convert("RGB").resize((art_size, art_size), Image.LANCZOS)
    else:
        art = Image.new("RGB", (art_size, art_size), (40, 40, 45))

    # soft drop shadow — generous margin so the blur has room to fall off
    # cleanly instead of getting clipped into a hard-edged ring, offset
    # downward like a real cast shadow rather than a symmetric halo
    margin = max(60, art_size // 5)
    blur_radius = max(30, art_size // 12)
    shadow = Image.new("RGBA", (art_size + margin * 2, art_size + margin * 2), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [margin, margin + int(margin * 0.25), margin + art_size, margin + int(margin * 0.25) + art_size],
        radius=20, fill=(0, 0, 0, 130),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur_radius))
    fg.alpha_composite(shadow, (block_x - margin, art_y - margin))

    mask = rounded_mask((art_size, art_size), radius=18)
    fg.paste(art, (block_x, art_y), mask)

    # typography — title bold/white, meta regular/translucent, both rendered
    # at full natural width; only baked directly into fg if they already fit
    title_font, meta_font = layout["title_font"], layout["meta_font"]
    meta_text = f"{track.artist} — {track.album}" if track.album else track.artist

    title_tex = render_text_texture(track.title, title_font, (255, 255, 255, 255))
    meta_tex = render_text_texture(meta_text, meta_font, (255, 255, 255, 115))

    title_scrolls = title_tex.width > viewport_w
    meta_scrolls = meta_tex.width > viewport_w

    fade_width = max(20, int(viewport_w * 0.07))
    gap_px = max(40, int(viewport_w * 0.18))  # small breathing space between repeats

    # Two fade variants per scrolling element: "rest" only fades the right
    # edge (nothing has scrolled past the left edge yet, so no reason to
    # blur it there), "full" fades both edges (used once sliding is under
    # way). _marquee_strip blends between them as the slide starts, so the
    # left blur eases in rather than popping on.
    title_tile = title_fade_full = title_fade_rest = None
    if title_scrolls:
        title_tile = build_marquee_tile(title_tex, gap_px)
        title_fade_full = build_directional_fade_profile(viewport_w, fade_width, True, True)
        title_fade_rest = build_directional_fade_profile(viewport_w, fade_width, False, True)
    else:
        fg.alpha_composite(title_tex, (block_x - TEXT_TEXTURE_PAD, layout["title_y"] - TEXT_TEXTURE_PAD))

    meta_tile = meta_fade_full = meta_fade_rest = None
    if meta_scrolls:
        meta_tile = build_marquee_tile(meta_tex, gap_px)
        meta_fade_full = build_directional_fade_profile(viewport_w, fade_width, True, True)
        meta_fade_rest = build_directional_fade_profile(viewport_w, fade_width, False, True)
    else:
        fg.alpha_composite(meta_tex, (block_x - TEXT_TEXTURE_PAD, layout["meta_y"] - TEXT_TEXTURE_PAD))

    return {
        "layer": fg,
        "layout": layout,
        "viewport_w": viewport_w,
        "title_tile": title_tile,
        "title_fade_full": title_fade_full,
        "title_fade_rest": title_fade_rest,
        "meta_tile": meta_tile,
        "meta_fade_full": meta_fade_full,
        "meta_fade_rest": meta_fade_rest,
    }


def render_progress_bar_overlay(t: float, duration: float, layout, size) -> Image.Image:
    """
    Draws the bar + time labels on a transparent overlay, not directly onto the
    opaque background. PIL's ImageDraw overwrites pixels rather than alpha-blending
    when drawn straight onto an opaque image, so semi-transparent fills need a
    transparent layer + a real alpha_composite to actually look transparent.
    """
    overlay = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    bar_x, bar_w, bar_y, bar_h = layout["bar_x"], layout["bar_w"], layout["bar_y"], layout["bar_h"]

    progress = 0.0 if duration <= 0 else min(max(t / duration, 0), 1)

    draw.rounded_rectangle([bar_x, bar_y, bar_x + bar_w, bar_y + bar_h], radius=bar_h // 2, fill=(255, 255, 255, 70))
    fill_w = int(bar_w * progress)
    if fill_w > 0:
        draw.rounded_rectangle([bar_x, bar_y, bar_x + fill_w, bar_y + bar_h], radius=bar_h // 2, fill=(255, 255, 255, 235))

    time_font = layout["time_font"]
    digit_w = layout["time_digit_w"]
    remaining = max(duration - t, 0)
    elapsed_str = f"{int(t // 60)}:{int(t % 60):02d}"
    remaining_str = f"-{int(remaining // 60)}:{int(remaining % 60):02d}"
    label_y = layout["label_y"]
    draw_tabular_text(draw, (bar_x, label_y), elapsed_str, time_font, (255, 255, 255, 180), digit_w)
    tw = tabular_text_width(remaining_str, time_font, digit_w, draw)
    draw_tabular_text(draw, (bar_x + bar_w - tw, label_y), remaining_str, time_font, (255, 255, 255, 180), digit_w)

    return overlay


# ==============================================================================
# Step 6: clip assembly
# ==============================================================================

def build_track_clip(track: Track, resolution, fps, background_image, font_dir):
    """
    Optimized frame generator. The per-frame costs, and what's done about them:

      1. Full-frame base copy (static-background path): at 4K that's a ~24MB
         memcpy per frame, dwarfing the actual overlay work. Fixed with a
         persistent working frame + dirty-rect restore: keep one frame array
         alive across make_frame calls and, each frame, restore only the
         small rectangles the PREVIOUS frame dirtied (marquee strips +
         progress bar) from the pristine base, then blend the new overlays.
         Safe because moviepy consumes each returned frame (pipes its bytes
         to ffmpeg, or copies it inside the transition wrapper) before
         requesting the next one, and correct for any call order/time since
         every call first restores whatever was dirty.

      2. Full-frame uint16 composite (gradient path): the background moves
         every frame so the frame can't be reused, but the foreground's alpha
         is zero outside the center block (artwork + shadow + text + bar) —
         compositing is a no-op there. The uint16 blend math is restricted to
         the foreground's bounding box; the rest of the frame is a plain
         uint8 crop-copy of the precomputed oversized gradient.

      3. Per-frame overlays (marquee text, progress bar) are alpha-blended
         directly into the uint8 frame in numpy — no PIL RGBA/RGB round
         trips per frame.
    """
    from moviepy.editor import AudioFileClip, VideoClip
    import numpy as np

    audio = AudioFileClip(track.audio_path)
    duration = audio.duration
    track.duration_sec = duration

    bg_kind, bg_payload = prepare_background(
        resolution, background_image, track.artwork_path, f"{track.artist}{track.title}"
    )
    fg = render_foreground_layer(track, resolution, font_dir)
    layout = fg["layout"]
    block_x, viewport_w = layout["block_x"], fg["viewport_w"]
    W, H = resolution
    fg_layer = fg["layer"]  # full-size RGBA PIL image

    # ---- static base composite (or gradient inputs) as numpy ---------------
    if bg_kind == "gradient":
        big_img, margin_w, margin_h = bg_payload
        big_np = np.asarray(big_img.convert("RGB"))                    # (Hb, Wb, 3) uint8
        # foreground bounding box: everything outside it is fully transparent,
        # so per-frame composite math only needs to run inside it
        fg_bbox = fg_layer.getbbox() or (0, 0, W, H)
        bx0, by0, bx1, by1 = fg_bbox
        fg_np = np.asarray(fg_layer)[by0:by1, bx0:bx1]                  # cropped to bbox
        fg_rgb_u16 = fg_np[..., :3].astype(np.uint16)
        fg_alpha_u16 = fg_np[..., 3:4].astype(np.uint16)
        fg_inv_alpha_u16 = 255 - fg_alpha_u16
        static_base_rgb = None
    else:
        base_pil = bg_payload.convert("RGBA")
        base_pil.alpha_composite(fg_layer)
        static_base_rgb = np.asarray(base_pil.convert("RGB")).copy()   # (H, W, 3) uint8
        big_np = fg_rgb_u16 = fg_alpha_u16 = fg_inv_alpha_u16 = None
        bx0 = by0 = bx1 = by1 = 0

    # ---- marquee text: PIL tiles + edge-fade profiles as numpy -------------
    def _prep_marquee(tile, fade_full, fade_rest):
        if tile is None:
            return None
        return np.asarray(tile), fade_full, fade_rest   # (h, tile_w, 4), (viewport_w,) x2

    title_data = _prep_marquee(fg.get("title_tile"), fg.get("title_fade_full"), fg.get("title_fade_rest"))
    meta_data  = _prep_marquee(fg.get("meta_tile"),  fg.get("meta_fade_full"),  fg.get("meta_fade_rest"))
    title_pos = (block_x - TEXT_TEXTURE_PAD, layout["title_y"] - TEXT_TEXTURE_PAD)
    meta_pos  = (block_x - TEXT_TEXTURE_PAD, layout["meta_y"]  - TEXT_TEXTURE_PAD)

    # ---- progress bar: render only into a small bounding box overlay -------
    time_font = layout["time_font"]
    digit_w = layout["time_digit_w"]
    _tmp_draw = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    label_h = _tmp_draw.textbbox((0, 0), "Ag", font=time_font)[3] + 4
    bar_x_abs = layout["bar_x"]
    bar_y_abs = layout["bar_y"]
    bar_w     = layout["bar_w"]
    bar_h     = layout["bar_h"]
    label_y_local = layout["label_y"] - bar_y_abs
    region_h = label_y_local + label_h  # bar top -> below the time labels

    # ---- numpy alpha-blend (RGBA over RGB, in place) -----------------------
    def _blend(dst_rgb, over_rgba, x, y):
        """Blend and return the (x0, y0, x1, y1) rect actually touched, or
        None if fully clipped — the static path uses these rects to know
        exactly what to restore from the pristine base next frame."""
        oh, ow = over_rgba.shape[:2]
        fh, fw = dst_rgb.shape[:2]
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(fw, x + ow), min(fh, y + oh)
        if x0 >= x1 or y0 >= y1:
            return None
        src = over_rgba[y0 - y:y1 - y, x0 - x:x1 - x]
        alpha = src[..., 3:4].astype(np.uint16)
        rgb   = src[..., :3].astype(np.uint16)
        dst   = dst_rgb[y0:y1, x0:x1].astype(np.uint16)
        dst_rgb[y0:y1, x0:x1] = ((dst * (255 - alpha) + rgb * alpha + 127) // 255).astype(np.uint8)
        return (x0, y0, x1, y1)

    def _marquee_strip(data, t):
        """Continuous wraparound crop of width viewport_w from the endlessly
        tiled (text + gap) texture. The left-edge fade is absent while parked
        at rest (nothing has scrolled past the left edge yet), eases in over
        MARQUEE_FADE_IN_SECONDS once the slide starts, and eases back out
        over the final MARQUEE_FADE_OUT_SECONDS of the slide, so the text
        arrives back at its resting position with a clean, unblurred left
        edge — the blur only returns when the next slide begins. The
        right-edge fade is always present since more text always continues
        off-screen."""
        tile_np, fade_full, fade_rest = data
        tile_w = tile_np.shape[1]
        scroll_x, slide_elapsed, slide_remaining = marquee_state(t, tile_w)
        start = int(scroll_x) % tile_w
        end = start + viewport_w
        if end <= tile_w:
            strip = tile_np[:, start:end]
        else:
            rest = end - tile_w
            strip = np.concatenate([tile_np[:, start:tile_w], tile_np[:, 0:rest]], axis=1)
        strip = strip.copy()  # don't mutate the cached tile

        if slide_elapsed is None:
            fade_row = fade_rest
        else:
            u_in = ease_in_out_cubic(min(slide_elapsed / MARQUEE_FADE_IN_SECONDS, 1.0))
            u_out = ease_in_out_cubic(min(slide_remaining / MARQUEE_FADE_OUT_SECONDS, 1.0))
            u = min(u_in, u_out)  # ease in at slide start, ease out before arrival
            fade_row = fade_rest + (fade_full - fade_rest) * u
        new_alpha = (strip[..., 3].astype(np.float64) * fade_row[np.newaxis, :] + 127) / 255
        strip[..., 3] = new_alpha.astype(np.uint8)
        return strip

    def _render_bar_region(t):
        overlay = Image.new("RGBA", (bar_w, region_h), (0, 0, 0, 0))
        d = ImageDraw.Draw(overlay)
        d.rounded_rectangle([0, 0, bar_w, bar_h], radius=bar_h // 2, fill=(255, 255, 255, 70))
        progress = 0.0 if duration <= 0 else min(max(t / duration, 0), 1)
        fill_w = int(bar_w * progress)
        if fill_w > 0:
            d.rounded_rectangle([0, 0, fill_w, bar_h], radius=bar_h // 2, fill=(255, 255, 255, 235))
        remaining = max(duration - t, 0)
        elapsed_str   = f"{int(t // 60)}:{int(t % 60):02d}"
        remaining_str = f"-{int(remaining // 60)}:{int(remaining % 60):02d}"
        draw_tabular_text(d, (0, label_y_local), elapsed_str, time_font, (255, 255, 255, 180), digit_w)
        tw = tabular_text_width(remaining_str, time_font, digit_w, d)
        draw_tabular_text(d, (bar_w - tw, label_y_local), remaining_str, time_font, (255, 255, 255, 180), digit_w)
        return np.asarray(overlay)

    # persistent working frame + last frame's dirty rects (static path only)
    frame_state = {"work": None, "dirty": []}

    def make_frame(t):
        if bg_kind == "gradient":
            # per-frame gradient pan: numpy slice of the precomputed big array;
            # foreground composited only inside its bounding box (see docstring)
            period = max(duration, 18.0)
            phase = (t / period) * 2 * math.pi
            dx = int(margin_w * (0.5 + 0.5 * math.sin(phase)))
            dy = int(margin_h * (0.5 + 0.5 * math.cos(phase * 0.85)))
            frame = big_np[dy:dy + H, dx:dx + W].copy()
            region = frame[by0:by1, bx0:bx1].astype(np.uint16)
            frame[by0:by1, bx0:bx1] = (
                (region * fg_inv_alpha_u16 + fg_rgb_u16 * fg_alpha_u16 + 127) // 255
            ).astype(np.uint8)
            dirty = None  # background changed everywhere; no frame reuse
        else:
            if frame_state["work"] is None:
                frame_state["work"] = static_base_rgb.copy()
            else:
                for (rx0, ry0, rx1, ry1) in frame_state["dirty"]:
                    frame_state["work"][ry0:ry1, rx0:rx1] = static_base_rgb[ry0:ry1, rx0:rx1]
            frame = frame_state["work"]
            dirty = []

        if title_data is not None:
            rect = _blend(frame, _marquee_strip(title_data, t), *title_pos)
            if dirty is not None and rect:
                dirty.append(rect)
        if meta_data is not None:
            rect = _blend(frame, _marquee_strip(meta_data, t), *meta_pos)
            if dirty is not None and rect:
                dirty.append(rect)

        rect = _blend(frame, _render_bar_region(t), bar_x_abs, bar_y_abs)
        if dirty is not None and rect:
            dirty.append(rect)

        if dirty is not None:
            frame_state["dirty"] = dirty
        return frame

    clip = VideoClip(make_frame, duration=duration).set_fps(fps)
    clip = clip.set_audio(audio)
    return clip


# ==============================================================================
# Step 6b: track-to-track transitions (visual only)
# ==============================================================================

def _apple_fade_transform(get_frame, t, duration, fade_duration, zoom_amount=0.035):
    """
    One clip's per-frame transform for the fade: near the very start/end of the
    clip's own runtime, blend toward black with a cubic ease (not linear — a
    linear alpha ramp reads as mechanical) while very subtly scaling the frame
    (~3.5%) so it settles into place rather than just materializing. This is
    the same idea as Keynote's built-in "Fade Through Color" transition:
    dip through black, ease the whole way, no dead-linear ramps.
    """
    frame = get_frame(t)

    if t < fade_duration:
        u = ease_in_out_cubic(t / fade_duration)
    elif t > duration - fade_duration:
        u = ease_in_out_cubic((duration - t) / fade_duration)
    else:
        return frame  # steady-state, skip all extra work

    if u >= 0.999:
        return frame

    img = Image.fromarray(frame)
    w, h = img.size

    scale = 1.0 + (1.0 - u) * zoom_amount
    if scale > 1.0005:
        nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
        # BILINEAR, not LANCZOS: at a <=3.5% upscale on frames that are
        # simultaneously fading through black, the two are visually
        # indistinguishable — and LANCZOS at 4K is several times slower,
        # per frame, for the whole duration of every fade.
        img = img.resize((nw, nh), Image.BILINEAR)
        left, top = (nw - w) // 2, (nh - h) // 2
        img = img.crop((left, top, left + w, top + h))

    arr = np.asarray(img).astype("float32") * u
    return arr.astype("uint8")


def apply_single_clip_transition(clip, transition_duration: float):
    """
    A short, eased dip-through-black at one clip's own edges, with a very
    subtle accompanying scale — purely visual, Keynote/Apple-style polish
    instead of a flat linear cross-fade. Only ever touches video frames
    (never clip.audio), and only reads from this one clip's own runtime, so
    it's safe to apply per-track in isolation (e.g. before parallel
    rendering) rather than only after assembling the full playlist.
    """
    d = min(transition_duration, max(0.05, clip.duration / 2 - 0.05))
    duration = clip.duration
    return clip.fl(lambda gf, t, d=d, duration=duration: _apple_fade_transform(gf, t, duration, d))


def apply_track_transitions(clips: list, transition_duration: float):
    """
    Applies apply_single_clip_transition across a list of clips. Total video
    duration is unchanged (the fade happens inside each clip's own existing
    runtime) and each track's audio keeps playing at its own original,
    untouched length with no overlap, so there's no risk of video/audio drift
    across a long playlist.
    """
    if transition_duration <= 0:
        return clips
    return [apply_single_clip_transition(clip, transition_duration) for clip in clips]


# ==============================================================================
# Step 6c: speed helpers — GPU encoding + parallel downloads
# ==============================================================================

def _ffmpeg_has_encoder(name: str) -> bool:
    """True if this ffmpeg build advertises the given encoder in `-encoders`."""
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True,
        ).stdout.decode("utf-8", errors="ignore")
        return f" {name} " in out
    except Exception:
        return False


def pick_hw_encoder() -> Optional[str]:
    """
    Return the best available hardware H.264 encoder for this machine, or None
    for software libx264. macOS -> VideoToolbox (works on both Apple Silicon
    and Intel Macs with any ffmpeg build that has it, which Homebrew's does).
    Linux with an NVIDIA GPU + nvenc-capable ffmpeg -> NVENC. Otherwise None.
    (On Apple Silicon, resolve_encode_settings upgrades the VideoToolbox
    choice to HEVC when the ffmpeg build has hevc_videotoolbox.)
    """
    if platform.system() == "Darwin" and _ffmpeg_has_encoder("h264_videotoolbox"):
        return "h264_videotoolbox"
    try:
        subprocess.run(
            ["nvidia-smi"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True,
        )
        if _ffmpeg_has_encoder("h264_nvenc"):
            return "h264_nvenc"
    except Exception:
        pass
    return None


def estimate_nvenc_bitrate_mbps(resolution, fps: int) -> int:
    """
    A sensible target video bitrate for NVENC, scaled from YouTube's own
    published recommended upload bitrate for 1080p60 (~12Mbps) with a bit of
    headroom. Deliberately bitrate-based (-b:v) rather than constant-quality
    (-cq/-qp): those option names have shifted across ffmpeg/NVENC SDK
    versions and aren't reliably available on every build (e.g. Colab's apt
    ffmpeg), whereas -b:v has been stable forever and works everywhere NVENC
    itself works.
    """
    w, h = resolution
    pixel_scale = (w * h) / (1920 * 1080)
    fps_scale = fps / 60
    return max(4, round(16 * pixel_scale * fps_scale))


def is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() in ("arm64", "aarch64")


VT_QUALITY_DEFAULT = 65  # videotoolbox -q:v (1-100). With HEVC, ~60-65 lands at the same
                          # perceptual quality H.264 needed ~70 for, at a much smaller file;
                          # raise toward 75 if you ever spot banding in dark gradients.

# Standardizing sample rate/channels across every per-track render is what
# makes the final ffmpeg concat (-c copy, see concat_clips) safe: concat
# demuxer stream-copy requires every input segment's streams to match.
_CONCAT_SAFE_AUDIO_PARAMS = ["-ar", "48000", "-ac", "2"]
_MOVFLAGS = ["-movflags", "+faststart"]


@dataclass
class EncodeSettings:
    codec: str
    ffmpeg_params: List[str]
    preset: Optional[str]  # None for videotoolbox, which rejects -preset


def software_encode_settings(
    preset_arg: Optional[str], crf_arg: Optional[int], fps: int = 30
) -> EncodeSettings:
    # "slow" over "veryfast": this video is almost entirely static (only the
    # marquee, progress bar, and track transitions move), so x264's slower
    # motion search finds far more redundancy to exploit than it would on
    # typical high-motion footage — a big size/quality win for not that much
    # extra encode time, since most macroblocks skip early anyway.
    preset = preset_arg or "slow"
    crf = crf_arg if crf_arg is not None else 18
    ffmpeg_params = [
        "-crf", str(crf), "-pix_fmt", "yuv420p",
        *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
    ]
    return EncodeSettings(codec="libx264", ffmpeg_params=ffmpeg_params, preset=preset)


def software_fallback_for(encode: EncodeSettings, fps: int = 30) -> EncodeSettings:
    """
    Software encoder matching the failed hardware encoder's CODEC FAMILY, so
    a per-track fallback stays stream-copy concat-compatible with the tracks
    that hardware-encoded fine — concat_clips uses -c copy, and mixing
    H.264 and HEVC segments in one concat list would break it.
    """
    if encode.codec.startswith("hevc"):
        return EncodeSettings(
            codec="libx265",
            ffmpeg_params=[
                "-crf", "22", "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
                *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
            ],
            preset="medium",
        )
    return software_encode_settings(None, None, fps=fps)


def _gop_params(fps: int) -> List[str]:
    """
    Long keyframe interval (~10s). This video is mostly static, so spending
    a full intra frame only every ~10s — instead of the encoder's much
    shorter default — lets nearly every frame be a cheap P-frame referencing
    an unchanged background: a large file-size win at zero visual cost.
    (Seeking granularity in local players gets slightly coarser; YouTube
    re-encodes with its own GOP on upload anyway.)
    """
    return ["-g", str(max(fps, 1) * 10)]


def resolve_encode_settings(gpu_choice: str, preset_arg: Optional[str], crf_arg: Optional[int],
                             resolution, fps: int) -> EncodeSettings:
    """
    Picks the codec + quality/rate-control settings once, shared by every
    per-track parallel render (and the marquee test). Prefers constant
    quality over a flat bitrate wherever the encoder supports it, since a
    flat bitrate assumes constant motion complexity — wasteful and lower
    quality-per-bit for content this static.
    """
    hw = pick_hw_encoder()
    if gpu_choice == "off":
        hw = None
    elif gpu_choice == "on" and hw is None:
        hw = "h264_videotoolbox" if platform.system() == "Darwin" else "h264_nvenc"

    if hw == "h264_videotoolbox":
        gop = _gop_params(fps)
        if is_apple_silicon():
            # Constant quality (-q:v) is Apple Silicon-only in ffmpeg; it
            # adapts bits to per-frame complexity instead of a flat rate, so
            # the long static stretches between marquee/bar/transition
            # motion cost almost nothing while motion still looks great.
            quality = VT_QUALITY_DEFAULT
            if _ffmpeg_has_encoder("hevc_videotoolbox"):
                # HEVC over H.264: ~35-45% smaller at the same perceptual
                # quality, encoded by the same dedicated media-engine hardware
                # (no speed cost). -tag:v hvc1 makes the mp4 play natively in
                # QuickTime/Safari; YouTube accepts HEVC uploads.
                ffmpeg_params = ["-q:v", str(quality), "-tag:v", "hvc1", "-allow_sw", "1",
                                 "-pix_fmt", "yuv420p",
                                 "-frames_before", "true", "-frames_after", "true",
                                 *gop, *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS]
                print(f"Encoder: VideoToolbox HEVC, constant quality q:v={quality} (Apple Silicon)")
                return EncodeSettings(codec="hevc_videotoolbox", ffmpeg_params=ffmpeg_params, preset=None)
            ffmpeg_params = ["-q:v", str(quality), "-allow_sw", "1", "-pix_fmt", "yuv420p",
                             "-frames_before", "true", "-frames_after", "true",
                             *gop, *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS]
            print(f"Encoder: VideoToolbox H.264, constant quality q:v={quality} "
                  f"(Apple Silicon; this ffmpeg build lacks hevc_videotoolbox)")
        else:
            bitrate = estimate_nvenc_bitrate_mbps(resolution, fps)
            ffmpeg_params = ["-b:v", f"{bitrate}M", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                             *gop, *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS]
            print(f"Encoder: VideoToolbox, ~{bitrate}Mbps (Intel Mac — constant quality needs Apple Silicon)")
        return EncodeSettings(codec=hw, ffmpeg_params=ffmpeg_params, preset=None)

    if hw == "h264_nvenc":
        preset = preset_arg or "p4"
        bitrate = estimate_nvenc_bitrate_mbps(resolution, fps)
        ffmpeg_params = [
            "-rc", "vbr", "-b:v", f"{bitrate}M", "-maxrate", f"{round(bitrate * 1.5)}M",
            "-bufsize", f"{bitrate * 2}M", "-pix_fmt", "yuv420p",
            *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
        ]
        print(f"Encoder: {hw}, preset={preset}, ~{bitrate}Mbps")
        return EncodeSettings(codec=hw, ffmpeg_params=ffmpeg_params, preset=preset)

    settings = software_encode_settings(preset_arg, crf_arg, fps=fps)
    print(f"Encoder: libx264 (CPU), preset={settings.preset}, crf={crf_arg if crf_arg is not None else 18}")
    return settings


def _write_videofile(clip, out_path: str, encode: EncodeSettings, *, fps: int,
                     ffmpeg_threads: int, logger) -> None:
    """
    moviepy always injects `-preset <name>` into the ffmpeg command. VideoToolbox
    rejects that option, so strip it for VT codecs before the process starts.
    """
    write_kwargs = dict(
        fps=fps,
        codec=encode.codec,
        audio_codec="aac",
        audio_bitrate="192k",
        threads=ffmpeg_threads,
        ffmpeg_params=list(encode.ffmpeg_params),
        verbose=False,
        logger=logger,
    )
    if encode.preset is not None:
        write_kwargs["preset"] = encode.preset

    if "videotoolbox" not in encode.codec:
        clip.write_videofile(out_path, **write_kwargs)
        return

    import subprocess as sp
    from moviepy.video.io.ffmpeg_writer import FFMPEG_VideoWriter

    orig_init = FFMPEG_VideoWriter.__init__
    real_popen = sp.Popen

    def _popen(cmd, *args, **kwargs):
        if isinstance(cmd, (list, tuple)):
            filtered = []
            skip_next = False
            for part in cmd:
                if skip_next:
                    skip_next = False
                    continue
                if part == "-preset":
                    skip_next = True
                    continue
                filtered.append(part)
            cmd = filtered
        return real_popen(cmd, *args, **kwargs)

    def _init(self, *args, **kwargs):
        sp.Popen = _popen
        try:
            return orig_init(self, *args, **kwargs)
        finally:
            sp.Popen = real_popen

    FFMPEG_VideoWriter.__init__ = _init
    try:
        clip.write_videofile(out_path, **write_kwargs)
    finally:
        FFMPEG_VideoWriter.__init__ = orig_init
        sp.Popen = real_popen


def _make_worker_bar_logger(position: int, desc: str):
    """
    A proglog logger (what moviepy's write_videofile wants) that renders its
    per-frame bar with tqdm pinned to a fixed terminal line (`position`)
    instead of proglog's default, which assumes it owns the whole terminal —
    with several render-worker processes drawing bars at once, that would
    otherwise garble into flicker.
    """
    import proglog

    class _WorkerBarLogger(proglog.TqdmProgressBarLogger):
        def new_tqdm_bar(self, bar):
            if (bar in self.tqdm_bars) and (self.tqdm_bars[bar] is not None):
                self.close_tqdm_bar(bar)
            self.tqdm_bars[bar] = self.tqdm(
                total=self.bars[bar]["total"], desc=desc, position=position, leave=False,
            )

    return _WorkerBarLogger(print_messages=False)


def _make_quiet_logger():
    import proglog
    return proglog.ProgressBarLogger(bars=None, ignored_bars=frozenset({"t"}))


def _make_queue_progress_logger(progress_queue, slot_id: int, desc: str, track_index: int):
    """Proglog logger that pushes throttled frame progress onto a Manager queue."""
    import time
    import proglog

    class _QueueProgressLogger(proglog.ProgressBarLogger):
        def __init__(self):
            super().__init__(bars=None, ignored_bars=frozenset())
            self._last_push = 0.0
            self._min_interval = 0.05  # ~20 Hz

        def bars_callback(self, bar, attr, value, old_value=None):
            if bar != "t" or attr != "index":
                return
            now = time.monotonic()
            total = self.bars.get("t", {}).get("total") or 0
            if total <= 0:
                return
            if now - self._last_push < self._min_interval and value + 1 < total:
                return
            self._last_push = now
            try:
                progress_queue.put({
                    "type": "progress",
                    "slot_id": slot_id,
                    "track_index": track_index,
                    "track_label": desc,
                    "current": value + 1,
                    "total": total,
                })
            except Exception:
                pass

    return _QueueProgressLogger()


def _drain_render_queue(progress_queue, on_progress: Optional[ProgressCallback],
                        completed: int, total: int) -> None:
    if progress_queue is None or on_progress is None:
        return
    while True:
        try:
            item = progress_queue.get_nowait()
        except Exception:
            break
        if not isinstance(item, dict):
            continue
        if item.get("type") == "progress":
            cur = float(item.get("current") or 0)
            tot = float(item.get("total") or 1)
            _emit(on_progress, ProgressEvent(
                phase="render",
                completed=completed,
                total=total,
                message=item.get("track_label") or "",
                track_index=item.get("track_index"),
                track_label=item.get("track_label"),
                track_status="rendering",
                slot_id=item.get("slot_id"),
                fraction=min(1.0, cur / tot) if tot else 0.0,
            ))
        elif item.get("type") == "clear":
            _emit(on_progress, ProgressEvent(
                phase="render",
                completed=completed,
                total=total,
                message="",
                track_index=item.get("track_index"),
                track_label=None,
                track_status=None,
                slot_id=item.get("slot_id"),
                fraction=None,
            ))


def render_track_to_file(
    track: Track,
    track_bg: Optional[str],
    resolution,
    fps: int,
    font_dir: Optional[str],
    transition_duration: float,
    encode: EncodeSettings,
    out_path: str,
    position_pool,
    ffmpeg_threads: int = 2,
    progress_queue=None,
    quiet: bool = False,
) -> Track:
    """
    Renders one track's clip (frames + transition + audio) straight to its
    own finished mp4. Meant to run inside a ProcessPoolExecutor worker.
    """
    desc = f"{track.artist} - {track.title}"[:60]
    position = position_pool.get()
    try:
        if quiet and progress_queue is not None:
            logger = _make_queue_progress_logger(progress_queue, position, desc, track.index)
            try:
                progress_queue.put({
                    "type": "progress",
                    "slot_id": position,
                    "track_index": track.index,
                    "track_label": desc,
                    "current": 0,
                    "total": 1,
                })
            except Exception:
                pass
        elif quiet:
            logger = _make_quiet_logger()
        else:
            logger = _make_worker_bar_logger(position, desc)

        clip = build_track_clip(track, resolution, fps, track_bg, font_dir)
        if transition_duration > 0:
            clip = apply_single_clip_transition(clip, transition_duration)

        try:
            _write_videofile(
                clip, out_path, encode, fps=fps, ffmpeg_threads=ffmpeg_threads, logger=logger,
            )
        except Exception as e:
            if encode.codec.startswith("libx"):
                raise
            fallback = software_fallback_for(encode, fps=fps)
            if not quiet:
                print(
                    f"  ! GPU encode failed for '{track.artist} - {track.title}' ({e}); "
                    f"retrying with {fallback.codec}..."
                )
            retry_logger = (
                _make_queue_progress_logger(progress_queue, position, desc, track.index)
                if quiet and progress_queue is not None
                else (_make_quiet_logger() if quiet else _make_worker_bar_logger(position, desc))
            )
            _write_videofile(
                clip, out_path, fallback, fps=fps, ffmpeg_threads=ffmpeg_threads, logger=retry_logger,
            )
    finally:
        if progress_queue is not None:
            try:
                progress_queue.put({
                    "type": "clear",
                    "slot_id": position,
                    "track_index": track.index,
                })
            except Exception:
                pass
        position_pool.put(position)
    return track


def concat_clips(clip_paths: List[str], output_path: str, workdir: str) -> None:
    """
    Losslessly stitches already-encoded per-track clips with ffmpeg's concat
    demuxer (stream copy — no re-encode, no quality loss, effectively
    instant). Safe specifically because every clip was produced by
    render_track_to_file with identical codec, resolution, fps, pixel format,
    and audio sample rate/channels, which is exactly what -c copy
    concatenation requires to avoid glitches.
    """
    list_path = os.path.join(workdir, "concat_list.txt")
    with open(list_path, "w", encoding="utf-8") as f:
        for p in clip_paths:
            escaped = os.path.abspath(p).replace("'", "'\\''")
            f.write(f"file '{escaped}'\n")
    subprocess.run(
        ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", list_path,
         "-c", "copy", "-movflags", "+faststart", output_path],
        check=True,
    )


def _probe_duration_sec(path: str) -> float:
    """Container duration of a rendered clip via ffprobe. Used for the
    description's timestamps instead of the source audio durations, so the
    times match the concatenated output exactly (encoder frame/audio-priming
    rounding included)."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(out)


def format_timestamp(seconds: float) -> str:
    """m:ss, switching to h:mm:ss past the one-hour mark."""
    s = int(seconds)
    if s >= 3600:
        return f"{s // 3600}:{(s % 3600) // 60:02d}:{s % 60:02d}"
    return f"{s // 60}:{s % 60:02d}"


def write_description(entries, output_video_path: str) -> str:
    """
    Writes a ready-to-paste tracklist for the video description, one line per
    track in final-video order: 'song title - artist m:ss', where the time is
    the track's start position in the concatenated video. `entries` is the
    ordered list of (track, clip_path) pairs that actually made it into the
    final video (failed/skipped tracks never appear, and their absence shifts
    the later timestamps correctly since times come from the real clips).

    Note: YouTube's automatic chapter detection requires the timestamp at the
    START of each line and the first one to be 0:00 — if you want clickable
    chapters rather than a plain tracklist, swap each line to
    '{timestamp} {title} - {artist}' before pasting.
    """
    lines = []
    t = 0.0
    for track, clip_path in entries:
        lines.append(f"{track.title} - {track.artist} {format_timestamp(t)}")
        t += _probe_duration_sec(clip_path)
    desc_path = os.path.splitext(output_video_path)[0] + "_description.txt"
    with open(desc_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return desc_path


def download_track_media(
    track: Track,
    workdir: str,
    cookies_file: Optional[str] = None,
    on_fraction: Optional[Callable[[float], None]] = None,
) -> Track:
    """Fetch artwork + audio for one track (thread-pool friendly)."""
    track.artwork_path = download_artwork(track, workdir)
    track.audio_path = download_audio(
        track, workdir, cookies_file=cookies_file, on_fraction=on_fraction,
    )
    if not track.artwork_path:
        track.artwork_path = download_artwork(track, workdir)
    return track


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


# ==============================================================================
# Main pipeline
# ==============================================================================

def parse_resolution(s: str):
    w, h = s.lower().split("x")
    return (int(w), int(h))


def _write_silence_wav(path: str, duration: float, sample_rate: int = 44100) -> None:
    import wave
    n_frames = max(1, int(duration * sample_rate))
    with wave.open(path, "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00\x00" * n_frames)


def run_marquee_test(args) -> None:
    resolution = parse_resolution(args.test_marquee_resolution)
    duration = args.test_marquee_duration
    workdir = tempfile.mkdtemp(prefix="amp_marquee_test_")
    font_dir = args.font_dir or try_download_pretendard(os.path.join(workdir, "fonts"))
    silent_wav = os.path.join(workdir, "silence.wav")
    _write_silence_wav(silent_wav, duration)
    track = Track(
        title=args.test_marquee_text,
        artist=args.test_marquee_artist,
        album=args.test_marquee_album,
        index=1, total=1,
    )
    track.audio_path = silent_wav
    track.artwork_path = None
    print(f"Rendering marquee test: {resolution[0]}x{resolution[1]} @ {args.fps}fps, "
          f"{duration}s -> {args.test_marquee_output}")
    clip = build_track_clip(track, resolution, args.fps, background_image=None, font_dir=font_dir)
    clip = clip.without_audio()
    encode = resolve_encode_settings(args.gpu, args.preset, args.crf, resolution, args.fps)
    write_kwargs = dict(
        fps=args.fps, codec=encode.codec, audio=False, threads=os.cpu_count() or 2,
        ffmpeg_params=encode.ffmpeg_params,
    )
    if encode.preset is not None:
        write_kwargs["preset"] = encode.preset
    clip.write_videofile(args.test_marquee_output, **write_kwargs)
    print("Done:", args.test_marquee_output)


def run_pipeline(
    config: PipelineConfig,
    on_progress: Optional[ProgressCallback] = None,
) -> PipelineResult:
    """Full playlist → video pipeline with optional progress callbacks."""
    import threading
    import time

    quiet = config.quiet
    resolution = parse_resolution(config.resolution)
    workdir = config.workdir or tempfile.mkdtemp(prefix="amp_video_")
    os.makedirs(workdir, exist_ok=True)
    out_dir = os.path.dirname(os.path.abspath(config.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    background_images = resolve_background_images(config.background_images, workdir)

    cookies_file = config.cookies_file
    if cookies_file:
        if not os.path.exists(cookies_file):
            raise FileNotFoundError(f"cookies file not found: {cookies_file}")
        writable_cookies = os.path.join(workdir, "cookies.txt")
        shutil.copyfile(cookies_file, writable_cookies)
        cookies_file = writable_cookies

    font_dir = config.font_dir
    if font_dir is None:
        font_dir = try_download_pretendard(os.path.join(workdir, "fonts"))

    _emit(on_progress, ProgressEvent(
        phase="fetch", completed=0, total=1, message="Fetching track list…",
    ))
    if config.tracks is not None:
        tracks = list(config.tracks)
    elif config.tracks_json:
        tracks = get_manual_tracks(config.tracks_json)
    else:
        if not config.playlist_url:
            raise ValueError("Provide playlist_url, tracks_json, or tracks")
        if not quiet:
            print("Fetching track list...")
        tracks = fetch_playlist_tracks(config.playlist_url, config.force_browser_scrape)
    if not quiet:
        print(f"  found {len(tracks)} tracks")
    _emit(on_progress, ProgressEvent(
        phase="fetch", completed=1, total=1,
        message=f"Found {len(tracks)} tracks",
    ))

    if config.shuffle:
        random.shuffle(tracks)
        for i, t in enumerate(tracks):
            t.index = i + 1

    if config.limit is not None:
        tracks = tracks[: config.limit]

    for i, t in enumerate(tracks):
        t.index, t.total = i + 1, len(tracks)

    if len(background_images) > len(tracks):
        raise ValueError(
            f"{len(background_images)} background images but only {len(tracks)} track(s)"
        )

    track_backgrounds = assign_track_backgrounds(tracks, background_images)

    for t in tracks:
        _emit(on_progress, ProgressEvent(
            phase="download", completed=0, total=len(tracks),
            message="pending",
            track_index=t.index,
            track_label=track_label(t),
            track_status="pending",
        ))

    if not quiet:
        print(f"Downloading audio + artwork for {len(tracks)} tracks ({config.workers} at a time)...")
    download_workers = max(1, config.workers)
    slot_pool: List[int] = list(range(download_workers))
    slot_lock = threading.Lock()
    done_count = 0
    done_lock = threading.Lock()

    def _download_one(track: Track) -> Track:
        nonlocal done_count
        with slot_lock:
            slot_id = slot_pool.pop(0) if slot_pool else 0
        label = track_label(track)

        def on_fraction(frac: float) -> None:
            with done_lock:
                completed = done_count
            _emit(on_progress, ProgressEvent(
                phase="download",
                completed=completed,
                total=len(tracks),
                message=f"Downloading {label}",
                track_index=track.index,
                track_label=label,
                track_status="downloading",
                slot_id=slot_id,
                fraction=frac,
            ))

        with done_lock:
            completed = done_count
        _emit(on_progress, ProgressEvent(
            phase="download", completed=completed, total=len(tracks),
            message=f"Downloading {label}",
            track_index=track.index, track_label=label,
            track_status="downloading", slot_id=slot_id, fraction=0.0,
        ))
        try:
            download_track_media(track, workdir, cookies_file, on_fraction=on_fraction)
        finally:
            with done_lock:
                completed = done_count
            _emit(on_progress, ProgressEvent(
                phase="download",
                completed=completed,
                total=len(tracks),
                message="",
                track_index=track.index,
                track_label=label,
                track_status=None,
                slot_id=slot_id,
                fraction=None,
            ))
            with slot_lock:
                slot_pool.append(slot_id)
        return track

    with ThreadPoolExecutor(max_workers=download_workers) as pool:
        futures = {pool.submit(_download_one, t): t for t in tracks}
        for future in as_completed(futures):
            track = futures[future]
            with done_lock:
                done_count += 1
                completed = done_count
            try:
                future.result()
                status = "ok" if track.audio_path else "skipped"
            except Exception as e:
                status = "failed"
                if not quiet:
                    print(f"  [{completed}/{len(tracks)}] {track_label(track)}: failed ({e})")
            else:
                if not quiet:
                    print(
                        f"  [{completed}/{len(tracks)}] {track_label(track)}: "
                        f"{'ok' if track.audio_path else 'no audio found'}"
                    )
            _emit(on_progress, ProgressEvent(
                phase="download",
                completed=completed,
                total=len(tracks),
                message=f"{track_label(track)}: {status}",
                track_index=track.index,
                track_label=track_label(track),
                track_status=status,
                fraction=1.0 if status == "ok" else None,
            ))

    encode = resolve_encode_settings(
        config.gpu, config.preset, config.crf, resolution, config.fps,
    )

    renderable = [
        (track, track_bg) for track, track_bg in zip(tracks, track_backgrounds) if track.audio_path
    ]
    for track in tracks:
        if not track.audio_path:
            if not quiet:
                print(f"  [{track.index}/{track.total}] {track_label(track)}: skipping (no audio)")
            _emit(on_progress, ProgressEvent(
                phase="render", completed=0, total=max(len(renderable), 1),
                message=f"Skipping {track_label(track)}",
                track_index=track.index, track_label=track_label(track),
                track_status="skipped",
            ))
    if not renderable:
        raise RuntimeError("No tracks with audio. Aborting.")

    cpu_count = os.cpu_count() or 4
    render_workers = config.render_workers or min(len(renderable), cpu_count)
    render_workers = max(1, render_workers)
    ffmpeg_threads = max(1, cpu_count // render_workers)
    if not quiet:
        print(
            f"Rendering {len(renderable)} clips ({render_workers} in parallel, "
            f"{ffmpeg_threads} ffmpeg thread(s) each)..."
        )

    clip_paths: List[Optional[str]] = [None] * len(renderable)
    overall_bar = None
    if not quiet:
        from tqdm import tqdm
        overall_bar = tqdm(total=len(renderable), desc="Overall", position=render_workers, leave=True)

    rendered_done = 0
    pool, position_pool, progress_queue, cleanup_pool = _open_render_pool(
        render_workers, quiet
    )
    try:
        futures = {}
        for i, (track, track_bg) in enumerate(renderable):
            out_path = os.path.join(workdir, f"clip_{track.index:03d}.mp4")
            fut = pool.submit(
                render_track_to_file, track, track_bg, resolution, config.fps,
                font_dir, config.transition_duration, encode, out_path, position_pool,
                ffmpeg_threads, progress_queue, quiet,
            )
            futures[fut] = (i, track, out_path)
            _emit(on_progress, ProgressEvent(
                phase="render", completed=0, total=len(renderable),
                message=f"Queued {track_label(track)}",
                track_index=track.index, track_label=track_label(track),
                track_status="pending",
            ))

        pending = set(futures.keys())
        while pending:
            _drain_render_queue(progress_queue, on_progress, rendered_done, len(renderable))
            done_now = [fut for fut in pending if fut.done()]
            if not done_now:
                time.sleep(0.05)
                continue
            for fut in done_now:
                pending.discard(fut)
                i, track, out_path = futures[fut]
                try:
                    fut.result()
                    clip_paths[i] = out_path
                    status = "ok"
                    msg = f"Rendered {track_label(track)}"
                    if not quiet and overall_bar is not None:
                        from tqdm import tqdm as _tqdm
                        _tqdm.write(
                            f"  [{rendered_done + 1}/{len(renderable)}] {track_label(track)}: rendered"
                        )
                except Exception as e:
                    status = "failed"
                    msg = f"Failed {track_label(track)}: {e}"
                    if not quiet and overall_bar is not None:
                        from tqdm import tqdm as _tqdm
                        _tqdm.write(
                            f"  [{rendered_done + 1}/{len(renderable)}] ! failed {track_label(track)}: {e}"
                        )
                rendered_done += 1
                if overall_bar is not None:
                    overall_bar.update(1)
                _emit(on_progress, ProgressEvent(
                    phase="render",
                    completed=rendered_done,
                    total=len(renderable),
                    message=msg,
                    track_index=track.index,
                    track_label=track_label(track),
                    track_status=status,
                    fraction=1.0 if status == "ok" else None,
                ))
        _drain_render_queue(progress_queue, on_progress, rendered_done, len(renderable))
    finally:
        cleanup_pool()

    if overall_bar is not None:
        overall_bar.close()

    finished_paths = [p for p in clip_paths if p]
    if not finished_paths:
        raise RuntimeError("No clips were rendered successfully. Aborting.")

    _emit(on_progress, ProgressEvent(
        phase="concat", completed=0, total=1,
        message=f"Stitching {len(finished_paths)} clips…",
    ))
    if not quiet:
        print(f"Stitching {len(finished_paths)} rendered clip(s) into {config.output} ...")
    concat_clips(finished_paths, config.output, workdir)

    entries = [(renderable[i][0], p) for i, p in enumerate(clip_paths) if p]
    desc_path = write_description(entries, config.output)
    with open(desc_path, "r", encoding="utf-8") as f:
        description_text = f.read()

    _emit(on_progress, ProgressEvent(
        phase="done", completed=1, total=1,
        message=f"Done: {config.output}",
    ))
    if not quiet:
        print(f"\nDescription ({desc_path}):")
        print(description_text.rstrip())
        print("\nDone:", config.output)

    return PipelineResult(
        output_path=config.output,
        description_path=desc_path,
        tracks=tracks,
        description_text=description_text,
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a YouTube playlist video from an Apple Music playlist."
    )
    parser.add_argument("playlist_url", nargs="?", help="Apple Music playlist URL")
    parser.add_argument("--output", default="output/playlist_video.mp4", help="Output video file")
    parser.add_argument("--background-image", nargs="+", default=None)
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--no-shuffle", action="store_true")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--tracks-json", default=None)
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--font-dir", default=None)
    parser.add_argument(
        "--fast-scrape",
        action="store_true",
        help="Try the fast HTML scrape first instead of Chromium (default is Playwright/Chromium)",
    )
    parser.add_argument(
        "--force-browser-scrape",
        action="store_true",
        help=argparse.SUPPRESS,  # legacy no-op; Chromium is already the default
    )
    parser.add_argument("--transition-duration", type=float, default=0.6)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--render-workers", type=int, default=None)
    parser.add_argument("--cookies-file", default=None)
    parser.add_argument("--gpu", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--preset", default=None)
    parser.add_argument("--crf", type=int, default=None)
    parser.add_argument("--test-marquee", action="store_true")
    parser.add_argument("--test-marquee-text",
                        default="This Is A Very Long Song Title That Should Definitely Scroll")
    parser.add_argument("--test-marquee-artist", default="A Fairly Long Test Artist Name")
    parser.add_argument("--test-marquee-album", default="An Equally Long Test Album Title")
    parser.add_argument("--test-marquee-duration", type=float, default=12.0)
    parser.add_argument("--test-marquee-resolution", default="960x540")
    parser.add_argument("--test-marquee-output", default="marquee_test.mp4")
    return parser


def config_from_args(args) -> PipelineConfig:
    return PipelineConfig(
        playlist_url=args.playlist_url,
        output=args.output,
        resolution=args.resolution,
        fps=args.fps,
        limit=args.limit,
        background_images=args.background_image,
        shuffle=not args.no_shuffle,
        workers=args.workers,
        render_workers=args.render_workers,
        gpu=args.gpu,
        transition_duration=args.transition_duration,
        cookies_file=args.cookies_file,
        tracks_json=args.tracks_json,
        workdir=args.workdir,
        font_dir=args.font_dir,
        force_browser_scrape=not args.fast_scrape,
        preset=args.preset,
        crf=args.crf,
        quiet=False,
    )


def main():
    parser = build_arg_parser()
    args = parser.parse_args()
    if args.test_marquee:
        run_marquee_test(args)
        return
    if not args.playlist_url and not args.tracks_json:
        parser.error("Provide a playlist_url or --tracks-json")
    try:
        run_pipeline(config_from_args(args))
    except (FileNotFoundError, ValueError, RuntimeError) as e:
        print(f"! {e}")
        sys.exit(1)


def _argv_from_config():
    argv = [
        PLAYLIST_URL,
        "--output", OUTPUT,
        "--resolution", RESOLUTION,
        "--fps", str(FPS),
        "--workers", str(WORKERS),
        "--gpu", GPU,
        *(["--render-workers", str(RENDER_WORKERS)] if RENDER_WORKERS else []),
        "--transition-duration", str(TRANSITION_DURATION),
    ]
    if LIMIT is not None:
        argv += ["--limit", str(LIMIT)]
    if BACKGROUND_IMAGE:
        images = [BACKGROUND_IMAGE] if isinstance(BACKGROUND_IMAGE, str) else list(BACKGROUND_IMAGE)
        argv += ["--background-image", *images]
    if not SHUFFLE:
        argv += ["--no-shuffle"]
    if COOKIES_FILE:
        argv += ["--cookies-file", COOKIES_FILE]
    return argv


if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.argv[1:] = _argv_from_config()
    main()
