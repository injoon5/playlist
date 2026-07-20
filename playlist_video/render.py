"""Per-track render worker, lossless concat, and description-file output."""

import os
import subprocess
from threading import Event
from typing import List, Optional

from .encoding import (
    EncodeSettings,
    encode_frames_to_file,
    software_fallback_for,
)
from .frames import build_track_renderer
from .models import CancelledError, Track, check_cancelled
from .transitions import iter_faded_frames


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
    cancel_event: Optional[Event] = None,
) -> Track:
    """
    Renders one track's clip (frames + transition + audio) straight to its
    own finished mp4. Meant to run inside a ProcessPoolExecutor / thread worker.
    """
    check_cancelled(cancel_event)
    desc = f"{track.artist} - {track.title}"[:60]
    position = position_pool.get()
    try:
        if progress_queue is not None:
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

        make_frame, duration = build_track_renderer(track, resolution, track_bg, font_dir)
        total_frames = max(1, int(round(duration * fps)))

        def on_frame(current: int, total: int) -> None:
            check_cancelled(cancel_event)
            if progress_queue is None:
                return
            try:
                progress_queue.put({
                    "type": "progress",
                    "slot_id": position,
                    "track_index": track.index,
                    "track_label": desc,
                    "current": current,
                    "total": total,
                })
            except Exception:
                pass

        def frame_iter():
            for frame, _t, _i in iter_faded_frames(
                make_frame, duration, fps, transition_duration,
            ):
                yield frame

        try:
            encode_frames_to_file(
                frame_iter(),
                out_path,
                encode,
                resolution=resolution,
                fps=fps,
                audio_path=track.audio_path,
                ffmpeg_threads=ffmpeg_threads,
                total_frames=total_frames,
                on_frame=on_frame,
                cancel_event=cancel_event,
            )
        except CancelledError:
            raise
        except Exception as e:
            if encode.codec.startswith("libx"):
                raise
            fallback = software_fallback_for(encode, fps=fps)
            if not quiet:
                print(
                    f"  ! GPU encode failed for '{track.artist} - {track.title}' ({e}); "
                    f"retrying with {fallback.codec}..."
                )
            check_cancelled(cancel_event)
            # Rebuild iterator — previous consumption exhausted it.
            encode_frames_to_file(
                frame_iter(),
                out_path,
                fallback,
                resolution=resolution,
                fps=fps,
                audio_path=track.audio_path,
                ffmpeg_threads=ffmpeg_threads,
                total_frames=total_frames,
                on_frame=on_frame,
                cancel_event=cancel_event,
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
    demuxer (stream copy — no re-encode).
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
    Writes a ready-to-paste YouTube chapter list, one line per track in
    final-video order: '{timestamp} {title} - {artist}'. The first line is
    always 0:00 so YouTube auto-detects chapters. `entries` is the ordered
    list of (track, clip_path) pairs that made it into the final video
    (failed/skipped tracks are omitted; later timestamps stay correct because
    times come from the real rendered clips).
    """
    lines = []
    t = 0.0
    for track, clip_path in entries:
        lines.append(f"{format_timestamp(t)} {track.title} - {track.artist}")
        t += _probe_duration_sec(clip_path)
    desc_path = os.path.splitext(output_video_path)[0] + "_description.txt"
    with open(desc_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return desc_path
