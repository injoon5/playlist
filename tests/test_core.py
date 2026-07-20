"""Unit tests — no network, no Playwright, no real ffmpeg encode."""

from threading import Event
from unittest.mock import MagicMock, patch

import pytest

from playlist_video.backgrounds import assign_track_backgrounds
from playlist_video.downloader import duration_mismatch
from playlist_video.models import CancelledError, Track, check_cancelled
from playlist_video.pipeline import parse_resolution
from playlist_video.render import format_timestamp, write_description
from playlist_video.text import ease_in_out_cubic, marquee_state


def test_format_timestamp_under_hour():
    assert format_timestamp(0) == "0:00"
    assert format_timestamp(65) == "1:05"
    assert format_timestamp(3599) == "59:59"


def test_format_timestamp_over_hour():
    assert format_timestamp(3600) == "1:00:00"
    assert format_timestamp(3661) == "1:01:01"


def test_write_description_youtube_chapters(tmp_path):
    """Chapter lines must be '{timestamp} {title} - {artist}' with 0:00 first."""
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    clip_a.write_bytes(b"x")
    clip_b.write_bytes(b"x")
    out = tmp_path / "out.mp4"

    tracks = [
        Track(title="First", artist="A", album="", index=1, total=2),
        Track(title="Second", artist="B", album="", index=2, total=2),
    ]

    with patch("playlist_video.render._probe_duration_sec", side_effect=[90.0, 120.0]):
        desc_path = write_description(
            [(tracks[0], str(clip_a)), (tracks[1], str(clip_b))],
            str(out),
        )

    text = open(desc_path, encoding="utf-8").read().strip().splitlines()
    assert text[0] == "0:00 First - A"
    assert text[1] == "1:30 Second - B"
    assert text[0].startswith("0:00 ")


def test_parse_resolution():
    assert parse_resolution("1920x1080") == (1920, 1080)
    assert parse_resolution("3840X2160") == (3840, 2160)


def test_assign_track_backgrounds_splits_evenly():
    tracks = [Track(title=str(i), artist="a", album="") for i in range(4)]
    images = ["bg1.jpg", "bg2.jpg"]
    assigned = assign_track_backgrounds(tracks, images)
    assert assigned == ["bg1.jpg", "bg1.jpg", "bg2.jpg", "bg2.jpg"]


def test_assign_track_backgrounds_empty():
    tracks = [Track(title="t", artist="a", album="")]
    assert assign_track_backgrounds(tracks, []) == [None]


def test_ease_in_out_cubic_bounds():
    assert ease_in_out_cubic(0.0) == 0.0
    assert ease_in_out_cubic(1.0) == 1.0
    assert 0.0 < ease_in_out_cubic(0.5) < 1.0


def test_marquee_state_holds_then_scrolls():
    tile_w = 280.0  # 10s slide at 28 px/s
    # During hold
    x, elapsed, remaining = marquee_state(1.0, tile_w, speed_px_per_sec=28.0, hold_seconds=2.6)
    assert x == 0.0
    assert elapsed is None
    # After hold starts sliding
    x, elapsed, remaining = marquee_state(3.0, tile_w, speed_px_per_sec=28.0, hold_seconds=2.6)
    assert x > 0.0
    assert elapsed is not None
    assert remaining is not None


def test_duration_mismatch():
    assert duration_mismatch(None, 100.0) is False
    assert duration_mismatch(180_000, None) is False
    assert duration_mismatch(180_000, 180.0) is False
    assert duration_mismatch(180_000, 200.0) is False  # ~11% ok
    assert duration_mismatch(180_000, 250.0) is True   # ~39% bad


def test_check_cancelled_raises():
    ev = Event()
    check_cancelled(ev)  # not set — ok
    ev.set()
    with pytest.raises(CancelledError):
        check_cancelled(ev)


def test_cancel_kills_download_popen():
    """When cancel_event is set mid-read, download kills the yt-dlp process."""
    from playlist_video import downloader

    ev = Event()
    track = Track(title="Song", artist="Artist", album="", duration_ms=180_000, index=1, total=1)

    class FakeStdout:
        def __iter__(self):
            yield "[download]  10.0% of 1MiB\n"
            ev.set()
            yield "[download]  20.0% of 1MiB\n"

    proc = MagicMock()
    proc.stdout = FakeStdout()
    proc.wait = MagicMock()
    proc.kill = MagicMock()

    with patch.object(downloader.subprocess, "Popen", return_value=proc):
        with patch.object(downloader, "_search_candidates", return_value=[("abc123", 180.0, "Song")]):
            with pytest.raises(CancelledError):
                downloader.download_audio(track, "/tmp", cancel_event=ev)

    proc.kill.assert_called()
