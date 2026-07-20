"""Encoder selection (VideoToolbox / NVENC / libx264-x265) and raw-frame
ffmpeg piping (no moviepy)."""

import platform
import subprocess
import threading
from dataclasses import dataclass
from threading import Event
from typing import Callable, Iterator, List, Optional, Tuple

import numpy as np

from .models import CancelledError, check_cancelled


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
    for software libx264. macOS -> VideoToolbox. Linux + NVIDIA -> NVENC.
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
    """Target video bitrate scaled from YouTube's ~12Mbps 1080p60 recommendation."""
    w, h = resolution
    pixel_scale = (w * h) / (1920 * 1080)
    fps_scale = fps / 60
    return max(4, round(16 * pixel_scale * fps_scale))


def is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() in ("arm64", "aarch64")


VT_QUALITY_DEFAULT = 65

_CONCAT_SAFE_AUDIO_PARAMS = ["-ar", "48000", "-ac", "2"]
_MOVFLAGS = ["-movflags", "+faststart"]


@dataclass
class EncodeSettings:
    codec: str
    ffmpeg_params: List[str]
    preset: Optional[str]  # None for videotoolbox, which rejects -preset


def _gop_params(fps: int) -> List[str]:
    return ["-g", str(max(fps, 1) * 10)]


def software_encode_settings(
    preset_arg: Optional[str], crf_arg: Optional[int], fps: int = 30
) -> EncodeSettings:
    preset = preset_arg or "slow"
    crf = crf_arg if crf_arg is not None else 18
    ffmpeg_params = [
        "-crf", str(crf), "-pix_fmt", "yuv420p",
        *_gop_params(fps), *_CONCAT_SAFE_AUDIO_PARAMS, *_MOVFLAGS,
    ]
    return EncodeSettings(codec="libx264", ffmpeg_params=ffmpeg_params, preset=preset)


def software_fallback_for(encode: EncodeSettings, fps: int = 30) -> EncodeSettings:
    """Software encoder matching the failed hardware encoder's codec family."""
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
            quality = VT_QUALITY_DEFAULT
            if _ffmpeg_has_encoder("hevc_videotoolbox"):
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


def probe_audio_duration(path: str) -> float:
    """Audio/container duration in seconds via ffprobe."""
    out = subprocess.run(
        [
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", path,
        ],
        capture_output=True, text=True, check=True, timeout=30,
    ).stdout.strip()
    return float(out)


def _build_ffmpeg_cmd(
    out_path: str,
    encode: EncodeSettings,
    resolution: Tuple[int, int],
    fps: int,
    audio_path: Optional[str],
    ffmpeg_threads: int,
) -> List[str]:
    w, h = resolution
    cmd = [
        "ffmpeg", "-y",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}",
        "-r", str(fps),
        "-i", "pipe:0",
    ]
    if audio_path:
        cmd += ["-i", audio_path]
    cmd += ["-c:v", encode.codec]
    if encode.preset is not None:
        cmd += ["-preset", encode.preset]
    cmd += list(encode.ffmpeg_params)
    if audio_path:
        cmd += ["-c:a", "aac", "-b:a", "192k", "-shortest"]
    else:
        cmd += ["-an"]
    cmd += ["-threads", str(max(1, ffmpeg_threads)), out_path]
    return cmd


# Registry of live ffmpeg Popen handles so cancel can kill them.
_active_encodes: List[subprocess.Popen] = []
_active_lock = threading.Lock()


def encode_frames_to_file(
    frames: Iterator[np.ndarray],
    out_path: str,
    encode: EncodeSettings,
    resolution: Tuple[int, int],
    fps: int,
    audio_path: Optional[str] = None,
    ffmpeg_threads: int = 2,
    total_frames: Optional[int] = None,
    on_frame: Optional[Callable[[int, int], None]] = None,
    cancel_event: Optional[Event] = None,
) -> None:
    """
    Pipe RGB24 frames into ffmpeg and mux optional audio. Raises CancelledError
    if cancel_event is set; kills the ffmpeg child in that case.
    """
    cmd = _build_ffmpeg_cmd(out_path, encode, resolution, fps, audio_path, ffmpeg_threads)
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as e:
        raise RuntimeError("ffmpeg not found on PATH") from e

    with _active_lock:
        _active_encodes.append(proc)

    frame_idx = 0
    total = total_frames or 0
    try:
        assert proc.stdin is not None
        for frame in frames:
            check_cancelled(cancel_event)
            if frame.dtype != np.uint8:
                frame = frame.astype(np.uint8)
            if not frame.flags["C_CONTIGUOUS"]:
                frame = np.ascontiguousarray(frame)
            try:
                proc.stdin.write(frame.tobytes())
            except BrokenPipeError as e:
                err = (proc.stderr.read() if proc.stderr else b"").decode("utf-8", errors="ignore")
                raise RuntimeError(f"ffmpeg encode failed: {err.strip() or e}") from e
            frame_idx += 1
            if on_frame is not None:
                on_frame(frame_idx, total if total else frame_idx)
        proc.stdin.close()
        stderr_data = proc.stderr.read() if proc.stderr else b""
        rc = proc.wait(timeout=600)
        if rc != 0:
            err = stderr_data.decode("utf-8", errors="ignore").strip()
            raise RuntimeError(f"ffmpeg exited {rc}: {err[-2000:]}")
    except CancelledError:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
        raise
    finally:
        with _active_lock:
            if proc in _active_encodes:
                _active_encodes.remove(proc)
        if proc.stdin and not proc.stdin.closed:
            try:
                proc.stdin.close()
            except Exception:
                pass


def kill_active_encodes() -> None:
    """Best-effort kill of in-flight ffmpeg encode processes (used on cancel)."""
    with _active_lock:
        procs = list(_active_encodes)
    for proc in procs:
        try:
            proc.kill()
        except Exception:
            pass
