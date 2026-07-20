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
"""Headless CLI entry point.

Turn an Apple Music playlist into a single video:

    uv run apple_music_playlist_video.py "https://music.apple.com/…/playlist/…"
    uv run apple_music_playlist_video.py            # uses playlist_video/config.py
    uv run apple_music_playlist_video.py --help

System requirements (once):
    brew install ffmpeg deno         # ffmpeg for encoding, deno for yt-dlp's JS challenge
    uv run playwright install chromium   # Chromium scrape is the default path

The implementation lives in the playlist_video package:

    playlist_video/config.py    user-editable defaults (edit these!)
    playlist_video/pipeline.py  fetch → download → render → concat orchestration
    playlist_video/frames.py    the per-track frame generator
    playlist_video/encoding.py  VideoToolbox / NVENC / libx264 selection
    ...

GPU encoding: on macOS this uses VideoToolbox automatically when GPU="auto" —
HEVC (hevc_videotoolbox) with constant-quality mode (-q:v) on Apple Silicon
when the ffmpeg build has it, which is ~35-45% smaller than H.264 at the same
perceptual quality with no encode-speed cost (same hardware media engine).
H.264 VideoToolbox is the fallback. On Linux with an NVIDIA GPU it uses
NVENC. Elsewhere it falls back to libx264 (software). Output is always an mp4.

Rendering is parallelized per-track across CPU cores (each track's frames +
encode happen in its own process), then the finished per-track clips are
stitched with a lossless ffmpeg concat (no re-encode).
"""

# Backward-compatible re-exports: this module used to contain the whole
# pipeline, so keep its old public surface importable from here.
from playlist_video import (  # noqa: F401
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
    COOKIES_FILE,
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
