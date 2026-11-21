# Playlist Gen

Turn an [Apple Music](https://music.apple.com) playlist into a YouTube-ready video — with a Textual TUI for setup, track picking, and live progress.

Scrapes the tracklist, downloads audio via yt-dlp (duration-checked against Apple Music when possible), renders album art + scrolling title cards, then stitches clips with ffmpeg. Optimized for macOS / Apple Silicon (VideoToolbox HEVC), with NVENC and libx264 fallbacks.

## macOS app

A native AppKit + SwiftUI app lives in `macos/` (macOS 27, Apple silicon recommended).
Python still reads the playlist and downloads audio with yt-dlp; the app draws every
frame with Core Graphics + Core Image on the GPU (Metal) and encodes with
AVFoundation/VideoToolbox — no ffmpeg pipe.

```bash
macos/build-app.sh --open        # builds macos/build/Playlist Gen.app and launches it
```

- Paste a playlist link (or **Paste Link and Load**), pick / reorder / rename songs, then **Generate Video** (⌘↩).
- Double-click a title, artist or album to edit it. Edits appear in the video and chapters;
  the YouTube search keeps using Apple Music's original metadata.
- The inspector shows a live preview drawn by the same renderer as the video.
- Settings (⌘,) has the video format (HEVC / H.264), concurrency, and where the Python project and `uv` live.
- `macos/Resources/AppIcon.icon` is an Icon Composer document.

Developer bits: `swift test --package-path macos` runs the tests;
`swift run --package-path macos render-frame --help` renders single frames or a whole clip.

## Requirements

```bash
brew install ffmpeg deno
uv sync
uv run playwright install chromium   # required — Chromium scrape is the default
```

Python 3.10+ via [uv](https://docs.astral.sh/uv/).

## Quick start (TUI)

```bash
uv run app.py
# or after sync:
uv run playlist-gen
```

1. Paste an Apple Music playlist URL → **Load tracks** (`L`)
2. Toggle tracks with **space** (or `A` / `N` for all / none)
3. Set resolution, backgrounds, workers, etc.
4. **Generate** (`G`) — watch overall + per-slot download/render bars
5. **Cancel** (`C`) stops downloads and kills in-flight ffmpeg encodes

Output: `output/playlist_video.mp4` + `output/playlist_video_description.txt` (YouTube chapter format, ready to paste).

## Headless / scripting

```bash
uv run apple_music_playlist_video.py "https://music.apple.com/…/playlist/…" \
  --output output/playlist_video.mp4 \
  --resolution 1920x1080 \
  --background-image assets/backgrounds/bg1.jpeg \
  --limit 5

# or:
uv run playlist-gen-cli "https://music.apple.com/…/playlist/…" --limit 2
```

Or edit the defaults in `playlist_video/config.py` and run with no args.

```bash
uv run apple_music_playlist_video.py --help
```

## Layout

```
playlist-gen/
├── app.py                          # TUI entry (uv run app.py)
├── apple_music_playlist_video.py   # headless CLI entry
├── pyproject.toml                  # deps + playlist-gen / playlist-gen-cli scripts
├── macos/                          # AppKit + SwiftUI app, Swift renderer (PlaylistRender)
├── playlist_video/                 # pipeline package (bridge.py = JSON-lines API for the app)
│   ├── config.py                   #   user-editable defaults
│   ├── models.py                   #   Track / PipelineConfig / progress / cancel
│   ├── scraper.py                  #   Apple Music scraping (amp-api + Chromium)
│   ├── downloader.py               #   yt-dlp audio + artwork + duration match
│   ├── fonts.py / backgrounds.py / text.py / frames.py / transitions.py
│   ├── encoding.py                 #   VideoToolbox / NVENC / libx264 + raw ffmpeg pipe
│   ├── progress.py / render.py / pipeline.py / cli.py
│   └── tui/                        #   Textual TUI
├── tests/                          # pytest (no network)
├── assets/backgrounds/
├── output/
└── README.md
```

## Notes

- Audio comes from YouTube search matches via yt-dlp. When Apple Music provides a duration, candidates more than 20% off are rejected and the next search hit is tried.
- Description file uses YouTube chapter format (`0:00 Title - Artist`).
- Defaults: 1080p, no shuffle, full playlist (`LIMIT = None`). Use `--limit` / TUI selection while iterating.
- Scraping defaults to headless Chromium. Opt into the old HTML path with `--fast-scrape`.
- Generated media under `output/` is gitignored.

## License

Use / modify as you like. You are responsible for copyright compliance on any audio or artwork you publish.
