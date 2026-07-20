"""Background sources: generated gradients, blurred artwork, and user images."""

import colorsys
import hashlib
import os
from typing import List, Optional

import numpy as np
import requests
from PIL import Image, ImageFilter


def make_gradient_texture(size, seed_text: str):
    """
    Deterministic-per-track diagonal gradient, built oversized (with margin)
    so it can be panned frame-to-frame for a slow drifting motion instead of
    sitting dead still. Vectorized with numpy so it's cheap to generate once
    per track (panning itself is just a crop, so it's cheap per-frame too).
    """
    w, h = size
    margin_w = int(w * 0.15)
    margin_h = int(h * 0.15)
    big_w, big_h = w + 2 * margin_w, h + 2 * margin_h

    seed = int(hashlib.md5(seed_text.encode()).hexdigest(), 16)
    hue = (seed % 360) / 360.0
    hue2 = (hue + 0.12) % 1.0
    r1, g1, b1 = colorsys.hsv_to_rgb(hue, 0.55, 0.26)
    r2, g2, b2 = colorsys.hsv_to_rgb(hue2, 0.65, 0.15)

    xs = np.linspace(0, 1, big_w)
    ys = np.linspace(0, 1, big_h)
    grid_x, grid_y = np.meshgrid(xs, ys)
    blend = (grid_x + grid_y) / 2.0  # diagonal blend, 0..1

    r = (r1 + (r2 - r1) * blend) * 255
    g = (g1 + (g2 - g1) * blend) * 255
    b = (b1 + (b2 - b1) * blend) * 255
    arr = np.stack([r, g, b], axis=-1).astype("uint8")
    img = Image.fromarray(arr, mode="RGB").filter(ImageFilter.GaussianBlur(3))
    return img, margin_w, margin_h


def make_blurred_artwork_bg(artwork_path: str, size) -> Image.Image:
    art = Image.open(artwork_path).convert("RGB")
    w, h = size
    scale = max(w / art.width, h / art.height) * 1.15
    art = art.resize((int(art.width * scale), int(art.height * scale)), Image.LANCZOS)
    left = (art.width - w) // 2
    top = (art.height - h) // 2
    art = art.crop((left, top, left + w, top + h))
    art = art.filter(ImageFilter.GaussianBlur(40))
    # darken so text stays readable
    overlay = Image.new("RGB", size, (0, 0, 0))
    return Image.blend(art, overlay, 0.45)


def resolve_background_image(
    background_image: Optional[str], workdir: str, index: int = 0, quiet: bool = False
) -> Optional[str]:
    """
    A single --background-image entry: local file path or an http(s) URL.
    URLs get downloaded once up front into workdir and the local path is
    used from then on; a local path is returned as-is (after checking it
    actually exists, so a bad path fails fast with a clear message instead
    of silently falling back to the gradient background later). `index`
    disambiguates the downloaded filename when multiple images are given.
    """
    if not background_image:
        return None
    if background_image.startswith("http://") or background_image.startswith("https://"):
        if not quiet:
            print(f"Downloading background image from {background_image} ...")
        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
        resp = requests.get(background_image, headers=headers, timeout=30)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "")
        ext = ".jpg"
        for candidate in (".png", ".jpg", ".jpeg", ".webp"):
            if candidate.strip(".") in content_type or background_image.split("?")[0].lower().endswith(candidate):
                ext = candidate
                break
        path = os.path.join(workdir, f"background_{index}{ext}")
        with open(path, "wb") as f:
            f.write(resp.content)
        # fail fast if it isn't actually a readable image, rather than
        # surfacing a confusing error deep inside every track's render
        Image.open(path).verify()
        return path
    if not os.path.exists(background_image):
        raise FileNotFoundError(f"--background-image path does not exist: {background_image}")
    return background_image


def resolve_background_images(background_images, workdir: str, quiet: bool = False) -> List[str]:
    """
    Normalizes the --background-image / BACKGROUND_IMAGE setting — which may
    be None, a single path/URL string, or a list of them — into a resolved
    list of local file paths (empty list if none were given).
    """
    if not background_images:
        return []
    if isinstance(background_images, str):
        background_images = [background_images]
    resolved = []
    for i, img in enumerate(background_images):
        path = resolve_background_image(img, workdir, index=i, quiet=quiet)
        if not quiet:
            print(f"Loaded background image {i + 1}/{len(background_images)}: {path}")
        resolved.append(path)
    return resolved


def assign_track_backgrounds(tracks: list, images: List[str]) -> List[Optional[str]]:
    """
    Splits `images` into len(images) contiguous blocks across the tracklist
    (sizes as equal as possible — track count // image count per block, with
    any remainder going to the earlier blocks), so the background switches
    exactly once per block boundary, i.e. at a track transition. Returns one
    entry per track (None for every track if no images were given, which
    falls back to the normal per-track auto background).
    """
    n = len(tracks)
    if not images or n == 0:
        return [None] * n
    k = len(images)
    return [images[i * k // n] for i in range(n)]


def prepare_background(size, background_image: Optional[str], artwork_path: Optional[str], seed_text: str):
    """
    Returns ("static", Image) for a custom background image or blurred artwork
    (both stay still), or ("gradient", (big_img, margin_w, margin_h)) for the
    default generated gradient, which pans over time.
    """
    if background_image and os.path.exists(background_image):
        img = Image.open(background_image).convert("RGB")
        w, h = size
        scale = max(w / img.width, h / img.height)
        img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
        left, top = (img.width - w) // 2, (img.height - h) // 2
        return "static", img.crop((left, top, left + w, top + h))
    if artwork_path and os.path.exists(artwork_path):
        return "static", make_blurred_artwork_bg(artwork_path, size)
    return "gradient", make_gradient_texture(size, seed_text)
