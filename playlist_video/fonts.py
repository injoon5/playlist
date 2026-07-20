"""Font loading with a per-process cache, plus a best-effort Pretendard fetch."""

import os
from typing import Optional

import requests
from PIL import ImageFont

_FONT_CACHE = {}


def load_font(size: int, bold: bool = False, font_dir: Optional[str] = None) -> ImageFont.FreeTypeFont:
    key = (size, bold, font_dir)
    if key in _FONT_CACHE:
        return _FONT_CACHE[key]

    candidates = []
    if font_dir:
        candidates += [
            os.path.join(font_dir, "Pretendard-Bold.otf" if bold else "Pretendard-Regular.otf"),
        ]
    candidates += [
        "/usr/share/fonts/truetype/pretendard/Pretendard-Bold.otf" if bold else "/usr/share/fonts/truetype/pretendard/Pretendard-Regular.otf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "C:\\Windows\\Fonts\\arialbd.ttf" if bold else "C:\\Windows\\Fonts\\arial.ttf",
    ]
    for path in candidates:
        if path and os.path.exists(path):
            font = ImageFont.truetype(path, size)
            _FONT_CACHE[key] = font
            return font

    font = ImageFont.load_default()
    _FONT_CACHE[key] = font
    return font


def try_download_pretendard(dest_dir: str) -> Optional[str]:
    """Best-effort download of Pretendard (nicer default typography, full Korean
    glyph coverage — useful since Apple Music track/artist names are often Korean).
    Tries jsDelivr first, falls back to raw.githubusercontent. Fails silently."""
    files = {
        "Pretendard-Regular.otf": [
            "https://cdn.jsdelivr.net/gh/fonts-archive/Pretendard/Pretendard-Regular.otf",
            "https://raw.githubusercontent.com/fonts-archive/Pretendard/main/Pretendard-Regular.otf",
        ],
        "Pretendard-Bold.otf": [
            "https://cdn.jsdelivr.net/gh/fonts-archive/Pretendard/Pretendard-Bold.otf",
            "https://raw.githubusercontent.com/fonts-archive/Pretendard/main/Pretendard-Bold.otf",
        ],
    }
    os.makedirs(dest_dir, exist_ok=True)
    ok = True
    for fname, urls in files.items():
        dest = os.path.join(dest_dir, fname)
        if os.path.exists(dest):
            continue
        downloaded = False
        for url in urls:
            try:
                r = requests.get(url, timeout=15)
                r.raise_for_status()
                with open(dest, "wb") as f:
                    f.write(r.content)
                downloaded = True
                break
            except Exception:
                continue
        if not downloaded:
            ok = False
    return dest_dir if ok else None
