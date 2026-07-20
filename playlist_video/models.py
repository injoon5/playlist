"""Shared data model: tracks, pipeline configuration, and progress events."""

from dataclasses import dataclass, field
from threading import Event
from typing import Callable, List, Optional


class CancelledError(Exception):
    """Raised when the pipeline is cancelled cooperatively."""


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
    matched_video_title: Optional[str] = None


@dataclass
class PipelineConfig:
    playlist_url: Optional[str] = None
    output: str = "output/playlist_video.mp4"
    resolution: str = "1920x1080"
    fps: int = 30
    limit: Optional[int] = None
    background_images: Optional[List[str]] = None
    shuffle: bool = False
    workers: int = 4
    render_workers: Optional[int] = None
    gpu: str = "auto"
    transition_duration: float = 0.6
    tracks_json: Optional[str] = None
    workdir: Optional[str] = None
    font_dir: Optional[str] = None
    force_browser_scrape: bool = True  # Chromium by default; False = try fast HTML first
    preset: Optional[str] = None
    crf: Optional[int] = None
    quiet: bool = False
    # Pre-fetched / user-selected tracks from the TUI. When set, scrape is skipped.
    tracks: Optional[List[Track]] = None
    # Cooperative cancel: set by TUI Cancel; download/render poll and abort.
    cancel_event: Event = field(default_factory=Event)


@dataclass
class ProgressEvent:
    phase: str  # fetch | download | render | concat | done | cancelled
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


def emit_progress(on_progress: Optional[ProgressCallback], event: ProgressEvent) -> None:
    if on_progress is not None:
        on_progress(event)


def check_cancelled(cancel_event: Optional[Event]) -> None:
    if cancel_event is not None and cancel_event.is_set():
        raise CancelledError("Cancelled")
