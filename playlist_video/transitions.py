"""Track-to-track transitions (visual only): eased dip-through-black fades."""

from typing import Callable, Iterator, Tuple

import numpy as np
from PIL import Image

from .text import ease_in_out_cubic


def _apple_fade_transform(frame: np.ndarray, t: float, duration: float, fade_duration: float,
                          zoom_amount: float = 0.035) -> np.ndarray:
    """
    Near the start/end of a clip, blend toward black with a cubic ease while
    very subtly scaling (~3.5%) — Keynote-style fade-through-black.
    """
    if t < fade_duration:
        u = ease_in_out_cubic(t / fade_duration)
    elif t > duration - fade_duration:
        u = ease_in_out_cubic((duration - t) / fade_duration)
    else:
        return frame

    if u >= 0.999:
        return frame

    img = Image.fromarray(frame)
    w, h = img.size

    scale = 1.0 + (1.0 - u) * zoom_amount
    if scale > 1.0005:
        nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
        img = img.resize((nw, nh), Image.BILINEAR)
        left, top = (nw - w) // 2, (nh - h) // 2
        img = img.crop((left, top, left + w, top + h))

    arr = np.asarray(img).astype("float32") * u
    return arr.astype("uint8")


def apply_fade_to_frame(frame: np.ndarray, t: float, duration: float,
                        transition_duration: float) -> np.ndarray:
    """Apply edge fade to a single frame when transition_duration > 0."""
    if transition_duration <= 0 or duration <= 0:
        return frame
    d = min(transition_duration, max(0.05, duration / 2 - 0.05))
    return _apple_fade_transform(frame, t, duration, d)


def iter_faded_frames(
    make_frame: Callable[[float], np.ndarray],
    duration: float,
    fps: int,
    transition_duration: float,
) -> Iterator[Tuple[np.ndarray, float, int]]:
    """
    Yield (frame, t, frame_index) for each frame of the clip, with optional
    dip-through-black transitions at the edges.
    """
    n_frames = max(1, int(round(duration * fps)))
    for i in range(n_frames):
        t = i / fps
        if t > duration:
            t = duration
        frame = make_frame(t)
        frame = apply_fade_to_frame(frame, t, duration, transition_duration)
        yield frame, t, i
