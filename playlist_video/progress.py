"""Render-pool plumbing and progress reporting."""

import queue as thread_queue
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from multiprocessing import Manager
from typing import Optional

from .models import ProgressCallback, ProgressEvent, emit_progress


def open_render_pool(render_workers: int, quiet: bool):
    """
    Prefer ProcessPool + Manager queues. Fall back to threads when spawn fails
    (common under Textual on macOS: ValueError "bad value(s) in fds_to_keep").
    Returns (pool, position_pool, progress_queue, cleanup).
    """
    def _thread_pool():
        position_pool = thread_queue.Queue()
        progress_queue = thread_queue.Queue() if quiet else None
        for slot in range(render_workers):
            position_pool.put(slot)
        pool = ThreadPoolExecutor(max_workers=render_workers)

        def cleanup() -> None:
            pool.shutdown(wait=True, cancel_futures=True)

        return pool, position_pool, progress_queue, cleanup

    # Quiet/TUI path: Textual holds non-inheritable FDs that break process spawn.
    if quiet:
        return _thread_pool()

    manager = None
    try:
        manager = Manager()
        position_pool = manager.Queue()
        for slot in range(render_workers):
            position_pool.put(slot)
        pool = ProcessPoolExecutor(max_workers=render_workers)

        def cleanup() -> None:
            pool.shutdown(wait=True, cancel_futures=True)
            manager.shutdown()

        return pool, position_pool, None, cleanup
    except (ValueError, OSError, PermissionError) as e:
        if manager is not None:
            try:
                manager.shutdown()
            except Exception:
                pass
        print(f"  ! Process pool unavailable ({e}); falling back to threads")
        return _thread_pool()


def drain_render_queue(progress_queue, on_progress: Optional[ProgressCallback],
                       completed: int, total: int) -> None:
    if progress_queue is None or on_progress is None:
        return
    while True:
        try:
            item = progress_queue.get_nowait()
        except Exception:
            break
        if not isinstance(item, dict):
            continue
        if item.get("type") == "progress":
            cur = float(item.get("current") or 0)
            tot = float(item.get("total") or 1)
            emit_progress(on_progress, ProgressEvent(
                phase="render",
                completed=completed,
                total=total,
                message=item.get("track_label") or "",
                track_index=item.get("track_index"),
                track_label=item.get("track_label"),
                track_status="rendering",
                slot_id=item.get("slot_id"),
                fraction=min(1.0, cur / tot) if tot else 0.0,
            ))
        elif item.get("type") == "clear":
            emit_progress(on_progress, ProgressEvent(
                phase="render",
                completed=completed,
                total=total,
                message="",
                track_index=item.get("track_index"),
                track_label=None,
                track_status=None,
                slot_id=item.get("slot_id"),
                fraction=None,
            ))
