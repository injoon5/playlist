"""Messages posted from worker threads back to the UI thread."""

from typing import List, Optional

from textual.message import Message

from ..models import PipelineResult, ProgressEvent, Track


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
