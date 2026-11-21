"""Bridge used by the macOS app — pure helpers only (no fd redirection, no network)."""

import io
import json
from threading import Event
from unittest.mock import patch

from playlist_video import bridge
from playlist_video.config import PROJECT_ROOT


def test_track_from_json_fills_missing_fields():
    t = bridge._track_from_json({"title": "밤편지", "artist": None, "duration_ms": 1000})
    assert t.title == "밤편지"
    assert t.artist == "Unknown Artist"
    assert t.album == ""
    assert t.duration_ms == 1000


def test_track_round_trip_keeps_wire_keys():
    t = bridge._track_from_json({
        "title": "A", "artist": "B", "album": "C",
        "artwork_url": "https://x/a.jpg", "duration_ms": 5,
    })
    t.index = 3
    assert bridge._track_to_json(t) == {
        "index": 3, "title": "A", "artist": "B", "album": "C",
        "artwork_url": "https://x/a.jpg", "duration_ms": 5,
    }


def test_abs_resolves_against_project_root():
    assert bridge._abs("output/x.mp4") == str(PROJECT_ROOT / "output/x.mp4")
    assert bridge._abs("/tmp/x.mp4") == "/tmp/x.mp4"
    assert bridge._abs("https://example.com/a.jpg") == "https://example.com/a.jpg"


def test_cancel_line_sets_event():
    event = Event()
    with patch("sys.stdin", io.StringIO("noise\ncancel\nmore\n")):
        bridge._watch_stdin_for_cancel(event)
    assert event.is_set()


def test_stdin_eof_cancels():
    # The app closing its end of the pipe (quit / crash) must stop the run.
    event = Event()
    with patch("sys.stdin", io.StringIO("")):
        bridge._watch_stdin_for_cancel(event)
    assert event.is_set()


def test_emitter_throttles_bar_ticks_but_not_status_changes():
    sent = []

    class FakeEmitter(bridge._Emitter):
        def __init__(self):  # skip fd redirection
            self._lock = __import__("threading").Lock()
            self._last_bar = {}

        def send(self, payload):
            sent.append(payload)

    out = FakeEmitter()
    tick = dict(phase="download", completed=0, total=1, message="", track_index=1,
                track_label="A - B", track_status="downloading", slot_id=0)
    for f in (0.1, 0.2, 0.3):
        out.progress(bridge.ProgressEvent(fraction=f, **tick))
    out.progress(bridge.ProgressEvent(
        phase="download", completed=1, total=1, message="A - B: ok",
        track_index=1, track_label="A - B", track_status="ok", fraction=1.0,
    ))
    assert len([p for p in sent if p["track_status"] == "downloading"]) == 1
    assert sent[-1]["track_status"] == "ok"
    json.dumps(sent)  # everything is serialisable
