"""User-editable defaults.

Edit these, then run:  uv run apple_music_playlist_video.py
(or launch the TUI with:  uv run app.py — the TUI pre-fills from these too).
"""

from pathlib import Path

# Repository root (the directory holding app.py / assets/ / output/).
PROJECT_ROOT = Path(__file__).resolve().parent.parent

PLAYLIST_URL = "https://music.apple.com/us/playlist/YOUR-PLAYLIST-ID"
OUTPUT = "output/playlist_video.mp4"
RESOLUTION = "1920x1080"
LIMIT = None         # None = whole playlist; use --limit / TUI selection to iterate

# Background: local path, http(s) URL, a list of either (split into contiguous blocks
# across the tracklist, switching at track/transition boundaries), or None for auto
# (blurred artwork / gradient, per track). Sample images live in assets/backgrounds/.
BACKGROUND_IMAGE = [
    "assets/backgrounds/bg1.jpeg",
    "assets/backgrounds/bg2.jpeg",
]
# BACKGROUND_IMAGE = None

SHUFFLE = False
WORKERS = 6          # tracks downloaded in parallel; network-bound, safe to raise
RENDER_WORKERS = 4   # tracks rendered (frames + encode) in parallel; CPU-bound — set to your actual core count
FPS = 30             # every moving thing here (marquee ~28 px/s, slow gradient pan, eased
                     # fades) moves around 1 px/frame or less at 30fps, so 30 is visually
                     # indistinguishable from 60 while halving frame-generation work,
                     # ffmpeg pipe traffic, AND encoded frame count. Set 60 if you insist.
GPU = "auto"         # "auto" | "on" | "off"  ("auto" picks VideoToolbox on macOS)
TRANSITION_DURATION = 0.6   # 0 to disable fade-through-black between tracks
