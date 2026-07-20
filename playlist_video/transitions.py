"""Track-to-track transitions (visual only): eased dip-through-black fades."""

import numpy as np
from PIL import Image

from .text import ease_in_out_cubic


def _apple_fade_transform(get_frame, t, duration, fade_duration, zoom_amount=0.035):
    """
    One clip's per-frame transform for the fade: near the very start/end of the
    clip's own runtime, blend toward black with a cubic ease (not linear — a
    linear alpha ramp reads as mechanical) while very subtly scaling the frame
    (~3.5%) so it settles into place rather than just materializing. This is
    the same idea as Keynote's built-in "Fade Through Color" transition:
    dip through black, ease the whole way, no dead-linear ramps.
    """
    frame = get_frame(t)

    if t < fade_duration:
        u = ease_in_out_cubic(t / fade_duration)
    elif t > duration - fade_duration:
        u = ease_in_out_cubic((duration - t) / fade_duration)
    else:
        return frame  # steady-state, skip all extra work

    if u >= 0.999:
        return frame

    img = Image.fromarray(frame)
    w, h = img.size

    scale = 1.0 + (1.0 - u) * zoom_amount
    if scale > 1.0005:
        nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
        # BILINEAR, not LANCZOS: at a <=3.5% upscale on frames that are
        # simultaneously fading through black, the two are visually
        # indistinguishable — and LANCZOS at 4K is several times slower,
        # per frame, for the whole duration of every fade.
        img = img.resize((nw, nh), Image.BILINEAR)
        left, top = (nw - w) // 2, (nh - h) // 2
        img = img.crop((left, top, left + w, top + h))

    arr = np.asarray(img).astype("float32") * u
    return arr.astype("uint8")


def apply_single_clip_transition(clip, transition_duration: float):
    """
    A short, eased dip-through-black at one clip's own edges, with a very
    subtle accompanying scale — purely visual, Keynote/Apple-style polish
    instead of a flat linear cross-fade. Only ever touches video frames
    (never clip.audio), and only reads from this one clip's own runtime, so
    it's safe to apply per-track in isolation (e.g. before parallel
    rendering) rather than only after assembling the full playlist.
    """
    d = min(transition_duration, max(0.05, clip.duration / 2 - 0.05))
    duration = clip.duration
    return clip.fl(lambda gf, t, d=d, duration=duration: _apple_fade_transform(gf, t, duration, d))
