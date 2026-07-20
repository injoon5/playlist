"""Per-track render worker, lossless concat, and description-file output."""

import os
import subprocess
from typing import List, Optional

from .encoding import EncodeSettings, software_fallback_for, write_videofile
from .frames import build_track_clip
from .models import Track
from .progress import make_queue_progress_logger, make_quiet_logger, make_worker_bar_logger
from .transitions import apply_single_clip_transition


def _pick_logger(quiet: bool, progress_queue, position: int, desc: str, track_index: int):
    if quiet and progress_queue is not None:
        return make_queue_progress_logger(progress_queue, position, desc, track_index)
    if quiet:
        return make_quiet_logger()
    return make_worker_bar_logger(position, desc)


def render_track_to_file(
    track: Track,
    track_bg: Optional[str],
    resolution,
    fps: int,
    font_dir: Optional[str],
    transition_duration: float,
    encode: EncodeSettings,
    out_path: str,
    position_pool,
    ffmpeg_threads: int = 2,
    progress_queue=None,
    quiet: bool = False,
) -> Track:
    """
    Renders one track's clip (frames + transition + audio) straight to its
    own finished mp4. Meant to run inside a ProcessPoolExecutor worker.
    """
    desc = f"{track.artist} - {track.title}"[:60]
    position = position_pool.get()
    try:
        logger = _pick_logger(quiet, progress_queue, position, desc, track.index)
        if quiet and progress_queue is not None:
            try:
                progress_queue.put({
                    "type": "progress",
                    "slot_id": position,
                    "track_index": track.index,
                    "track_label": desc,
                    "current": 0,
                    "total": 1,
                })
            except Exception:
                pass

        clip = build_track_clip(track, resolution, fps, track_bg, font_dir)
        if transition_duration > 0:
            clip = apply_single_clip_transition(clip, transition_duration)

        try:
            write_videofile(
                clip, out_path, encode, fps=fps, ffmpeg_threads=ffmpeg_threads, logger=logger,
            )
        except Exception as e:
            if encode.codec.startswith("libx"):
                raise
            fallback = software_fallback_for(encode, fps=fps)
            if not quiet:
                print(
                    f"  ! GPU encode failed for '{track.artist} - {track.title}' ({e}); "
                    f"retrying with {fallback.codec}..."
                )
            retry_logger = _pick_logger(quiet, progress_queue, position, desc, track.index)
            write_videofile(
                clip, out_path, fallback, fps=fps, ffmpeg_threads=ffmpeg_threads, logger=retry_logger,
            )
    finally:
        if progress_queue is not None:
            try:
                progress_queue.put({
                    "type": "clear",
                    "slot_id": position,
                    "track_index": track.index,
                })
            except Exception:
                pass
        position_pool.put(position)
    return track


def concat_clips(clip_paths: List[str], output_path: str, workdir: str) -> None:
    """
    Losslessly stitches already-encoded per-track clips with ffmpeg's concat
    demuxer (stream copy — no re-encode, no quality loss, effectively
    instant). Safe specifically because every clip was produced by
    render_track_to_file with identical codec, resolution, fps, pixel format,
    and audio sample rate/channels, which is exactly what -c copy
    concatenation requires to avoid glitches.
    """
    list_path = os.path.join(workdir, "concat_list.txt")
    with open(list_path, "w", encoding="utf-8") as f:
        for p in clip_paths:
            escaped = os.path.abspath(p).replace("'", "'\\''")
            f.write(f"file '{escaped}'\n")
    subprocess.run(
        ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", list_path,
         "-c", "copy", "-movflags", "+faststart", output_path],
        check=True,
    )


def _probe_duration_sec(path: str) -> float:
    """Container duration of a rendered clip via ffprobe. Used for the
    description's timestamps instead of the source audio durations, so the
    times match the concatenated output exactly (encoder frame/audio-priming
    rounding included)."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(out)


def format_timestamp(seconds: float) -> str:
    """m:ss, switching to h:mm:ss past the one-hour mark."""
    s = int(seconds)
    if s >= 3600:
        return f"{s // 3600}:{(s % 3600) // 60:02d}:{s % 60:02d}"
    return f"{s // 60}:{s % 60:02d}"


def write_description(entries, output_video_path: str) -> str:
    """
    Writes a ready-to-paste tracklist for the video description, one line per
    track in final-video order: 'song title - artist m:ss', where the time is
    the track's start position in the concatenated video. `entries` is the
    ordered list of (track, clip_path) pairs that actually made it into the
    final video (failed/skipped tracks never appear, and their absence shifts
    the later timestamps correctly since times come from the real clips).

    Note: YouTube's automatic chapter detection requires the timestamp at the
    START of each line and the first one to be 0:00 — if you want clickable
    chapters rather than a plain tracklist, swap each line to
    '{timestamp} {title} - {artist}' before pasting.
    """
    lines = []
    t = 0.0
    for track, clip_path in entries:
        lines.append(f"{track.title} - {track.artist} {format_timestamp(t)}")
        t += _probe_duration_sec(clip_path)
    desc_path = os.path.splitext(output_video_path)[0] + "_description.txt"
    with open(desc_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return desc_path
