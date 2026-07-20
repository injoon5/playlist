"""Info-screen layout, static foreground layer, and the per-track frame
generator (build_track_clip) that moviepy turns into a video clip."""

import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from .backgrounds import prepare_background
from .fonts import load_font
from .models import Track
from .text import (
    MARQUEE_FADE_IN_SECONDS,
    MARQUEE_FADE_OUT_SECONDS,
    TEXT_TEXTURE_PAD,
    build_directional_fade_profile,
    build_marquee_tile,
    draw_tabular_text,
    ease_in_out_cubic,
    marquee_state,
    render_text_texture,
    rounded_mask,
    tabular_digit_width,
    tabular_text_width,
)


def compute_layout(size, font_dir):
    """
    Single source of truth for every position, so the foreground layer and the
    per-frame progress bar never disagree about where things are.
    The whole block (artwork + title + meta + bar) is vertically centered
    on the canvas as one unit.
    """
    w, h = size

    art_size = int(h * 0.42)
    # title and meta share the same size — title stands out purely through
    # weight (bold, full white) and opacity, not size
    text_font_size = int(h * 0.032)
    time_font_size = int(h * 0.022)

    title_font = load_font(text_font_size, bold=True, font_dir=font_dir)
    meta_font = load_font(text_font_size, bold=False, font_dir=font_dir)
    time_font = load_font(time_font_size, bold=False, font_dir=font_dir)

    tmp = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    title_h = tmp.textbbox((0, 0), "Ag", font=title_font)[3]
    meta_h = tmp.textbbox((0, 0), "Ag", font=meta_font)[3]
    time_h = tmp.textbbox((0, 0), "Ag", font=time_font)[3]

    gap_art_title = int(h * 0.04)
    gap_title_meta = int(h * 0.004)   # tight — title and meta read as one block
    gap_meta_bar = int(h * 0.035)
    bar_h = 6
    gap_bar_label = 14

    block_height = (
        art_size + gap_art_title + title_h + gap_title_meta + meta_h
        + gap_meta_bar + bar_h + gap_bar_label + time_h
    )
    art_y = int((h - block_height) / 2)

    block_x = int(w * 0.5 - art_size / 2)
    title_y = art_y + art_size + gap_art_title
    meta_y = title_y + title_h + gap_title_meta
    bar_y = meta_y + meta_h + gap_meta_bar
    label_y = bar_y + bar_h + gap_bar_label

    return {
        "art_size": art_size,
        "block_x": block_x,
        "art_y": art_y,
        "title_y": title_y,
        "meta_y": meta_y,
        "bar_x": block_x,
        "bar_w": art_size,
        "bar_y": bar_y,
        "bar_h": bar_h,
        "label_y": label_y,
        "title_font": title_font,
        "meta_font": meta_font,
        "time_font": time_font,
        "time_digit_w": tabular_digit_width(time_font),
    }


def render_foreground_layer(track: Track, size, font_dir) -> dict:
    """
    Everything that does NOT change over time and sits ON TOP of the background:
    artwork (with a proper soft drop shadow), plus title/artist/album text —
    baked in statically if it fits within the artwork's width, or handed back
    as a separate full-width texture (for build_track_clip to marquee-scroll
    per frame) if it doesn't.
    """
    layout = compute_layout(size, font_dir)
    fg = Image.new("RGBA", size, (0, 0, 0, 0))

    art_size = layout["art_size"]
    block_x = layout["block_x"]
    art_y = layout["art_y"]
    viewport_w = art_size  # text scrolls/fits within the same width as the artwork

    if track.artwork_path and os.path.exists(track.artwork_path):
        art = Image.open(track.artwork_path).convert("RGB").resize((art_size, art_size), Image.LANCZOS)
    else:
        art = Image.new("RGB", (art_size, art_size), (40, 40, 45))

    # soft drop shadow — generous margin so the blur has room to fall off
    # cleanly instead of getting clipped into a hard-edged ring, offset
    # downward like a real cast shadow rather than a symmetric halo
    margin = max(60, art_size // 5)
    blur_radius = max(30, art_size // 12)
    shadow = Image.new("RGBA", (art_size + margin * 2, art_size + margin * 2), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [margin, margin + int(margin * 0.25), margin + art_size, margin + int(margin * 0.25) + art_size],
        radius=20, fill=(0, 0, 0, 130),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur_radius))
    fg.alpha_composite(shadow, (block_x - margin, art_y - margin))

    mask = rounded_mask((art_size, art_size), radius=18)
    fg.paste(art, (block_x, art_y), mask)

    # typography — title bold/white, meta regular/translucent, both rendered
    # at full natural width; only baked directly into fg if they already fit
    title_font, meta_font = layout["title_font"], layout["meta_font"]
    meta_text = f"{track.artist} — {track.album}" if track.album else track.artist

    title_tex = render_text_texture(track.title, title_font, (255, 255, 255, 255))
    meta_tex = render_text_texture(meta_text, meta_font, (255, 255, 255, 115))

    title_scrolls = title_tex.width > viewport_w
    meta_scrolls = meta_tex.width > viewport_w

    fade_width = max(20, int(viewport_w * 0.07))
    gap_px = max(40, int(viewport_w * 0.18))  # small breathing space between repeats

    # Two fade variants per scrolling element: "rest" only fades the right
    # edge (nothing has scrolled past the left edge yet, so no reason to
    # blur it there), "full" fades both edges (used once sliding is under
    # way). The marquee strip blends between them as the slide starts, so the
    # left blur eases in rather than popping on.
    title_tile = title_fade_full = title_fade_rest = None
    if title_scrolls:
        title_tile = build_marquee_tile(title_tex, gap_px)
        title_fade_full = build_directional_fade_profile(viewport_w, fade_width, True, True)
        title_fade_rest = build_directional_fade_profile(viewport_w, fade_width, False, True)
    else:
        fg.alpha_composite(title_tex, (block_x - TEXT_TEXTURE_PAD, layout["title_y"] - TEXT_TEXTURE_PAD))

    meta_tile = meta_fade_full = meta_fade_rest = None
    if meta_scrolls:
        meta_tile = build_marquee_tile(meta_tex, gap_px)
        meta_fade_full = build_directional_fade_profile(viewport_w, fade_width, True, True)
        meta_fade_rest = build_directional_fade_profile(viewport_w, fade_width, False, True)
    else:
        fg.alpha_composite(meta_tex, (block_x - TEXT_TEXTURE_PAD, layout["meta_y"] - TEXT_TEXTURE_PAD))

    return {
        "layer": fg,
        "layout": layout,
        "viewport_w": viewport_w,
        "title_tile": title_tile,
        "title_fade_full": title_fade_full,
        "title_fade_rest": title_fade_rest,
        "meta_tile": meta_tile,
        "meta_fade_full": meta_fade_full,
        "meta_fade_rest": meta_fade_rest,
    }


def build_track_clip(track: Track, resolution, fps, background_image, font_dir):
    """
    Optimized frame generator. The per-frame costs, and what's done about them:

      1. Full-frame base copy (static-background path): at 4K that's a ~24MB
         memcpy per frame, dwarfing the actual overlay work. Fixed with a
         persistent working frame + dirty-rect restore: keep one frame array
         alive across make_frame calls and, each frame, restore only the
         small rectangles the PREVIOUS frame dirtied (marquee strips +
         progress bar) from the pristine base, then blend the new overlays.
         Safe because moviepy consumes each returned frame (pipes its bytes
         to ffmpeg, or copies it inside the transition wrapper) before
         requesting the next one, and correct for any call order/time since
         every call first restores whatever was dirty.

      2. Full-frame uint16 composite (gradient path): the background moves
         every frame so the frame can't be reused, but the foreground's alpha
         is zero outside the center block (artwork + shadow + text + bar) —
         compositing is a no-op there. The uint16 blend math is restricted to
         the foreground's bounding box; the rest of the frame is a plain
         uint8 crop-copy of the precomputed oversized gradient.

      3. Per-frame overlays (marquee text, progress bar) are alpha-blended
         directly into the uint8 frame in numpy — no PIL RGBA/RGB round
         trips per frame.
    """
    from moviepy.editor import AudioFileClip, VideoClip

    audio = AudioFileClip(track.audio_path)
    duration = audio.duration
    track.duration_sec = duration

    bg_kind, bg_payload = prepare_background(
        resolution, background_image, track.artwork_path, f"{track.artist}{track.title}"
    )
    fg = render_foreground_layer(track, resolution, font_dir)
    layout = fg["layout"]
    block_x, viewport_w = layout["block_x"], fg["viewport_w"]
    W, H = resolution
    fg_layer = fg["layer"]  # full-size RGBA PIL image

    # ---- static base composite (or gradient inputs) as numpy ---------------
    if bg_kind == "gradient":
        big_img, margin_w, margin_h = bg_payload
        big_np = np.asarray(big_img.convert("RGB"))                    # (Hb, Wb, 3) uint8
        # foreground bounding box: everything outside it is fully transparent,
        # so per-frame composite math only needs to run inside it
        fg_bbox = fg_layer.getbbox() or (0, 0, W, H)
        bx0, by0, bx1, by1 = fg_bbox
        fg_np = np.asarray(fg_layer)[by0:by1, bx0:bx1]                  # cropped to bbox
        fg_rgb_u16 = fg_np[..., :3].astype(np.uint16)
        fg_alpha_u16 = fg_np[..., 3:4].astype(np.uint16)
        fg_inv_alpha_u16 = 255 - fg_alpha_u16
        static_base_rgb = None
    else:
        base_pil = bg_payload.convert("RGBA")
        base_pil.alpha_composite(fg_layer)
        static_base_rgb = np.asarray(base_pil.convert("RGB")).copy()   # (H, W, 3) uint8
        big_np = fg_rgb_u16 = fg_alpha_u16 = fg_inv_alpha_u16 = None
        bx0 = by0 = bx1 = by1 = 0

    # ---- marquee text: PIL tiles + edge-fade profiles as numpy -------------
    def _prep_marquee(tile, fade_full, fade_rest):
        if tile is None:
            return None
        return np.asarray(tile), fade_full, fade_rest   # (h, tile_w, 4), (viewport_w,) x2

    title_data = _prep_marquee(fg.get("title_tile"), fg.get("title_fade_full"), fg.get("title_fade_rest"))
    meta_data  = _prep_marquee(fg.get("meta_tile"),  fg.get("meta_fade_full"),  fg.get("meta_fade_rest"))
    title_pos = (block_x - TEXT_TEXTURE_PAD, layout["title_y"] - TEXT_TEXTURE_PAD)
    meta_pos  = (block_x - TEXT_TEXTURE_PAD, layout["meta_y"]  - TEXT_TEXTURE_PAD)

    # ---- progress bar: render only into a small bounding box overlay -------
    time_font = layout["time_font"]
    digit_w = layout["time_digit_w"]
    _tmp_draw = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    label_h = _tmp_draw.textbbox((0, 0), "Ag", font=time_font)[3] + 4
    bar_x_abs = layout["bar_x"]
    bar_y_abs = layout["bar_y"]
    bar_w     = layout["bar_w"]
    bar_h     = layout["bar_h"]
    label_y_local = layout["label_y"] - bar_y_abs
    region_h = label_y_local + label_h  # bar top -> below the time labels

    # ---- numpy alpha-blend (RGBA over RGB, in place) -----------------------
    def _blend(dst_rgb, over_rgba, x, y):
        """Blend and return the (x0, y0, x1, y1) rect actually touched, or
        None if fully clipped — the static path uses these rects to know
        exactly what to restore from the pristine base next frame."""
        oh, ow = over_rgba.shape[:2]
        fh, fw = dst_rgb.shape[:2]
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(fw, x + ow), min(fh, y + oh)
        if x0 >= x1 or y0 >= y1:
            return None
        src = over_rgba[y0 - y:y1 - y, x0 - x:x1 - x]
        alpha = src[..., 3:4].astype(np.uint16)
        rgb   = src[..., :3].astype(np.uint16)
        dst   = dst_rgb[y0:y1, x0:x1].astype(np.uint16)
        dst_rgb[y0:y1, x0:x1] = ((dst * (255 - alpha) + rgb * alpha + 127) // 255).astype(np.uint8)
        return (x0, y0, x1, y1)

    def _marquee_strip(data, t):
        """Continuous wraparound crop of width viewport_w from the endlessly
        tiled (text + gap) texture. The left-edge fade is absent while parked
        at rest (nothing has scrolled past the left edge yet), eases in over
        MARQUEE_FADE_IN_SECONDS once the slide starts, and eases back out
        over the final MARQUEE_FADE_OUT_SECONDS of the slide, so the text
        arrives back at its resting position with a clean, unblurred left
        edge — the blur only returns when the next slide begins. The
        right-edge fade is always present since more text always continues
        off-screen."""
        tile_np, fade_full, fade_rest = data
        tile_w = tile_np.shape[1]
        scroll_x, slide_elapsed, slide_remaining = marquee_state(t, tile_w)
        start = int(scroll_x) % tile_w
        end = start + viewport_w
        if end <= tile_w:
            strip = tile_np[:, start:end]
        else:
            rest = end - tile_w
            strip = np.concatenate([tile_np[:, start:tile_w], tile_np[:, 0:rest]], axis=1)
        strip = strip.copy()  # don't mutate the cached tile

        if slide_elapsed is None:
            fade_row = fade_rest
        else:
            u_in = ease_in_out_cubic(min(slide_elapsed / MARQUEE_FADE_IN_SECONDS, 1.0))
            u_out = ease_in_out_cubic(min(slide_remaining / MARQUEE_FADE_OUT_SECONDS, 1.0))
            u = min(u_in, u_out)  # ease in at slide start, ease out before arrival
            fade_row = fade_rest + (fade_full - fade_rest) * u
        new_alpha = (strip[..., 3].astype(np.float64) * fade_row[np.newaxis, :] + 127) / 255
        strip[..., 3] = new_alpha.astype(np.uint8)
        return strip

    def _render_bar_region(t):
        overlay = Image.new("RGBA", (bar_w, region_h), (0, 0, 0, 0))
        d = ImageDraw.Draw(overlay)
        d.rounded_rectangle([0, 0, bar_w, bar_h], radius=bar_h // 2, fill=(255, 255, 255, 70))
        progress = 0.0 if duration <= 0 else min(max(t / duration, 0), 1)
        fill_w = int(bar_w * progress)
        if fill_w > 0:
            d.rounded_rectangle([0, 0, fill_w, bar_h], radius=bar_h // 2, fill=(255, 255, 255, 235))
        remaining = max(duration - t, 0)
        elapsed_str   = f"{int(t // 60)}:{int(t % 60):02d}"
        remaining_str = f"-{int(remaining // 60)}:{int(remaining % 60):02d}"
        draw_tabular_text(d, (0, label_y_local), elapsed_str, time_font, (255, 255, 255, 180), digit_w)
        tw = tabular_text_width(remaining_str, time_font, digit_w, d)
        draw_tabular_text(d, (bar_w - tw, label_y_local), remaining_str, time_font, (255, 255, 255, 180), digit_w)
        return np.asarray(overlay)

    # persistent working frame + last frame's dirty rects (static path only)
    frame_state = {"work": None, "dirty": []}

    def make_frame(t):
        if bg_kind == "gradient":
            # per-frame gradient pan: numpy slice of the precomputed big array;
            # foreground composited only inside its bounding box (see docstring)
            period = max(duration, 18.0)
            phase = (t / period) * 2 * math.pi
            dx = int(margin_w * (0.5 + 0.5 * math.sin(phase)))
            dy = int(margin_h * (0.5 + 0.5 * math.cos(phase * 0.85)))
            frame = big_np[dy:dy + H, dx:dx + W].copy()
            region = frame[by0:by1, bx0:bx1].astype(np.uint16)
            frame[by0:by1, bx0:bx1] = (
                (region * fg_inv_alpha_u16 + fg_rgb_u16 * fg_alpha_u16 + 127) // 255
            ).astype(np.uint8)
            dirty = None  # background changed everywhere; no frame reuse
        else:
            if frame_state["work"] is None:
                frame_state["work"] = static_base_rgb.copy()
            else:
                for (rx0, ry0, rx1, ry1) in frame_state["dirty"]:
                    frame_state["work"][ry0:ry1, rx0:rx1] = static_base_rgb[ry0:ry1, rx0:rx1]
            frame = frame_state["work"]
            dirty = []

        if title_data is not None:
            rect = _blend(frame, _marquee_strip(title_data, t), *title_pos)
            if dirty is not None and rect:
                dirty.append(rect)
        if meta_data is not None:
            rect = _blend(frame, _marquee_strip(meta_data, t), *meta_pos)
            if dirty is not None and rect:
                dirty.append(rect)

        rect = _blend(frame, _render_bar_region(t), bar_x_abs, bar_y_abs)
        if dirty is not None and rect:
            dirty.append(rect)

        if dirty is not None:
            frame_state["dirty"] = dirty
        return frame

    clip = VideoClip(make_frame, duration=duration).set_fps(fps)
    clip = clip.set_audio(audio)
    return clip
