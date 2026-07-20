# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "yt-dlp[default]",
#     "pillow",
#     "requests",
#     "numpy",
#     "playwright",
#     "tqdm",
# ]
# ///
"""Headless CLI entry point.

Turn an Apple Music playlist into a single video:

    uv run apple_music_playlist_video.py "https://music.apple.com/…/playlist/…"
    uv run apple_music_playlist_video.py            # uses playlist_video/config.py
    uv run apple_music_playlist_video.py --help

Prefer project mode after `uv sync`:
    uv run playlist-gen-cli …

System requirements (once):
    brew install ffmpeg deno         # ffmpeg for encoding, deno for yt-dlp's JS challenge
    uv run playwright install chromium   # Chromium scrape is the default path
"""

from playlist_video import (  # noqa: F401
    CancelledError,
    PipelineConfig,
    PipelineResult,
    ProgressEvent,
    Track,
    fetch_playlist_tracks,
    run_pipeline,
)
from playlist_video.cli import main
from playlist_video.config import (  # noqa: F401
    BACKGROUND_IMAGE,
    FPS,
    GPU,
    LIMIT,
    OUTPUT,
    PLAYLIST_URL,
    RENDER_WORKERS,
    RESOLUTION,
    SHUFFLE,
    TRANSITION_DURATION,
    WORKERS,
)

if __name__ == "__main__":
    main()
