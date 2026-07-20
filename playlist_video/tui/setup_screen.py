"""Setup screen: configure the run, load a playlist, and select tracks."""

import os
from pathlib import Path
from typing import List, Optional

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.reactive import reactive
from textual.screen import Screen
from textual.widgets import (
    Button,
    Footer,
    Header,
    Input,
    Label,
    Select,
    SelectionList,
    Switch,
)
from textual.widgets.selection_list import Selection

from .. import config as defaults
from ..config import PROJECT_ROOT
from ..models import PipelineConfig, Track
from ..scraper import fetch_playlist_tracks
from .messages import TracksLoaded
from .run_screen import RunScreen

BG_DIR = PROJECT_ROOT / "assets" / "backgrounds"
BG_EXTS = {".jpeg", ".jpg", ".png", ".webp", ".gif", ".bmp"}

_RESOLUTIONS = {"1920x1080", "2560x1440", "3840x2160"}


def _list_background_assets() -> List[Path]:
    if not BG_DIR.is_dir():
        return []
    return sorted(
        p for p in BG_DIR.iterdir() if p.is_file() and p.suffix.lower() in BG_EXTS
    )


def _default_background_selection() -> set[str]:
    """Relative paths (from the project root) that should start selected."""
    if defaults.BACKGROUND_IMAGE:
        items = (
            defaults.BACKGROUND_IMAGE
            if isinstance(defaults.BACKGROUND_IMAGE, list)
            else [defaults.BACKGROUND_IMAGE]
        )
        return {str(Path(p)) for p in items}
    paths = _list_background_assets()[:2]
    return {str(p.relative_to(PROJECT_ROOT)) for p in paths}


def _parse_optional_int(raw: str) -> Optional[int]:
    raw = raw.strip()
    if not raw:
        return None
    return int(raw)


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
                    value="" if "YOUR-PLAYLIST" in defaults.PLAYLIST_URL else defaults.PLAYLIST_URL,
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
                    yield Switch(value=defaults.SHUFFLE, id="shuffle")

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
                            defaults.RESOLUTION
                            if defaults.RESOLUTION in _RESOLUTIONS
                            else "1920x1080"
                        ),
                        id="resolution",
                        allow_blank=False,
                    )

                    yield Label("Output path", classes="field-label")
                    yield Input(value=defaults.OUTPUT, id="output")

                    yield Label(
                        "Backgrounds — space to toggle (none = auto)",
                        classes="field-label",
                    )
                    yield SelectionList[str](id="bg-list")

                    with Horizontal(classes="row"):
                        with Vertical(classes="half"):
                            yield Label("Download workers", classes="field-label")
                            yield Input(value=str(defaults.WORKERS), id="workers", type="integer")
                        with Vertical(classes="half"):
                            yield Label("Render workers", classes="field-label")
                            yield Input(
                                value="" if defaults.RENDER_WORKERS is None else str(defaults.RENDER_WORKERS),
                                placeholder="auto",
                                id="render-workers",
                                type="integer",
                            )

                    with Horizontal(classes="row"):
                        with Vertical(classes="half"):
                            yield Label("GPU", classes="field-label")
                            yield Select(
                                [("Auto", "auto"), ("On", "on"), ("Off", "off")],
                                value=defaults.GPU if defaults.GPU in {"auto", "on", "off"} else "auto",
                                id="gpu",
                                allow_blank=False,
                            )
                        with Vertical(classes="half"):
                            yield Label("FPS", classes="field-label")
                            yield Input(value=str(defaults.FPS), id="fps", type="integer")

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
        selected_defaults = _default_background_selection()
        assets = _list_background_assets()
        if not assets:
            self.notify(f"No images in {BG_DIR.relative_to(PROJECT_ROOT)}", severity="warning")
            return
        for path in assets:
            rel = str(path.relative_to(PROJECT_ROOT))
            sel.add_option(Selection(path.name, rel, rel in selected_defaults))

    def _selected_backgrounds(self) -> Optional[List[str]]:
        # Selection values are project-root-relative; resolve to absolute so
        # the pipeline finds them regardless of the process's working directory.
        selected = list(self.query_one("#bg-list", SelectionList).selected)
        return [str(PROJECT_ROOT / rel) for rel in selected] or None

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

        config = PipelineConfig(
            playlist_url=url or None,
            output=self.query_one("#output", Input).value.strip() or defaults.OUTPUT,
            resolution=resolution,
            fps=fps,
            limit=None,
            background_images=self._selected_backgrounds(),
            shuffle=self.query_one("#shuffle", Switch).value,
            workers=workers,
            render_workers=render_workers,
            gpu=gpu,
            transition_duration=defaults.TRANSITION_DURATION,
            quiet=True,
            tracks=tracks,
        )
        n_slots = max(workers, render_workers or (os.cpu_count() or 4))
        self.app.push_screen(RunScreen(config, tracks, n_slots))
