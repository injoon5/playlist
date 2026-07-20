"""Per-track media acquisition: audio via the yt-dlp CLI, artwork via HTTP."""

import os
import re
import subprocess
from typing import Callable, List, Optional

import requests

from .models import Track

# YouTube's bot-check ("Sign in to confirm you're not a bot") hits datacenter
# IPs — Colab included — far more than home connections. The android/ios
# clients use a different auth flow than the default web client and often
# aren't flagged even when web is; tv_embedded is a third fallback. Order
# matters: cheapest/most-likely-to-work first.
YT_DLP_CLIENT_FALLBACKS = ["android", "ios", "tv_embedded", "web"]

# Error substrings worth retrying with a different player_client: both the
# bot-check AND "requested format is not available" are client-specific —
# each client exposes a different, sometimes broken/restricted format list
# for a given video, not just a different auth flow.
_RETRYABLE_PATTERNS = ["sign in to confirm", "not a bot", "requested format is not available"]


def _parse_ytdlp_percent(line: str) -> Optional[float]:
    """Extract 0..1 from a yt-dlp progress line like '[download]  45.2% of …'."""
    if "[download]" not in line or "%" not in line:
        return None
    match = re.search(r"(\d+(?:\.\d+)?)\s*%", line)
    if not match:
        return None
    return min(1.0, max(0.0, float(match.group(1)) / 100.0))


def download_audio(
    track: Track,
    workdir: str,
    cookies_file: Optional[str] = None,
    on_fraction: Optional[Callable[[float], None]] = None,
    quiet: bool = False,
) -> Optional[str]:
    """
    Shells out to the yt-dlp CLI rather than using the Python API. The CLI is
    yt-dlp's primary, far more battle-tested interface — new features (like
    the js_runtimes/EJS challenge-solving machinery YouTube now requires) tend
    to land there first and get exercised far more than the Python API's
    equivalent option shapes, which is where an unexplained internal
    'NoneType' object has no attribute 'get' kept surfacing.
    """
    query = f"ytsearch1:{track.artist} - {track.title} audio"
    safe_name = re.sub(r"[^\w\-. ]", "_", f"{track.index:03d}_{track.artist}_{track.title}")[:120]
    out_template = os.path.join(workdir, f"{safe_name}.%(ext)s")

    last_error: Optional[str] = None
    for client in YT_DLP_CLIENT_FALLBACKS:
        cmd = [
            "yt-dlp", query,
            "-f", "bestaudio/best",
            "--extract-audio", "--audio-format", "best", "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
            "--js-runtimes", "deno",
            "--js-runtimes", "node",
            "--extractor-args", f"youtube:player_client={client}",
            "-o", out_template,
            "--print", "video:YTDLP_THUMB::%(thumbnail)s",
            "--print", "after_move:YTDLP_PATH::%(filepath)s",
            "--no-warnings",
            "--newline",
        ]
        if cookies_file:
            cmd += ["--cookies", cookies_file]

        try:
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
        except FileNotFoundError:
            last_error = "yt-dlp CLI not found on PATH — pip install \"yt-dlp[default]\""
            break
        except Exception as e:
            last_error = str(e)
            continue

        thumb, filepath = None, None
        collected: List[str] = []
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                collected.append(line.rstrip("\n"))
                if line.startswith("YTDLP_THUMB::"):
                    val = line[len("YTDLP_THUMB::"):].strip()
                    if val and val.upper() != "NA":
                        thumb = val
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
        except Exception as e:
            proc.kill()
            last_error = str(e)
            continue

        if filepath and os.path.exists(filepath):
            if not track.artwork_url and thumb:
                track.artwork_url = thumb
            if on_fraction is not None:
                on_fraction(1.0)
            return filepath

        stderr_lines = [ln for ln in collected if ln.strip() and not ln.startswith("YTDLP_")]
        last_error = stderr_lines[-1] if stderr_lines else "unknown yt-dlp failure"
        continue

    if not quiet:
        hint = ""
        if last_error and any(p in str(last_error).lower() for p in _RETRYABLE_PATTERNS):
            hint = " (all player-client fallbacks failed — pass --cookies-file with an exported cookies.txt)"
        print(f"  ! download failed for '{track.artist} - {track.title}': {last_error}{hint}")
    return None


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
    cookies_file: Optional[str] = None,
    on_fraction: Optional[Callable[[float], None]] = None,
    quiet: bool = False,
) -> Track:
    """Fetch artwork + audio for one track (thread-pool friendly).

    Artwork is retried after the audio download because download_audio can
    backfill track.artwork_url from the video thumbnail when Apple Music
    didn't provide artwork.
    """
    track.artwork_path = download_artwork(track, workdir, quiet=quiet)
    track.audio_path = download_audio(
        track, workdir, cookies_file=cookies_file, on_fraction=on_fraction, quiet=quiet,
    )
    if not track.artwork_path:
        track.artwork_path = download_artwork(track, workdir, quiet=quiet)
    return track
