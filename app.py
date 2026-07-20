# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "textual",
#     "yt-dlp[default]",
#     "moviepy<2",
#     "pillow",
#     "requests",
#     "numpy",
#     "playwright",
#     "tqdm",
#     "proglog",
# ]
# ///
"""Textual TUI for Apple Music → playlist video generation."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.reactive import reactive
from textual.screen import Screen
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    ProgressBar,
    RichLog,
    Select,
    SelectionList,
    Static,
    Switch,
)
from textual.widgets.selection_list import Selection
from textual.worker import get_current_worker

from apple_music_playlist_video import (
    BACKGROUND_IMAGE,
    COOKIES_FILE,
    FPS,
    GPU,
    OUTPUT,
    PLAYLIST_URL,
    RENDER_WORKERS,
    RESOLUTION,
    SHUFFLE,
    TRANSITION_DURATION,
    WORKERS,
    PipelineConfig,
    PipelineResult,
    ProgressEvent,
    Track,
    fetch_playlist_tracks,
    run_pipeline,
)

ROOT = Path(__file__).resolve().parent
BG_DIR = ROOT / "assets" / "backgrounds"
BG_EXTS = {".jpeg", ".jpg", ".png", ".webp", ".gif", ".bmp"}


def _list_background_assets() -> List[Path]:
    if not BG_DIR.is_dir():
        return []
    return sorted(
        p for p in BG_DIR.iterdir() if p.is_file() and p.suffix.lower() in BG_EXTS
    )


def _default_background_selection() -> set[str]:
    """Relative paths that should start selected."""
    if BACKGROUND_IMAGE:
        items = BACKGROUND_IMAGE if isinstance(BACKGROUND_IMAGE, list) else [BACKGROUND_IMAGE]
        return {str(Path(p)) for p in items}
    paths = _list_background_assets()[:2]
    return {str(p.relative_to(ROOT)) for p in paths}


def _parse_optional_int(raw: str) -> Optional[int]:
    raw = raw.strip()
    if not raw:
        return None
    return int(raw)


class PipelineProgress(Message):
    def __init__(self, event: ProgressEvent) -> None:
        self.event = event
        super().__init__()


class PipelineFinished(Message):
    def __init__(self, result: Optional[PipelineResult], error: Optional[str] = None) -> None:
        self.result = result
        self.error = error
        super().__init__()


class TracksLoaded(Message):
    def __init__(self, tracks: List[Track], error: Optional[str] = None) -> None:
        self.tracks = tracks
        self.error = error
        super().__init__()


class TrackProgressRow(Static):
    """One active-slot row: label + progress bar."""

    DEFAULT_CSS = """
    TrackProgressRow {
        layout: horizontal;
        height: 1;
        width: 100%;
    }
    TrackProgressRow > Label {
        width: 1fr;
        min-width: 8;
        color: $text-muted;
        overflow: hidden;
    }
    TrackProgressRow > ProgressBar {
        /* Bar(12) + %(5) + ETA(9) — never shrink below content */
        width: 26;
        min-width: 26;
        dock: right;
    }
    TrackProgressRow > ProgressBar > Bar {
        width: 12;
        min-width: 12;
    }
    """

    def __init__(self, slot_id: int, **kwargs) -> None:
        super().__init__(**kwargs)
        self.slot_id = slot_id
        self._current_label = ""

    def compose(self) -> ComposeResult:
        yield Label(f"[{self.slot_id}] —", id=f"slot-label-{self.slot_id}")
        yield ProgressBar(
            total=100,
            show_eta=True,
            show_percentage=True,
            id=f"slot-bar-{self.slot_id}",
        )

    def _reset_bar(self) -> None:
        bar = self.query_one(ProgressBar)
        # Reset ETA without toggling total=None (that flashes indeterminate and shifts layout)
        bar._eta.reset()
        bar._clock.reset()
        bar.update(total=100, progress=0)

    def clear_slot(self) -> None:
        self._current_label = ""
        self.query_one(Label).update(f"[{self.slot_id}] —")
        self._reset_bar()

    def set_progress(self, label: str, fraction: Optional[float]) -> None:
        short = label if len(label) <= 48 else label[:45] + "…"
        self.query_one(Label).update(f"[{self.slot_id}] {short}")
        bar = self.query_one(ProgressBar)
        if fraction is None:
            self._current_label = ""
            self._reset_bar()
            return
        if label != self._current_label:
            self._current_label = label
            self._reset_bar()
        bar.update(total=100, progress=int(max(0.0, min(1.0, fraction)) * 100))


class SetupScreen(Screen):
    """Configure run + load playlist + select tracks."""

    BINDINGS = [
        Binding("l", "load_tracks", "Load", show=True),
        Binding("g", "generate", "Generate", show=True),
        Binding("a", "select_all", "All", show=True),
        Binding("n", "select_none", "None", show=True),
        Binding("q", "app.quit", "Quit", show=True),
    ]

    loaded_tracks: reactive[List[Track]] = reactive(list, layout=False)

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="setup-body"):
            with Vertical(id="playlist-pane"):
                yield Label("Playlist URL", classes="field-label")
                yield Input(
                    value="" if "YOUR-PLAYLIST" in PLAYLIST_URL else PLAYLIST_URL,
                    placeholder="https://music.apple.com/…/playlist/…",
                    id="playlist-url",
                )
                yield Button("Load tracks", variant="primary", id="btn-load")
                with Horizontal(id="track-header"):
                    yield Label("Tracks — space to toggle", classes="field-label")
                    with Horizontal(id="track-select-btns"):
                        yield Button(
                            "All", id="btn-all", flat=True, compact=True, disabled=True
                        )
                        yield Button(
                            "None", id="btn-none", flat=True, compact=True, disabled=True
                        )
                yield SelectionList[int](id="track-list")
                with Horizontal(id="track-footer", classes="row switches"):
                    yield Label("0 tracks loaded", id="track-count")
                    yield Label("Shuffle", classes="switch-label")
                    yield Switch(value=SHUFFLE, id="shuffle")

            with Vertical(id="settings-pane"):
                with VerticalScroll(id="setup-form"):
                    yield Label("Resolution", classes="field-label")
                    yield Select(
                        [
                            ("1080p — 1920×1080", "1920x1080"),
                            ("1440p — 2560×1440", "2560x1440"),
                            ("4K — 3840×2160", "3840x2160"),
                        ],
                        value=(
                            RESOLUTION
                            if RESOLUTION in {"1920x1080", "2560x1440", "3840x2160"}
                            else "1920x1080"
                        ),
                        id="resolution",
                        allow_blank=False,
                    )

                    yield Label("Output path", classes="field-label")
                    yield Input(value=OUTPUT, id="output")

                    yield Label(
                        "Backgrounds — space to toggle (none = auto)",
                        classes="field-label",
                    )
                    yield SelectionList[str](id="bg-list")

                    with Horizontal(classes="row"):
                        with Vertical(classes="half"):
                            yield Label("Download workers", classes="field-label")
                            yield Input(value=str(WORKERS), id="workers", type="integer")
                        with Vertical(classes="half"):
                            yield Label("Render workers", classes="field-label")
                            yield Input(
                                value="" if RENDER_WORKERS is None else str(RENDER_WORKERS),
                                placeholder="auto",
                                id="render-workers",
                                type="integer",
                            )

                    with Horizontal(classes="row"):
                        with Vertical(classes="half"):
                            yield Label("GPU", classes="field-label")
                            yield Select(
                                [("Auto", "auto"), ("On", "on"), ("Off", "off")],
                                value=GPU if GPU in {"auto", "on", "off"} else "auto",
                                id="gpu",
                                allow_blank=False,
                            )
                        with Vertical(classes="half"):
                            yield Label("FPS", classes="field-label")
                            yield Input(value=str(FPS), id="fps", type="integer")

                yield Button(
                    "Generate video",
                    variant="success",
                    id="btn-generate",
                    disabled=True,
                )

        yield Footer()

    def on_mount(self) -> None:
        self._populate_backgrounds()
        self.query_one("#playlist-url", Input).focus()

    def _populate_backgrounds(self) -> None:
        sel = self.query_one("#bg-list", SelectionList)
        sel.clear_options()
        defaults = _default_background_selection()
        assets = _list_background_assets()
        if not assets:
            self.notify(f"No images in {BG_DIR.relative_to(ROOT)}", severity="warning")
            return
        for path in assets:
            rel = str(path.relative_to(ROOT))
            sel.add_option(Selection(path.name, rel, rel in defaults))

    def _selected_backgrounds(self) -> Optional[List[str]]:
        selected = list(self.query_one("#bg-list", SelectionList).selected)
        return selected or None

    @on(Button.Pressed, "#btn-load")
    def _on_load_btn(self) -> None:
        self.action_load_tracks()

    @on(Input.Submitted, "#playlist-url")
    def _on_url_submitted(self) -> None:
        self.action_load_tracks()

    @on(Button.Pressed, "#btn-all")
    def _on_all(self) -> None:
        self.action_select_all()

    @on(Button.Pressed, "#btn-none")
    def _on_none(self) -> None:
        self.action_select_none()

    @on(Button.Pressed, "#btn-generate")
    def _on_generate_btn(self) -> None:
        self.action_generate()

    def action_select_all(self) -> None:
        if not self.loaded_tracks:
            return
        self.query_one("#track-list", SelectionList).select_all()

    def action_select_none(self) -> None:
        if not self.loaded_tracks:
            return
        self.query_one("#track-list", SelectionList).deselect_all()

    def action_load_tracks(self) -> None:
        url = self.query_one("#playlist-url", Input).value.strip()
        if not url or "YOUR-PLAYLIST" in url:
            self.notify("Enter a valid Apple Music playlist URL", severity="error")
            return
        self.query_one("#track-count", Label).update("Loading…")
        self.query_one("#btn-load", Button).disabled = True
        self.load_tracks_worker(url)

    @work(thread=True, exclusive=True, group="fetch")
    def load_tracks_worker(self, url: str) -> None:
        try:
            tracks = fetch_playlist_tracks(url)
            self.post_message(TracksLoaded(tracks))
        except Exception as e:
            self.post_message(TracksLoaded([], error=str(e)))

    def _set_tracks_ready(self, ready: bool) -> None:
        self.query_one("#btn-all", Button).disabled = not ready
        self.query_one("#btn-none", Button).disabled = not ready
        self.query_one("#btn-generate", Button).disabled = not ready

    def on_tracks_loaded(self, message: TracksLoaded) -> None:
        self.query_one("#btn-load", Button).disabled = False
        if message.error:
            self.loaded_tracks = []
            self.query_one("#track-list", SelectionList).clear_options()
            self._set_tracks_ready(False)
            self.query_one("#track-count", Label).update("Load failed")
            self.notify(f"Failed to load playlist: {message.error}", severity="error")
            return
        self.loaded_tracks = message.tracks
        sel = self.query_one("#track-list", SelectionList)
        sel.clear_options()
        for i, track in enumerate(message.tracks):
            prompt = f"{i + 1:>3}. {track.title}  —  {track.artist}"
            sel.add_option(Selection(prompt, i, True))
        self._set_tracks_ready(bool(message.tracks))
        self._refresh_track_count()
        self.notify(f"Loaded {len(message.tracks)} tracks", severity="information")

    @on(SelectionList.SelectedChanged)
    def _on_selection_changed(self) -> None:
        self._refresh_track_count()

    def _refresh_track_count(self) -> None:
        n = len(self.loaded_tracks)
        if n == 0:
            self.query_one("#track-count", Label).update("0 tracks loaded")
            return
        selected = len(self.query_one("#track-list", SelectionList).selected)
        self.query_one("#track-count", Label).update(
            f"{n} tracks loaded — {selected} selected"
        )

    def _selected_tracks(self) -> List[Track]:
        selected = set(self.query_one("#track-list", SelectionList).selected)
        return [t for i, t in enumerate(self.loaded_tracks) if i in selected]

    def action_generate(self) -> None:
        url = self.query_one("#playlist-url", Input).value.strip()
        if not self.loaded_tracks:
            self.notify("Load a playlist first (L)", severity="warning")
            return
        selected = self._selected_tracks()
        if not selected:
            self.notify("Select at least one track", severity="error")
            return

        try:
            workers = _parse_optional_int(self.query_one("#workers", Input).value) or 4
            render_workers = _parse_optional_int(self.query_one("#render-workers", Input).value)
            fps = _parse_optional_int(self.query_one("#fps", Input).value) or 30
        except ValueError:
            self.notify("Workers / fps must be integers", severity="error")
            return

        tracks = list(selected)
        for i, t in enumerate(tracks):
            t.index, t.total = i + 1, len(tracks)

        resolution = self.query_one("#resolution", Select).value
        if not isinstance(resolution, str):
            resolution = "1920x1080"
        gpu = self.query_one("#gpu", Select).value
        if not isinstance(gpu, str):
            gpu = "auto"

        cookies = COOKIES_FILE or None
        config = PipelineConfig(
            playlist_url=url or None,
            output=self.query_one("#output", Input).value.strip() or OUTPUT,
            resolution=resolution,
            fps=fps,
            limit=None,
            background_images=self._selected_backgrounds(),
            shuffle=self.query_one("#shuffle", Switch).value,
            workers=workers,
            render_workers=render_workers,
            gpu=gpu,
            transition_duration=TRANSITION_DURATION,
            cookies_file=cookies,
            quiet=True,
            tracks=tracks,
        )
        n_slots = max(workers, render_workers or (os.cpu_count() or 4))
        self.app.push_screen(RunScreen(config, tracks, n_slots))


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

        # download 0–45%, render 45–95%, concat 95–100%
        weights = {
            "fetch": (0.0, 0.0),
            "download": (0.0, 0.45),
            "render": (0.45, 0.50),
            "concat": (0.95, 0.05),
            "done": (1.0, 0.0),
        }
        base, span = weights.get(ev.phase, (0.0, 0.0))

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


class PlaylistGenApp(App[None]):
    TITLE = "Playlist Gen"
    SUB_TITLE = "Apple Music → video"
    CSS_PATH = "app.tcss"
    BINDINGS = [Binding("q", "quit", "Quit")]

    def on_mount(self) -> None:
        self.push_screen(SetupScreen())


if __name__ == "__main__":
    PlaylistGenApp().run()
