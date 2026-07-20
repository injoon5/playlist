"""Typography building blocks: easing, text textures with baked shadows,
manual tabular figures, marquee tiles/timing, and anti-aliased masks."""

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def rounded_mask(size, radius, supersample=4):
    """
    Anti-aliased rounded-corner mask: draw the rounded rect at `supersample`x
    resolution, then downscale with LANCZOS. Drawing directly at target size
    gives PIL's rounded_rectangle a hard, aliased (jagged/staircased) curve;
    supersampling + downscaling produces a smooth soft-edged corner instead.
    """
    ss = max(1, supersample)
    big = Image.new("L", (size[0] * ss, size[1] * ss), 0)
    d = ImageDraw.Draw(big)
    d.rounded_rectangle([0, 0, size[0] * ss, size[1] * ss], radius=radius * ss, fill=255)
    return big.resize(size, Image.LANCZOS)


def ease_in_out_cubic(u: float) -> float:
    """
    The one easing curve used everywhere motion happens in this video (marquee
    scroll, track transitions) — same curve throughout reads as one consistent,
    considered motion language rather than a grab-bag of different animation
    feels. Cubic in/out: slow-fast-slow, the standard "polished UI" ease.
    """
    u = min(max(u, 0.0), 1.0)
    return 4 * u ** 3 if u < 0.5 else 1 - ((-2 * u + 2) ** 3) / 2


TEXT_TEXTURE_PAD = 10  # margin baked into every text texture for the shadow's blur to fall off in;
                        # callers must offset the paste position by -TEXT_TEXTURE_PAD to keep the
                        # visible glyph flush with the artwork/bar's left edge, not inset by the padding


def render_text_texture(text: str, font, fill_rgba, shadow: bool = True) -> Image.Image:
    """Render one line of text at its full natural width (never truncated) onto
    a tight, transparent RGBA canvas, with a soft drop shadow baked in so it
    stays legible over any background — including a user's own custom image —
    without darkening the picture itself. Used both for text that fits as-is
    and as the source strip a marquee crops a moving window out of, so the
    shadow scrolls right along with the text."""
    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    bbox = tmp.textbbox((0, 0), text, font=font)
    text_w = max(1, bbox[2] - bbox[0])
    text_h = max(1, bbox[3] - bbox[1])
    pad = TEXT_TEXTURE_PAD
    img = Image.new("RGBA", (text_w + pad * 2, text_h + pad * 2), (0, 0, 0, 0))

    if shadow:
        shadow_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow_layer)
        sd.text((pad - bbox[0], pad - bbox[1] + 2), text, font=font, fill=(0, 0, 0, 190))
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(3))
        img.alpha_composite(shadow_layer)

    d = ImageDraw.Draw(img)
    d.text((pad - bbox[0], pad - bbox[1]), text, font=font, fill=fill_rgba)
    return img


def tabular_digit_width(font) -> float:
    """Widest single-digit glyph in this font, used as a fixed advance width
    so numeric labels don't jitter horizontally as digits of different
    natural widths tick over (manual tabular figures — PIL's basic text
    layout has no 'tnum' OpenType feature toggle without libraqm)."""
    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    return max(tmp.textlength(d, font=font) for d in "0123456789")


def tabular_text_width(text: str, font, digit_w: float, draw: ImageDraw.ImageDraw) -> float:
    return sum(digit_w if ch.isdigit() else draw.textlength(ch, font=font) for ch in text)


def draw_tabular_text(draw: ImageDraw.ImageDraw, xy, text: str, font, fill, digit_w: float) -> None:
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += digit_w if ch.isdigit() else draw.textlength(ch, font=font)


MARQUEE_HOLD_SECONDS = 2.6  # how long the marquee sits still (flush left) before each scroll
MARQUEE_FADE_IN_SECONDS = 0.35  # how long the left-edge fade takes to ease in once sliding starts
MARQUEE_FADE_OUT_SECONDS = 0.5  # how long before arrival the left-edge fade eases back out, so the
                                # text settles into its resting position with a clean, unblurred left
                                # edge (safe: the tile's trailing gap means nothing visible is crossing
                                # the left edge during the final stretch of the slide)


def marquee_state(t: float, tile_w: float, speed_px_per_sec: float = 28.0, hold_seconds: float = MARQUEE_HOLD_SECONDS):
    """
    Scroll position for time t across one tile width, plus how long the slide
    has been running and how long until it arrives back at rest (both None
    while at rest). Holds at position 0 for hold_seconds, then slides
    right-to-left at constant speed straight through the tile (text + gap),
    arriving back at position 0 exactly as the tile wraps — the loop is
    seamless (position 0 and position tile_w are the same pixel under
    modulo) — and holds there again before repeating.
    """
    slide_time = max(tile_w / speed_px_per_sec, 0.6)
    period = hold_seconds + slide_time
    phase = t % period
    if phase < hold_seconds:
        return 0.0, None, None
    slide_elapsed = phase - hold_seconds
    return speed_px_per_sec * slide_elapsed, slide_elapsed, slide_time - slide_elapsed


def build_directional_fade_profile(width: int, fade_width: int, fade_left: bool, fade_right: bool) -> np.ndarray:
    """
    1D (width,) alpha profile (0..255 as float), fading toward transparent at
    the left and/or right edge — only on the sides requested — full opacity
    everywhere else. Broadcastable across any row height, and cheap to
    interpolate between two variants (see the marquee strip fade-in in
    playlist_video.frames).
    """
    fade_width = max(1, min(fade_width, width // 2))
    x = np.arange(width)
    profile = np.ones(width)
    if fade_left:
        profile = np.minimum(profile, np.clip(x / fade_width, 0, 1))
    if fade_right:
        profile = np.minimum(profile, np.clip((width - 1 - x) / fade_width, 0, 1))
    return profile * 255.0


def build_marquee_tile(text_tex: Image.Image, gap_px: int) -> Image.Image:
    """
    One repeat unit for a continuously scrolling marquee: the text texture
    followed by a transparent gap, endlessly tiled via modulo indexing at
    render time (see the marquee strip logic in playlist_video.frames).
    Because the loop point is just wrapping around within this one tile —
    never a reset of position — the scroll never stops or jumps; the gap is
    what reads as a small breathing space between repeats while the motion
    itself never stops.
    """
    tile_w = text_tex.width + gap_px
    tile = Image.new("RGBA", (tile_w, text_tex.height), (0, 0, 0, 0))
    tile.alpha_composite(text_tex, (0, 0))
    return tile
