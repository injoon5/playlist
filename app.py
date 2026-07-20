# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "textual",
#     "yt-dlp[default]",
#     "pillow",
#     "requests",
#     "numpy",
#     "playwright",
#     "tqdm",
# ]
# ///
"""Textual TUI entry point:  uv run app.py

Prefer: uv sync && uv run playlist-gen
The TUI lives in playlist_video/tui/; the pipeline in playlist_video/.
"""

from playlist_video.tui.app import main

if __name__ == "__main__":
    main()
