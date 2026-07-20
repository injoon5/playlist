"""Apple Music playlist → video pipeline.

Public API:
    run_pipeline(config, on_progress=...)   full playlist → video pipeline
    fetch_playlist_tracks(url)              scrape an Apple Music playlist
    PipelineConfig / Track / ProgressEvent / PipelineResult

User-editable defaults live in playlist_video.config; the headless CLI is
playlist_video.cli and the Textual TUI is playlist_video.tui.
"""

from .models import (
    PipelineConfig,
    PipelineResult,
    ProgressCallback,
    ProgressEvent,
    Track,
    track_label,
)
from .pipeline import parse_resolution, run_pipeline
from .scraper import fetch_playlist_tracks, get_manual_tracks

__all__ = [
    "PipelineConfig",
    "PipelineResult",
    "ProgressCallback",
    "ProgressEvent",
    "Track",
    "track_label",
    "parse_resolution",
    "run_pipeline",
    "fetch_playlist_tracks",
    "get_manual_tracks",
]
