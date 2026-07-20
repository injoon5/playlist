"""Render-pool plumbing and progress reporting: proglog loggers for terminal
and TUI modes, plus the queue that ferries per-frame progress out of workers."""

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
            pool.shutdown(wait=True)

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
            pool.shutdown(wait=True)
            manager.shutdown()

        # progress_queue is only needed in quiet mode (the terminal path
        # renders tqdm bars in the workers themselves), and quiet mode never
        # reaches here — so no Manager queue for progress.
        return pool, position_pool, None, cleanup
    except (ValueError, OSError, PermissionError) as e:
        if manager is not None:
            try:
                manager.shutdown()
            except Exception:
                pass
        print(f"  ! Process pool unavailable ({e}); falling back to threads")
        return _thread_pool()


def make_worker_bar_logger(position: int, desc: str):
    """
    A proglog logger (what moviepy's write_videofile wants) that renders its
    per-frame bar with tqdm pinned to a fixed terminal line (`position`)
    instead of proglog's default, which assumes it owns the whole terminal —
    with several render-worker processes drawing bars at once, that would
    otherwise garble into flicker.
    """
    import proglog

    class _WorkerBarLogger(proglog.TqdmProgressBarLogger):
        def new_tqdm_bar(self, bar):
            if (bar in self.tqdm_bars) and (self.tqdm_bars[bar] is not None):
                self.close_tqdm_bar(bar)
            self.tqdm_bars[bar] = self.tqdm(
                total=self.bars[bar]["total"], desc=desc, position=position, leave=False,
            )

    return _WorkerBarLogger(print_messages=False)


def make_quiet_logger():
    import proglog
    return proglog.ProgressBarLogger(bars=None, ignored_bars=frozenset({"t"}))


def make_queue_progress_logger(progress_queue, slot_id: int, desc: str, track_index: int):
    """Proglog logger that pushes throttled frame progress onto a queue."""
    import time
    import proglog

    class _QueueProgressLogger(proglog.ProgressBarLogger):
        def __init__(self):
            super().__init__(bars=None, ignored_bars=frozenset())
            self._last_push = 0.0
            self._min_interval = 0.05  # ~20 Hz

        def bars_callback(self, bar, attr, value, old_value=None):
            if bar != "t" or attr != "index":
                return
            now = time.monotonic()
            total = self.bars.get("t", {}).get("total") or 0
            if total <= 0:
                return
            if now - self._last_push < self._min_interval and value + 1 < total:
                return
            self._last_push = now
            try:
                progress_queue.put({
                    "type": "progress",
                    "slot_id": slot_id,
                    "track_index": track_index,
                    "track_label": desc,
                    "current": value + 1,
                    "total": total,
                })
            except Exception:
                pass

    return _QueueProgressLogger()


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
