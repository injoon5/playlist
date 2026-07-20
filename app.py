# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "textual",
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
"""Textual TUI entry point:  uv run app.py

The TUI itself lives in playlist_video/tui/ (screens, widgets, messages);
the pipeline it drives lives in the playlist_video package.
"""

from playlist_video.tui.app import main

if __name__ == "__main__":
    main()
