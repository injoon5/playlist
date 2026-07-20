"""Per-track media acquisition: audio via the yt-dlp CLI, artwork via HTTP."""

import os
import re
import subprocess
from threading import Event
from typing import Callable, List, Optional, Tuple

import requests

from .models import CancelledError, Track, check_cancelled

# YouTube's bot-check ("Sign in to confirm you're not a bot") hits datacenter
# IPs far more than home connections. The android/ios clients use a different
# auth flow than the default web client and often aren't flagged even when web
# is; tv_embedded is a third fallback. Order matters: cheapest first.
YT_DLP_CLIENT_FALLBACKS = ["android", "ios", "tv_embedded", "web"]

_RETRYABLE_PATTERNS = ["sign in to confirm", "not a bot", "requested format is not available"]

# How far a YouTube hit's duration may drift from Apple Music's duration_ms
# before we reject it as a likely wrong match.
DURATION_TOLERANCE = 0.20
SEARCH_CANDIDATES = 5


def _parse_ytdlp_percent(line: str) -> Optional[float]:
    """Extract 0..1 from a yt-dlp progress line like '[download]  45.2% of …'."""
    if "[download]" not in line or "%" not in line:
        return None
    match = re.search(r"(\d+(?:\.\d+)?)\s*%", line)
    if not match:
        return None
    return min(1.0, max(0.0, float(match.group(1)) / 100.0))


def probe_media_duration(path: str) -> Optional[float]:
    """Container duration in seconds via ffprobe, or None on failure."""
    try:
        out = subprocess.run(
            [
                "ffprobe", "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", path,
            ],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout.strip()
        return float(out)
    except Exception:
        return None


def duration_mismatch(expected_ms: Optional[int], actual_sec: Optional[float]) -> bool:
    """True when both durations are known and differ by more than DURATION_TOLERANCE."""
    if expected_ms is None or actual_sec is None or expected_ms <= 0 or actual_sec <= 0:
        return False
    expected = expected_ms / 1000.0
    return abs(actual_sec - expected) / expected > DURATION_TOLERANCE


def _safe_name(track: Track) -> str:
    return re.sub(r"[^\w\-. ]", "_", f"{track.index:03d}_{track.artist}_{track.title}")[:120]


def _search_candidates(
    query: str,
    cancel_event: Optional[Event] = None,
) -> List[Tuple[str, Optional[float], str]]:
    """
    Flat-search YouTube for up to SEARCH_CANDIDATES results.
    Returns list of (video_id, duration_sec_or_None, title).
    """
    check_cancelled(cancel_event)
    cmd = [
        "yt-dlp",
        f"ytsearch{SEARCH_CANDIDATES}:{query}",
        "--flat-playlist",
        "--print", "%(id)s\t%(duration)s\t%(title)s",
        "--no-warnings",
        "--js-runtimes", "deno",
        "--js-runtimes", "node",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        raise RuntimeError('yt-dlp CLI not found on PATH — install "yt-dlp[default]"')
    except subprocess.TimeoutExpired:
        return []

    check_cancelled(cancel_event)
    results: List[Tuple[str, Optional[float], str]] = []
    for line in (proc.stdout or "").splitlines():
        parts = line.split("\t", 2)
        if len(parts) < 1 or not parts[0].strip():
            continue
        vid = parts[0].strip()
        dur: Optional[float] = None
        if len(parts) >= 2 and parts[1].strip() and parts[1].strip().upper() != "NA":
            try:
                dur = float(parts[1].strip())
            except ValueError:
                dur = None
        title = parts[2].strip() if len(parts) >= 3 else ""
        results.append((vid, dur, title))
    return results


def _rank_candidates(
    candidates: List[Tuple[str, Optional[float], str]],
    expected_ms: Optional[int],
) -> List[Tuple[str, Optional[float], str]]:
    """Prefer candidates within duration tolerance; otherwise keep search order."""
    if expected_ms is None or expected_ms <= 0:
        return candidates
    expected = expected_ms / 1000.0
    good = [
        c for c in candidates
        if c[1] is not None and abs(c[1] - expected) / expected <= DURATION_TOLERANCE
    ]
    if good:
        good.sort(key=lambda c: abs((c[1] or 0) - expected))
        rest = [c for c in candidates if c not in good]
        return good + rest
    return candidates


def _download_video_id(
    video_id: str,
    out_template: str,
    cancel_event: Optional[Event] = None,
    on_fraction: Optional[Callable[[float], None]] = None,
) -> Tuple[Optional[str], Optional[str], Optional[str], Optional[str]]:
    """
    Download one YouTube id. Returns (filepath, thumb_url, video_title, last_error).
    """
    last_error: Optional[str] = None
    for client in YT_DLP_CLIENT_FALLBACKS:
        check_cancelled(cancel_event)
        cmd = [
            "yt-dlp", f"https://www.youtube.com/watch?v={video_id}",
            "-f", "bestaudio/best",
            "--extract-audio", "--audio-format", "best", "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
            "--js-runtimes", "deno",
            "--js-runtimes", "node",
            "--extractor-args", f"youtube:player_client={client}",
            "-o", out_template,
            "--print", "video:YTDLP_THUMB::%(thumbnail)s",
            "--print", "video:YTDLP_TITLE::%(title)s",
            "--print", "after_move:YTDLP_PATH::%(filepath)s",
            "--no-warnings",
            "--newline",
        ]
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except FileNotFoundError:
            return None, None, None, 'yt-dlp CLI not found on PATH — install "yt-dlp[default]"'
        except Exception as e:
            last_error = str(e)
            continue

        thumb, filepath, title = None, None, None
        collected: List[str] = []
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                check_cancelled(cancel_event)
                collected.append(line.rstrip("\n"))
                if line.startswith("YTDLP_THUMB::"):
                    val = line[len("YTDLP_THUMB::"):].strip()
                    if val and val.upper() != "NA":
                        thumb = val
                elif line.startswith("YTDLP_TITLE::"):
                    val = line[len("YTDLP_TITLE::"):].strip()
                    if val and val.upper() != "NA":
                        title = val
                elif line.startswith("YTDLP_PATH::"):
                    val = line[len("YTDLP_PATH::"):].strip()
                    if val:
                        filepath = val
                elif on_fraction is not None:
                    pct = _parse_ytdlp_percent(line)
                    if pct is not None:
                        on_fraction(pct)
            try:
                proc.wait(timeout=180)
            except subprocess.TimeoutExpired:
                proc.kill()
                last_error = "yt-dlp timed out"
                continue
        except CancelledError:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            raise
        except Exception as e:
            proc.kill()
            last_error = str(e)
            continue

        if filepath and os.path.exists(filepath):
            if on_fraction is not None:
                on_fraction(1.0)
            return filepath, thumb, title, None

        stderr_lines = [ln for ln in collected if ln.strip() and not ln.startswith("YTDLP_")]
        last_error = stderr_lines[-1] if stderr_lines else "unknown yt-dlp failure"

    return None, None, None, last_error


def download_audio(
    track: Track,
    workdir: str,
    on_fraction: Optional[Callable[[float], None]] = None,
    quiet: bool = False,
    cancel_event: Optional[Event] = None,
) -> Optional[str]:
    """
    Search YouTube for the track, prefer duration-matching candidates when
    Apple Music provided duration_ms, download via yt-dlp CLI. On duration
    mismatch after download, try the next candidate.
    """
    query = f"{track.artist} - {track.title} audio"
    safe = _safe_name(track)
    out_template = os.path.join(workdir, f"{safe}.%(ext)s")

    try:
        candidates = _search_candidates(query, cancel_event=cancel_event)
    except RuntimeError as e:
        if not quiet:
            print(f"  ! download failed for '{track.artist} - {track.title}': {e}")
        return None

    if not candidates:
        # Fall back to classic ytsearch1 download path via a synthetic id search
        candidates = [("__search__", None, "")]

    ranked = _rank_candidates(candidates, track.duration_ms)
    last_error: Optional[str] = None

    for video_id, _cand_dur, cand_title in ranked:
        check_cancelled(cancel_event)
        if video_id == "__search__":
            # Legacy single-shot search download
            filepath, thumb, title, err = _download_search_query(
                query, out_template, cancel_event=cancel_event, on_fraction=on_fraction,
            )
        else:
            # Unique output name per attempt so retries don't collide
            attempt_template = os.path.join(workdir, f"{safe}_{video_id}.%(ext)s")
            filepath, thumb, title, err = _download_video_id(
                video_id, attempt_template, cancel_event=cancel_event, on_fraction=on_fraction,
            )

        if err and not filepath:
            last_error = err
            continue
        if not filepath:
            last_error = err or "unknown yt-dlp failure"
            continue

        actual = probe_media_duration(filepath)
        if duration_mismatch(track.duration_ms, actual):
            expected = (track.duration_ms or 0) / 1000.0
            if not quiet:
                print(
                    f"  ! duration mismatch for '{track.artist} - {track.title}' "
                    f"(expected ~{expected:.0f}s, got {actual:.0f}s"
                    f"{f', hit: {title or cand_title}' if (title or cand_title) else ''})"
                    f" — trying next candidate"
                )
            try:
                os.remove(filepath)
            except OSError:
                pass
            last_error = (
                f"duration mismatch: expected ~{expected:.0f}s, got {actual:.0f}s "
                "— likely wrong YouTube hit"
            )
            continue

        if not track.artwork_url and thumb:
            track.artwork_url = thumb
        track.matched_video_title = title or cand_title or None
        if actual is not None:
            track.duration_sec = actual
        return filepath

    if not quiet:
        hint = ""
        if last_error and any(p in str(last_error).lower() for p in _RETRYABLE_PATTERNS):
            hint = " (all player-client fallbacks failed)"
        print(f"  ! download failed for '{track.artist} - {track.title}': {last_error}{hint}")
    return None


def _download_search_query(
    query: str,
    out_template: str,
    cancel_event: Optional[Event] = None,
    on_fraction: Optional[Callable[[float], None]] = None,
) -> Tuple[Optional[str], Optional[str], Optional[str], Optional[str]]:
    """ytsearch1 fallback when flat search returned nothing."""
    last_error: Optional[str] = None
    for client in YT_DLP_CLIENT_FALLBACKS:
        check_cancelled(cancel_event)
        cmd = [
            "yt-dlp", f"ytsearch1:{query}",
            "-f", "bestaudio/best",
            "--extract-audio", "--audio-format", "best", "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
            "--js-runtimes", "deno",
            "--js-runtimes", "node",
            "--extractor-args", f"youtube:player_client={client}",
            "-o", out_template,
            "--print", "video:YTDLP_THUMB::%(thumbnail)s",
            "--print", "video:YTDLP_TITLE::%(title)s",
            "--print", "after_move:YTDLP_PATH::%(filepath)s",
            "--no-warnings",
            "--newline",
        ]
        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except FileNotFoundError:
            return None, None, None, 'yt-dlp CLI not found on PATH — install "yt-dlp[default]"'
        except Exception as e:
            last_error = str(e)
            continue

        thumb, filepath, title = None, None, None
        collected: List[str] = []
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                check_cancelled(cancel_event)
                collected.append(line.rstrip("\n"))
                if line.startswith("YTDLP_THUMB::"):
                    val = line[len("YTDLP_THUMB::"):].strip()
                    if val and val.upper() != "NA":
                        thumb = val
                elif line.startswith("YTDLP_TITLE::"):
                    val = line[len("YTDLP_TITLE::"):].strip()
                    if val and val.upper() != "NA":
                        title = val
                elif line.startswith("YTDLP_PATH::"):
                    val = line[len("YTDLP_PATH::"):].strip()
                    if val:
                        filepath = val
                elif on_fraction is not None:
                    pct = _parse_ytdlp_percent(line)
                    if pct is not None:
                        on_fraction(pct)
            try:
                proc.wait(timeout=180)
            except subprocess.TimeoutExpired:
                proc.kill()
                last_error = "yt-dlp timed out"
                continue
        except CancelledError:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            raise
        except Exception as e:
            proc.kill()
            last_error = str(e)
            continue

        if filepath and os.path.exists(filepath):
            if on_fraction is not None:
                on_fraction(1.0)
            return filepath, thumb, title, None

        stderr_lines = [ln for ln in collected if ln.strip() and not ln.startswith("YTDLP_")]
        last_error = stderr_lines[-1] if stderr_lines else "unknown yt-dlp failure"

    return None, None, None, last_error


def download_artwork(track: Track, workdir: str, quiet: bool = False) -> Optional[str]:
    if not track.artwork_url:
        return None
    try:
        r = requests.get(track.artwork_url, timeout=20)
        r.raise_for_status()
        path = os.path.join(workdir, f"art_{track.index:03d}.jpg")
        with open(path, "wb") as f:
            f.write(r.content)
        return path
    except Exception as e:
        if not quiet:
            print(f"  ! artwork download failed: {e}")
        return None


def download_track_media(
    track: Track,
    workdir: str,
    on_fraction: Optional[Callable[[float], None]] = None,
    quiet: bool = False,
    cancel_event: Optional[Event] = None,
) -> Track:
    """Fetch artwork + audio for one track (thread-pool friendly).

    Artwork is retried after the audio download because download_audio can
    backfill track.artwork_url from the video thumbnail when Apple Music
    didn't provide artwork.
    """
    check_cancelled(cancel_event)
    track.artwork_path = download_artwork(track, workdir, quiet=quiet)
    track.audio_path = download_audio(
        track, workdir, on_fraction=on_fraction, quiet=quiet, cancel_event=cancel_event,
    )
    if not track.artwork_path:
        track.artwork_path = download_artwork(track, workdir, quiet=quiet)
    return track
