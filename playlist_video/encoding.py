"""Encoder selection (VideoToolbox / NVENC / libx264-x265) and a moviepy
write_videofile wrapper that keeps VideoToolbox happy."""

import platform
import subprocess
import threading
from dataclasses import dataclass
from typing import List, Optional


def _ffmpeg_has_encoder(name: str) -> bool:
    """True if this ffmpeg build advertises the given encoder in `-encoders`."""
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True,
        ).stdout.decode("utf-8", errors="ignore")
        return f" {name} " in out
    except Exception:
        return False


def pick_hw_encoder() -> Optional[str]:
    """
    Return the best available hardware H.264 encoder for this machine, or None
    for software libx264. macOS -> VideoToolbox (works on both Apple Silicon
    and Intel Macs with any ffmpeg build that has it, which Homebrew's does).
    Linux with an NVIDIA GPU + nvenc-capable ffmpeg -> NVENC. Otherwise None.
    (On Apple Silicon, resolve_encode_settings upgrades the VideoToolbox
    choice to HEVC when the ffmpeg build has hevc_videotoolbox.)
    """
    if platform.system() == "Darwin" and _ffmpeg_has_encoder("h264_videotoolbox"):
        return "h264_videotoolbox"
    try:
        subprocess.run(
            ["nvidia-smi"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True,
        )
        if _ffmpeg_has_encoder("h264_nvenc"):
            return "h264_nvenc"
    except Exception:
        pass
    return None


def estimate_nvenc_bitrate_mbps(resolution, fps: int) -> int:
    """
    A sensible target video bitrate for hardware encoders, scaled from
    YouTube's published recommended upload bitrate for 1080p60 (~12Mbps)
    plus headroom (16Mbps at 1080p60 here). Deliberately bitrate-based
    (-b:v) rather than constant-quality (-cq/-qp): those option names have
    shifted across ffmpeg/NVENC SDK versions and aren't reliably available
    on every build (e.g. Colab's apt ffmpeg), whereas -b:v has been stable
    forever and works everywhere NVENC itself works.
    """
    w, h = resolution
    pixel_scale = (w * h) / (1920 * 1080)
    fps_scale = fps / 60
    return max(4, round(16 * pixel_scale * fps_scale))


def is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() in ("arm64", "aarch64")


VT_QUALITY_DEFAULT = 65  # videotoolbox -q:v (1-100). With HEVC, ~60-65 lands at the same
                          # perceptual quality H.264 needed ~70 for, at a much smaller file;
                          # raise toward 75 if you ever spot banding in dark gradients.

# Standardizing sample rate/channels across every per-track render is what
# makes the final ffmpeg concat (-c copy, see playlist_video.render) safe:
# concat demuxer stream-copy requires every input segment's streams to match.
_CONCAT_SAFE_AUDIO_PARAMS = ["-ar", "48000", "-ac", "2"]
_MOVFLAGS = ["-movflags", "+faststart"]


@dataclass
class EncodeSettings:
    codec: str
    ffmpeg_params: List[str]
    preset: Optional[str]  # None for videotoolbox, which rejects -preset


def _gop_params(fps: int) -> List[str]:
    """
    Long keyframe interval (~10s). This video is mostly static, so spending
    a full intra frame only every ~10s — instead of the encoder's much
    shorter default — lets nearly every frame be a cheap P-frame referencing
    an unchanged background: a large file-size win at zero visual cost.
    (Seeking granularity in local players gets slightly coarser; YouTube
    re-encodes with its own GOP on upload anyway.)
    """
    return ["-g", str(max(fps, 1) * 10)]


def software_encode_settings(
    preset_arg: Optional[str], crf_arg: Optional[int], fps: int = 30
) -> EncodeSettings:
    # "slow" over "veryfast": this video is almost entirely static (only the
    # marquee, progress bar, and track transitions move), so x264's slower
    # motion search finds far more redundancy to exploit than it would on
    # typical high-motion footage — a big size/quality win for not that much
    # extra encode time, since most macroblocks skip early anyway.
    preset = preset_arg or "slow"
    crf = crf_arg if crf_arg is not None else 18
    ffmpeg_params = [
        "-crf", str(crf), "-pix_fmt", "yuv420p",
        *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
    ]
    return EncodeSettings(codec="libx264", ffmpeg_params=ffmpeg_params, preset=preset)


def software_fallback_for(encode: EncodeSettings, fps: int = 30) -> EncodeSettings:
    """
    Software encoder matching the failed hardware encoder's CODEC FAMILY, so
    a per-track fallback stays stream-copy concat-compatible with the tracks
    that hardware-encoded fine — concat_clips uses -c copy, and mixing
    H.264 and HEVC segments in one concat list would break it.
    """
    if encode.codec.startswith("hevc"):
        return EncodeSettings(
            codec="libx265",
            ffmpeg_params=[
                "-crf", "22", "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
                *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
            ],
            preset="medium",
        )
    return software_encode_settings(None, None, fps=fps)


def resolve_encode_settings(gpu_choice: str, preset_arg: Optional[str], crf_arg: Optional[int],
                            resolution, fps: int, quiet: bool = False) -> EncodeSettings:
    """
    Picks the codec + quality/rate-control settings once, shared by every
    per-track parallel render (and the marquee test). Prefers constant
    quality over a flat bitrate wherever the encoder supports it, since a
    flat bitrate assumes constant motion complexity — wasteful and lower
    quality-per-bit for content this static.
    """
    def log(msg: str) -> None:
        if not quiet:
            print(msg)

    hw = pick_hw_encoder()
    if gpu_choice == "off":
        hw = None
    elif gpu_choice == "on" and hw is None:
        hw = "h264_videotoolbox" if platform.system() == "Darwin" else "h264_nvenc"

    if hw == "h264_videotoolbox":
        gop = _gop_params(fps)
        if is_apple_silicon():
            # Constant quality (-q:v) is Apple Silicon-only in ffmpeg; it
            # adapts bits to per-frame complexity instead of a flat rate, so
            # the long static stretches between marquee/bar/transition
            # motion cost almost nothing while motion still looks great.
            quality = VT_QUALITY_DEFAULT
            if _ffmpeg_has_encoder("hevc_videotoolbox"):
                # HEVC over H.264: ~35-45% smaller at the same perceptual
                # quality, encoded by the same dedicated media-engine hardware
                # (no speed cost). -tag:v hvc1 makes the mp4 play natively in
                # QuickTime/Safari; YouTube accepts HEVC uploads.
                ffmpeg_params = ["-q:v", str(quality), "-tag:v", "hvc1", "-allow_sw", "1",
                                 "-pix_fmt", "yuv420p",
                                 "-frames_before", "true", "-frames_after", "true",
                                 *gop, *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS]
                log(f"Encoder: VideoToolbox HEVC, constant quality q:v={quality} (Apple Silicon)")
                return EncodeSettings(codec="hevc_videotoolbox", ffmpeg_params=ffmpeg_params, preset=None)
            ffmpeg_params = ["-q:v", str(quality), "-allow_sw", "1", "-pix_fmt", "yuv420p",
                             "-frames_before", "true", "-frames_after", "true",
                             *gop, *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS]
            log(f"Encoder: VideoToolbox H.264, constant quality q:v={quality} "
                f"(Apple Silicon; this ffmpeg build lacks hevc_videotoolbox)")
        else:
            bitrate = estimate_nvenc_bitrate_mbps(resolution, fps)
            ffmpeg_params = ["-b:v", f"{bitrate}M", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                             *gop, *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS]
            log(f"Encoder: VideoToolbox, ~{bitrate}Mbps (Intel Mac — constant quality needs Apple Silicon)")
        return EncodeSettings(codec=hw, ffmpeg_params=ffmpeg_params, preset=None)

    if hw == "h264_nvenc":
        preset = preset_arg or "p4"
        bitrate = estimate_nvenc_bitrate_mbps(resolution, fps)
        ffmpeg_params = [
            "-rc", "vbr", "-b:v", f"{bitrate}M", "-maxrate", f"{round(bitrate * 1.5)}M",
            "-bufsize", f"{bitrate * 2}M", "-pix_fmt", "yuv420p",
            *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
        ]
        log(f"Encoder: {hw}, preset={preset}, ~{bitrate}Mbps")
        return EncodeSettings(codec=hw, ffmpeg_params=ffmpeg_params, preset=preset)

    settings = software_encode_settings(preset_arg, crf_arg, fps=fps)
    log(f"Encoder: libx264 (CPU), preset={settings.preset}, crf={crf_arg if crf_arg is not None else 18}")
    return settings


# ---------------------------------------------------------------------------
# VideoToolbox `-preset` workaround
#
# moviepy's ffmpeg writer always injects `-preset <name>` into the ffmpeg
# command it builds, and VideoToolbox encoders reject that option. The old
# implementation temporarily monkey-patched subprocess.Popen around each
# write — a race when several render threads write concurrently (the TUI's
# quiet path uses a thread pool). Instead we install, once per process, a
# subprocess-module proxy on moviepy's ffmpeg_writer module whose Popen
# strips `-preset` only from commands that use a videotoolbox codec. The
# decision is per-command, so it is safe under any thread interleaving and
# leaves every other encoder's command untouched.
# ---------------------------------------------------------------------------

_vt_filter_lock = threading.Lock()
_vt_filter_installed = False


def _strip_preset(cmd):
    filtered, skip_next = [], False
    for part in cmd:
        if skip_next:
            skip_next = False
            continue
        if part == "-preset":
            skip_next = True
            continue
        filtered.append(part)
    return filtered


def _install_videotoolbox_preset_filter() -> None:
    global _vt_filter_installed
    with _vt_filter_lock:
        if _vt_filter_installed:
            return
        import moviepy.video.io.ffmpeg_writer as ffmpeg_writer

        real_popen = subprocess.Popen

        def _filtering_popen(cmd, *args, **kwargs):
            if isinstance(cmd, (list, tuple)) and any(
                isinstance(part, str) and "videotoolbox" in part for part in cmd
            ):
                cmd = _strip_preset(list(cmd))
            return real_popen(cmd, *args, **kwargs)

        class _SubprocessProxy:
            """Stands in for the `subprocess` module inside moviepy's
            ffmpeg_writer only; everything except Popen passes through."""
            Popen = staticmethod(_filtering_popen)

            def __getattr__(self, name):
                return getattr(subprocess, name)

        ffmpeg_writer.sp = _SubprocessProxy()
        _vt_filter_installed = True


def ensure_encoder_compat(codec: str) -> None:
    """Call before any moviepy write using `codec`; installs the
    VideoToolbox -preset filter when needed (idempotent, thread-safe)."""
    if "videotoolbox" in codec:
        _install_videotoolbox_preset_filter()


def write_videofile(clip, out_path: str, encode: EncodeSettings, *, fps: int,
                    ffmpeg_threads: int, logger) -> None:
    """moviepy write_videofile with the encoder settings applied and the
    VideoToolbox -preset incompatibility handled."""
    ensure_encoder_compat(encode.codec)
    write_kwargs = dict(
        fps=fps,
        codec=encode.codec,
        audio_codec="aac",
        audio_bitrate="192k",
        threads=ffmpeg_threads,
        ffmpeg_params=list(encode.ffmpeg_params),
        verbose=False,
        logger=logger,
    )
    if encode.preset is not None:
        write_kwargs["preset"] = encode.preset
    clip.write_videofile(out_path, **write_kwargs)
