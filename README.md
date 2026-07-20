# Playlist Gen

Turn an [Apple Music](https://music.apple.com) playlist into a YouTube-ready video — with a Textual TUI for setup, track picking, and live progress.

Scrapes the tracklist, downloads audio via yt-dlp, renders album art + scrolling title cards, then stitches clips with ffmpeg. Optimized for macOS / Apple Silicon (VideoToolbox HEVC), with NVENC and libx264 fallbacks.

## Requirements

```bash
brew install ffmpeg deno uv
uv run playwright install chromium   # required — Chromium scrape is the default
```

Python 3.10+ (deps via [uv](https://docs.astral.sh/uv/) script headers).

## Quick start (TUI)

```bash
uv run app.py
```

1. Paste an Apple Music playlist URL → **Load tracks** (`L`)
2. Toggle tracks with **space** (or `A` / `N` for all / none)
3. Set resolution, backgrounds, workers, etc.
4. **Generate** (`G`) — watch overall + per-slot download/render bars

Output: `output/playlist_video.mp4` + `output/playlist_video_description.txt`

## Headless / scripting

```bash
uv run apple_music_playlist_video.py "https://music.apple.com/…/playlist/…" \
  --output output/playlist_video.mp4 \
  --resolution 1920x1080 \
  --background-image assets/backgrounds/bg1.jpeg \
  --limit 5
```

Or edit the `CONFIG` block at the top of `apple_music_playlist_video.py` and run with no args.

```bash
uv run apple_music_playlist_video.py --help
```

## Layout

```
playlist-gen/
├── app.py                          # Textual TUI (default entry)
├── app.tcss                        # TUI styles
├── apple_music_playlist_video.py   # pipeline library + headless CLI
├── assets/backgrounds/             # sample / custom backgrounds
├── output/                         # generated videos (gitignored)
├── README.md
└── .gitignore
```

## Notes

- Audio comes from YouTube search matches via yt-dlp — verify before uploading.
- TUI Run screen shows overall progress plus concurrent slot bars (download % / render frames).
- Use `--limit` / the Limit field while iterating at 4K.
- Scraping defaults to headless Chromium. Opt into the old HTML path with `--fast-scrape`.
- Generated media under `output/` is gitignored.

## License

Use / modify as you like. You are responsible for copyright compliance on any audio or artwork you publish.
