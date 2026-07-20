"""Reusable TUI widgets."""

from typing import Optional

from textual.app import ComposeResult
from textual.widgets import Label, ProgressBar, Static


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
        # Reset ETA without toggling total=None (that flashes indeterminate and
        # shifts layout). _eta/_clock are Textual internals — guard so a
        # Textual upgrade degrades to a slightly stale ETA, not a crash.
        try:
            bar._eta.reset()
            bar._clock.reset()
        except AttributeError:
            pass
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
