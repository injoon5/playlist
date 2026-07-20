"""Pipeline orchestration: fetch → download → render → concat → describe."""

import os
import random
import tempfile
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, as_completed, wait
from typing import List, Optional, Tuple

from .backgrounds import assign_track_backgrounds, resolve_background_images
from .downloader import download_track_media
from .encoding import kill_active_encodes, resolve_encode_settings
from .fonts import try_download_pretendard
from .models import (
    CancelledError,
    PipelineConfig,
    PipelineResult,
    ProgressCallback,
    ProgressEvent,
    Track,
    check_cancelled,
    emit_progress,
    track_label,
)
from .progress import drain_render_queue, open_render_pool
from .render import concat_clips, render_track_to_file, write_description
from .scraper import fetch_playlist_tracks, get_manual_tracks


def parse_resolution(s: str) -> Tuple[int, int]:
    w, h = s.lower().split("x")
    return (int(w), int(h))


def _fetch_tracks(config: PipelineConfig, on_progress: Optional[ProgressCallback]) -> List[Track]:
    quiet = config.quiet
    check_cancelled(config.cancel_event)
    emit_progress(on_progress, ProgressEvent(
        phase="fetch", completed=0, total=1, message="Fetching track list…",
    ))
    if config.tracks is not None:
        tracks = list(config.tracks)
    elif config.tracks_json:
        tracks = get_manual_tracks(config.tracks_json)
    else:
        if not config.playlist_url:
            raise ValueError("Provide playlist_url, tracks_json, or tracks")
        if not quiet:
            print("Fetching track list...")
        tracks = fetch_playlist_tracks(config.playlist_url, config.force_browser_scrape)
    if not quiet:
        print(f"  found {len(tracks)} tracks")
    emit_progress(on_progress, ProgressEvent(
        phase="fetch", completed=1, total=1,
        message=f"Found {len(tracks)} tracks",
    ))

    if config.shuffle:
        random.shuffle(tracks)

    if config.limit is not None:
        tracks = tracks[: config.limit]

    for i, t in enumerate(tracks):
        t.index, t.total = i + 1, len(tracks)
    return tracks


def _download_phase(
    tracks: List[Track],
    workdir: str,
    config: PipelineConfig,
    on_progress: Optional[ProgressCallback],
) -> None:
    """Fetch audio + artwork for every track in parallel, emitting per-slot
    progress. Mutates each track's audio_path/artwork_path in place."""
    quiet = config.quiet
    cancel_event = config.cancel_event
    for t in tracks:
        emit_progress(on_progress, ProgressEvent(
            phase="download", completed=0, total=len(tracks),
            message="pending",
            track_index=t.index,
            track_label=track_label(t),
            track_status="pending",
        ))

    if not quiet:
        print(f"Downloading audio + artwork for {len(tracks)} tracks ({config.workers} at a time)...")
    download_workers = max(1, config.workers)
    import threading
    slot_pool: List[int] = list(range(download_workers))
    slot_lock = threading.Lock()
    done_count = 0
    done_lock = threading.Lock()

    def _completed() -> int:
        with done_lock:
            return done_count

    def _download_one(track: Track) -> Track:
        check_cancelled(cancel_event)
        with slot_lock:
            slot_id = slot_pool.pop(0) if slot_pool else 0
        label = track_label(track)

        def on_fraction(frac: float) -> None:
            emit_progress(on_progress, ProgressEvent(
                phase="download",
                completed=_completed(),
                total=len(tracks),
                message=f"Downloading {label}",
                track_index=track.index,
                track_label=label,
                track_status="downloading",
                slot_id=slot_id,
                fraction=frac,
            ))

        on_fraction(0.0)
        try:
            download_track_media(
                track, workdir, on_fraction=on_fraction, quiet=quiet, cancel_event=cancel_event,
            )
        finally:
            emit_progress(on_progress, ProgressEvent(
                phase="download",
                completed=_completed(),
                total=len(tracks),
                message="",
                track_index=track.index,
                track_label=label,
                track_status=None,
                slot_id=slot_id,
                fraction=None,
            ))
            with slot_lock:
                slot_pool.append(slot_id)
        return track

    pool = ThreadPoolExecutor(max_workers=download_workers)
    try:
        futures = {pool.submit(_download_one, t): t for t in tracks}
        for future in as_completed(futures):
            if cancel_event.is_set():
                break
            track = futures[future]
            with done_lock:
                done_count += 1
                completed = done_count
            try:
                future.result()
                status = "ok" if track.audio_path else "skipped"
                extra = ""
                if track.audio_path and track.matched_video_title and not quiet:
                    extra = f" (yt: {track.matched_video_title[:60]})"
            except CancelledError:
                status = "cancelled"
                extra = ""
            except Exception as e:
                status = "failed"
                extra = ""
                if not quiet:
                    print(f"  [{completed}/{len(tracks)}] {track_label(track)}: failed ({e})")
            else:
                if not quiet:
                    print(
                        f"  [{completed}/{len(tracks)}] {track_label(track)}: "
                        f"{'ok' if track.audio_path else 'no audio found'}{extra}"
                    )
            emit_progress(on_progress, ProgressEvent(
                phase="download",
                completed=completed,
                total=len(tracks),
                message=f"{track_label(track)}: {status}",
                track_index=track.index,
                track_label=track_label(track),
                track_status=status,
                fraction=1.0 if status == "ok" else None,
            ))
    finally:
        if cancel_event.is_set():
            pool.shutdown(wait=False, cancel_futures=True)
        else:
            pool.shutdown(wait=True, cancel_futures=True)

    check_cancelled(cancel_event)


def _render_phase(
    renderable: List[Tuple[Track, Optional[str]]],
    workdir: str,
    font_dir: Optional[str],
    resolution,
    encode,
    config: PipelineConfig,
    on_progress: Optional[ProgressCallback],
) -> List[Optional[str]]:
    """Render every downloadable track to its own clip file in parallel."""
    quiet = config.quiet
    cancel_event = config.cancel_event
    cpu_count = os.cpu_count() or 4
    render_workers = config.render_workers or min(len(renderable), cpu_count)
    render_workers = max(1, render_workers)
    ffmpeg_threads = max(1, cpu_count // render_workers)
    if not quiet:
        print(
            f"Rendering {len(renderable)} clips ({render_workers} in parallel, "
            f"{ffmpeg_threads} ffmpeg thread(s) each)..."
        )

    clip_paths: List[Optional[str]] = [None] * len(renderable)
    overall_bar = None
    if not quiet:
        from tqdm import tqdm
        overall_bar = tqdm(total=len(renderable), desc="Overall", position=render_workers, leave=True)

    rendered_done = 0
    pool, position_pool, progress_queue, cleanup_pool = open_render_pool(render_workers, quiet)
    try:
        futures = {}
        for i, (track, track_bg) in enumerate(renderable):
            check_cancelled(cancel_event)
            out_path = os.path.join(workdir, f"clip_{track.index:03d}.mp4")
            fut = pool.submit(
                render_track_to_file, track, track_bg, resolution, config.fps,
                font_dir, config.transition_duration, encode, out_path, position_pool,
                ffmpeg_threads, progress_queue, quiet,
                # threading.Event is not picklable across ProcessPool workers;
                # TUI uses quiet=True → ThreadPool, where cancel works.
                cancel_event if quiet else None,
            )
            futures[fut] = (i, track, out_path)
            emit_progress(on_progress, ProgressEvent(
                phase="render", completed=0, total=len(renderable),
                message=f"Queued {track_label(track)}",
                track_index=track.index, track_label=track_label(track),
                track_status="pending",
            ))

        pending = set(futures.keys())
        while pending:
            if cancel_event.is_set():
                kill_active_encodes()
                for fut in pending:
                    fut.cancel()
                break
            drain_render_queue(progress_queue, on_progress, rendered_done, len(renderable))
            done_now, pending = wait(pending, timeout=0.1, return_when=FIRST_COMPLETED)
            for fut in done_now:
                i, track, out_path = futures[fut]
                try:
                    fut.result()
                    clip_paths[i] = out_path
                    status = "ok"
                    msg = f"Rendered {track_label(track)}"
                    if overall_bar is not None:
                        from tqdm import tqdm as _tqdm
                        _tqdm.write(
                            f"  [{rendered_done + 1}/{len(renderable)}] {track_label(track)}: rendered"
                        )
                except CancelledError:
                    status = "cancelled"
                    msg = f"Cancelled {track_label(track)}"
                except Exception as e:
                    status = "failed"
                    msg = f"Failed {track_label(track)}: {e}"
                    if overall_bar is not None:
                        from tqdm import tqdm as _tqdm
                        _tqdm.write(
                            f"  [{rendered_done + 1}/{len(renderable)}] ! failed {track_label(track)}: {e}"
                        )
                rendered_done += 1
                if overall_bar is not None:
                    overall_bar.update(1)
                emit_progress(on_progress, ProgressEvent(
                    phase="render",
                    completed=rendered_done,
                    total=len(renderable),
                    message=msg,
                    track_index=track.index,
                    track_label=track_label(track),
                    track_status=status,
                    fraction=1.0 if status == "ok" else None,
                ))
        drain_render_queue(progress_queue, on_progress, rendered_done, len(renderable))
    finally:
        if cancel_event.is_set():
            kill_active_encodes()
        cleanup_pool()

    if overall_bar is not None:
        overall_bar.close()
    check_cancelled(cancel_event)
    return clip_paths


def run_pipeline(
    config: PipelineConfig,
    on_progress: Optional[ProgressCallback] = None,
) -> PipelineResult:
    """Full playlist → video pipeline with optional progress callbacks."""
    quiet = config.quiet
    try:
        resolution = parse_resolution(config.resolution)
        workdir = config.workdir or tempfile.mkdtemp(prefix="amp_video_")
        os.makedirs(workdir, exist_ok=True)
        out_dir = os.path.dirname(os.path.abspath(config.output))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)

        background_images = resolve_background_images(config.background_images, workdir, quiet=quiet)

        font_dir = config.font_dir
        if font_dir is None:
            font_dir = try_download_pretendard(os.path.join(workdir, "fonts"))

        tracks = _fetch_tracks(config, on_progress)

        if len(background_images) > len(tracks):
            raise ValueError(
                f"{len(background_images)} background images but only {len(tracks)} track(s)"
            )

        track_backgrounds = assign_track_backgrounds(tracks, background_images)

        _download_phase(tracks, workdir, config, on_progress)

        encode = resolve_encode_settings(
            config.gpu, config.preset, config.crf, resolution, config.fps, quiet=quiet,
        )

        renderable = [
            (track, track_bg) for track, track_bg in zip(tracks, track_backgrounds) if track.audio_path
        ]
        for track in tracks:
            if not track.audio_path:
                if not quiet:
                    print(f"  [{track.index}/{track.total}] {track_label(track)}: skipping (no audio)")
                emit_progress(on_progress, ProgressEvent(
                    phase="render", completed=0, total=max(len(renderable), 1),
                    message=f"Skipping {track_label(track)}",
                    track_index=track.index, track_label=track_label(track),
                    track_status="skipped",
                ))
        if not renderable:
            raise RuntimeError("No tracks with audio. Aborting.")

        clip_paths = _render_phase(
            renderable, workdir, font_dir, resolution, encode, config, on_progress,
        )

        finished_paths = [p for p in clip_paths if p]
        if not finished_paths:
            raise RuntimeError("No clips were rendered successfully. Aborting.")

        check_cancelled(config.cancel_event)
        emit_progress(on_progress, ProgressEvent(
            phase="concat", completed=0, total=1,
            message=f"Stitching {len(finished_paths)} clips…",
        ))
        if not quiet:
            print(f"Stitching {len(finished_paths)} rendered clip(s) into {config.output} ...")
        concat_clips(finished_paths, config.output, workdir)

        entries = [(renderable[i][0], p) for i, p in enumerate(clip_paths) if p]
        desc_path = write_description(entries, config.output)
        with open(desc_path, "r", encoding="utf-8") as f:
            description_text = f.read()

        emit_progress(on_progress, ProgressEvent(
            phase="done", completed=1, total=1,
            message=f"Done: {config.output}",
        ))
        if not quiet:
            print(f"\nDescription ({desc_path}):")
            print(description_text.rstrip())
            print("\nDone:", config.output)

        return PipelineResult(
            output_path=config.output,
            description_path=desc_path,
            tracks=tracks,
            description_text=description_text,
        )
    except CancelledError:
        kill_active_encodes()
        emit_progress(on_progress, ProgressEvent(
            phase="cancelled", completed=0, total=1, message="Cancelled",
        ))
        raise
