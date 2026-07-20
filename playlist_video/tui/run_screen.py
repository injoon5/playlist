"""Run screen: live overall + per-slot progress while the pipeline runs."""

import subprocess
import sys
from pathlib import Path
from typing import List

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Button, DataTable, Footer, Header, Label, ProgressBar, RichLog
from textual.worker import get_current_worker

from ..models import PipelineConfig, ProgressEvent, Track
from ..pipeline import run_pipeline
from .messages import PipelineFinished, PipelineProgress
from .widgets import TrackProgressRow

# Overall bar phase weights: download 0–45%, render 45–95%, concat 95–100%
_PHASE_WEIGHTS = {
    "fetch": (0.0, 0.0),
    "download": (0.0, 0.45),
    "render": (0.45, 0.50),
    "concat": (0.95, 0.05),
    "done": (1.0, 0.0),
}


class RunScreen(Screen):
    """Live overall + per-slot progress while the pipeline runs."""

    BINDINGS = [
        Binding("c", "cancel", "Cancel", show=True),
        Binding("q", "app.quit", "Quit", show=True),
        Binding("escape", "back", "Back", show=True),
    ]

    def __init__(self, config: PipelineConfig, tracks: List[Track], n_slots: int) -> None:
        super().__init__()
        self.config = config
        self.tracks = tracks
        self.n_slots = max(1, min(n_slots, 12))
        self._row_keys: dict[int, object] = {}
        self._finished = False
        self._slot_frac: dict[int, float] = {}
        self._overall_phase = ""

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical(id="run-body"):
            yield Label("Starting…", id="phase-label")
            yield ProgressBar(id="overall-bar", show_eta=True)
            with Horizontal(id="run-mid"):
                with Vertical(id="active-pane"):
                    yield Label("Active", classes="section-title")
                    with Vertical(id="slots"):
                        for i in range(self.n_slots):
                            yield TrackProgressRow(i, id=f"slot-row-{i}")
                with Vertical(id="tracks-pane"):
                    yield Label("Tracks", classes="section-title")
                    yield DataTable(id="track-table", zebra_stripes=True)
            yield Label("Log", classes="section-title")
            yield RichLog(id="run-log", highlight=True, markup=True)
            with Horizontal(id="done-actions"):
                yield Button("Open folder", id="btn-open", disabled=True)
                yield Button("New run", id="btn-new", disabled=True)
                yield Button("Quit", id="btn-quit")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#track-table", DataTable)
        # Explicit keys — add_columns(label) alone auto-keys, so update_cell(..., "Status") fails
        table.add_column("#", key="#", width=3)
        table.add_column("Title", key="Title")
        table.add_column("Artist", key="Artist")
        table.add_column("Status", key="Status", width=12)
        for track in self.tracks:
            row_key = str(track.index)
            table.add_row(
                str(track.index), track.title, track.artist, "pending", key=row_key
            )
            self._row_keys[track.index] = row_key
        self.run_job(self.config)

    @work(thread=True, exclusive=True, group="pipeline")
    def run_job(self, config: PipelineConfig) -> None:
        worker = get_current_worker()

        def on_progress(ev: ProgressEvent) -> None:
            if worker.is_cancelled:
                return
            self.post_message(PipelineProgress(ev))

        try:
            result = run_pipeline(config, on_progress=on_progress)
            if not worker.is_cancelled:
                self.post_message(PipelineFinished(result))
        except Exception as e:
            if not worker.is_cancelled:
                self.post_message(PipelineFinished(None, error=str(e)))

    def _sync_overall(self, ev: ProgressEvent) -> None:
        """Overall bar = phase weight + in-progress slot fractions (not just whole tracks)."""
        if ev.phase != self._overall_phase:
            self._slot_frac.clear()
            self._overall_phase = ev.phase

        if ev.slot_id is not None:
            if (
                ev.fraction is not None
                and ev.track_status in {"downloading", "rendering"}
            ):
                self._slot_frac[ev.slot_id] = max(0.0, min(1.0, float(ev.fraction)))
            else:
                self._slot_frac.pop(ev.slot_id, None)

        base, span = _PHASE_WEIGHTS.get(ev.phase, (0.0, 0.0))

        if ev.phase in {"download", "render"} and ev.total > 0:
            partial = sum(self._slot_frac.values())
            phase_pct = min(1.0, (ev.completed + partial) / ev.total)
        elif ev.phase == "concat":
            phase_pct = 1.0 if ev.completed else 0.0
        elif ev.phase == "done":
            phase_pct = 1.0
        else:
            phase_pct = 0.0

        overall = 1.0 if ev.phase == "done" else base + span * phase_pct
        self.query_one("#overall-bar", ProgressBar).update(
            total=100, progress=round(overall * 100, 1)
        )

    def on_pipeline_progress(self, message: PipelineProgress) -> None:
        ev = message.event
        # Keep header stable — per-track chatter goes to Active slots / table / log
        phase_text = f"Phase: {ev.phase}  ({ev.completed}/{ev.total})"
        if ev.slot_id is None and ev.phase in {"fetch", "concat"} and ev.message:
            phase_text = f"{phase_text}  {ev.message}"
        self.query_one("#phase-label", Label).update(phase_text)
        self._sync_overall(ev)

        if ev.slot_id is not None and 0 <= ev.slot_id < self.n_slots:
            row = self.query_one(f"#slot-row-{ev.slot_id}", TrackProgressRow)
            if ev.fraction is None and ev.track_status not in {"downloading", "rendering"}:
                row.clear_slot()
            else:
                row.set_progress(
                    ev.track_label or "",
                    ev.fraction if ev.fraction is not None else 0.0,
                )

        if ev.track_index is not None and ev.track_status and ev.track_index in self._row_keys:
            table = self.query_one("#track-table", DataTable)
            table.update_cell(
                self._row_keys[ev.track_index],
                "Status",
                ev.track_status,
            )

        if ev.track_status in {"ok", "failed", "skipped"} or (
            ev.fraction is None and ev.phase in {"fetch", "concat", "done"}
        ):
            self.query_one("#run-log", RichLog).write(f"[dim]{ev.phase}[/] {ev.message}")

    def on_pipeline_finished(self, message: PipelineFinished) -> None:
        self._finished = True
        self.query_one("#btn-open", Button).disabled = message.result is None
        self.query_one("#btn-new", Button).disabled = False
        for row in self.query(TrackProgressRow):
            row.clear_slot()
        if message.error:
            err = message.error
            short = err if len(err) <= 60 else err[:57] + "…"
            self.query_one("#phase-label", Label).update(f"Failed: {short}")
            self.query_one("#run-log", RichLog).write(f"[red]Error:[/] {message.error}")
            self.notify(message.error, severity="error")
            return
        assert message.result is not None
        result = message.result
        out_name = Path(result.output_path).name
        self.query_one("#phase-label", Label).update(f"Done — {out_name}")
        self.query_one("#overall-bar", ProgressBar).update(total=100, progress=100)
        log = self.query_one("#run-log", RichLog)
        log.write(f"[green]Output:[/] {result.output_path}")
        log.write(f"[green]Description:[/] {result.description_path}")
        for line in result.description_text.strip().splitlines()[:20]:
            log.write(f"  {line}")
        self.notify("Video ready", severity="information")

    def action_cancel(self) -> None:
        if self._finished:
            return
        self.workers.cancel_all()
        self.query_one("#phase-label", Label).update("Cancelled — in-flight renders may finish")
        self.query_one("#btn-new", Button).disabled = False
        self.notify("Cancel requested", severity="warning")

    def action_back(self) -> None:
        if not self._finished:
            self.workers.cancel_all()
        self.app.pop_screen()

    @on(Button.Pressed, "#btn-new")
    def _new_run(self) -> None:
        self.app.pop_screen()

    @on(Button.Pressed, "#btn-quit")
    def _quit(self) -> None:
        self.app.exit()

    @on(Button.Pressed, "#btn-open")
    def _open_folder(self) -> None:
        folder = Path(self.config.output).resolve().parent
        if sys.platform == "darwin":
            subprocess.Popen(["open", str(folder)])
        elif sys.platform.startswith("linux"):
            subprocess.Popen(["xdg-open", str(folder)])
        else:
            subprocess.Popen(["explorer", str(folder)])
