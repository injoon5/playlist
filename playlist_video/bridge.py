"""JSON-lines bridge for native front-ends (the macOS app in macos/).

Every message on stdout is one JSON object per line. Anything else the
pipeline (or a library) prints is redirected to stderr, so stdout stays a
clean protocol channel.

Commands:

    python -m playlist_video.bridge defaults
        -> {"type": "defaults", ...}

    python -m playlist_video.bridge fetch URL [--fast-scrape]
        -> {"type": "tracks", "tracks": [...]}

    python -m playlist_video.bridge download
        stdin line 1: {"tracks": [...], "workers": N, "workdir": PATH}
        stdin after:  "cancel" (or EOF) cancels cooperatively
        -> {"type": "progress", ...ProgressEvent}  repeated
           {"type": "downloaded", "tracks": [{index, audio_path, artwork_path,
                                              matched_video_title}]}
           | {"type": "cancelled"}

Rendering, encoding and concat happen in the macOS app (macos/Sources/
PlaylistRender); this bridge only scrapes and downloads with the existing
Python code (Apple Music scrape, yt-dlp, artwork).

Any failure ends with {"type": "error", "message": ..., "detail": ...} and a
non-zero exit status.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import signal
import sys
import tempfile
import threading
import time
import traceback
from typing import Any, Dict, List, Optional

from . import config as defaults
from .models import CancelledError, PipelineConfig, ProgressEvent, Track

# Progress events that only move a bar are throttled to this interval per
# (phase, slot); status changes always go through.
_PROGRESS_INTERVAL = 0.05

_TRACK_INPUT_FIELDS = ("title", "artist", "album", "artwork_url", "duration_ms")


class _Emitter:
    """Thread-safe JSON-lines writer bound to the original stdout fd."""

    def __init__(self) -> None:
        sys.stdout.flush()
        # Keep a private handle to the real stdout, then point fd 1 at stderr
        # so stray prints and inherited child-process output can't corrupt
        # the protocol stream.
        self._out = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
        os.dup2(2, 1)
        sys.stdout = sys.stderr
        self._lock = threading.Lock()
        self._last_bar: Dict[tuple, float] = {}

    def send(self, payload: Dict[str, Any]) -> None:
        line = json.dumps(payload, ensure_ascii=False, default=str)
        with self._lock:
            try:
                self._out.write(line + "\n")
                self._out.flush()
            except (BrokenPipeError, ValueError):
                pass  # front-end went away; nothing useful left to do

    def progress(self, ev: ProgressEvent) -> None:
        is_bar_tick = ev.fraction is not None and ev.track_status in {"downloading", "rendering"}
        if is_bar_tick and ev.slot_id is not None:
            key = (ev.phase, ev.slot_id)
            now = time.monotonic()
            with self._lock:
                last = self._last_bar.get(key, 0.0)
                if now - last < _PROGRESS_INTERVAL and (ev.fraction or 0.0) < 1.0:
                    return
                self._last_bar[key] = now
        self.send({"type": "progress", **dataclasses.asdict(ev)})


def _track_to_json(t: Track) -> Dict[str, Any]:
    return {
        "index": t.index,
        "title": t.title,
        "artist": t.artist,
        "album": t.album,
        "artwork_url": t.artwork_url,
        "duration_ms": t.duration_ms,
    }


def _track_from_json(d: Dict[str, Any]) -> Track:
    kwargs = {k: d.get(k) for k in _TRACK_INPUT_FIELDS}
    kwargs["title"] = kwargs["title"] or "Unknown Title"
    kwargs["artist"] = kwargs["artist"] or "Unknown Artist"
    kwargs["album"] = kwargs["album"] or ""
    return Track(**kwargs)


def _abs(path: str) -> str:
    """Resolve a path relative to the project root, like the TUI does."""
    if path.startswith(("http://", "https://")) or os.path.isabs(path):
        return path
    return str(defaults.PROJECT_ROOT / path)


def cmd_defaults(out: _Emitter) -> int:
    bg = defaults.BACKGROUND_IMAGE
    if isinstance(bg, str):
        bg = [bg]
    out.send({
        "type": "defaults",
        "project_root": str(defaults.PROJECT_ROOT),
        "playlist_url": "" if "YOUR-PLAYLIST" in defaults.PLAYLIST_URL else defaults.PLAYLIST_URL,
        "output": _abs(defaults.OUTPUT),
        "resolution": defaults.RESOLUTION,
        "fps": defaults.FPS,
        "workers": defaults.WORKERS,
        "render_workers": defaults.RENDER_WORKERS,
        "gpu": defaults.GPU,
        "shuffle": defaults.SHUFFLE,
        "transition_duration": defaults.TRANSITION_DURATION,
        "background_images": [_abs(p) for p in (bg or [])],
        "backgrounds_dir": str(defaults.PROJECT_ROOT / "assets" / "backgrounds"),
    })
    return 0


def cmd_fetch(out: _Emitter, url: str, fast_scrape: bool) -> int:
    from .scraper import fetch_playlist_tracks

    tracks = fetch_playlist_tracks(url, force_browser_scrape=not fast_scrape)
    for i, t in enumerate(tracks):
        t.index, t.total = i + 1, len(tracks)
    out.send({"type": "tracks", "tracks": [_track_to_json(t) for t in tracks]})
    return 0


def _watch_stdin_for_cancel(cancel: threading.Event) -> None:
    """Cancel on a "cancel" line or when stdin closes (the app quit or crashed)."""
    for line in sys.stdin:
        if line.strip().lower() == "cancel":
            break
    cancel.set()


def cmd_download(out: _Emitter) -> int:
    from .pipeline import _download_phase

    first = sys.stdin.readline()
    if not first.strip():
        raise ValueError("Expected a JSON download request on stdin")
    req = json.loads(first)
    tracks: List[Track] = []
    for i, d in enumerate(req.get("tracks") or []):
        t = _track_from_json(d)
        t.index = int(d.get("index") or i + 1)
        tracks.append(t)
    if not tracks:
        raise ValueError("Select at least one track")
    for t in tracks:
        t.total = len(tracks)

    workdir = req.get("workdir") or tempfile.mkdtemp(prefix="amp_video_")
    os.makedirs(workdir, exist_ok=True)
    config = PipelineConfig(workers=int(req.get("workers") or defaults.WORKERS), quiet=True)

    threading.Thread(
        target=_watch_stdin_for_cancel, args=(config.cancel_event,), daemon=True,
    ).start()
    signal.signal(signal.SIGTERM, lambda *_: config.cancel_event.set())

    try:
        _download_phase(tracks, workdir, config, out.progress)
    except CancelledError:
        out.send({"type": "cancelled"})
        return 130
    out.send({
        "type": "downloaded",
        "tracks": [
            {
                "index": t.index,
                "audio_path": t.audio_path,
                "artwork_path": t.artwork_path,
                "matched_video_title": t.matched_video_title,
            }
            for t in tracks
        ],
    })
    return 0


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="python -m playlist_video.bridge")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("defaults")
    fetch = sub.add_parser("fetch")
    fetch.add_argument("url")
    fetch.add_argument("--fast-scrape", action="store_true")
    sub.add_parser("download")
    args = parser.parse_args(argv)

    out = _Emitter()
    try:
        if args.command == "defaults":
            code = cmd_defaults(out)
        elif args.command == "fetch":
            code = cmd_fetch(out, args.url, args.fast_scrape)
        else:
            code = cmd_download(out)
    except KeyboardInterrupt:
        out.send({"type": "cancelled"})
        code = 130
    except Exception as e:  # noqa: BLE001 — report every failure to the front-end
        out.send({
            "type": "error",
            "message": str(e) or e.__class__.__name__,
            "detail": traceback.format_exc(),
        })
        code = 1
    sys.exit(code)


if __name__ == "__main__":
    main()
