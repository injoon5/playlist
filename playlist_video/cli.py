"""Headless command-line interface (and the marquee smoke test).

Run with no arguments to use the defaults in playlist_video.config.
"""

import argparse
import os
import sys
import tempfile

from . import config as defaults
from .encoding import encode_frames_to_file, resolve_encode_settings
from .fonts import try_download_pretendard
from .frames import build_track_renderer
from .models import PipelineConfig, Track
from .pipeline import parse_resolution, run_pipeline
from .transitions import iter_faded_frames


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a YouTube playlist video from an Apple Music playlist."
    )
    parser.add_argument("playlist_url", nargs="?", help="Apple Music playlist URL")
    parser.add_argument("--output", default="output/playlist_video.mp4", help="Output video file")
    parser.add_argument("--background-image", nargs="+", default=None)
    parser.add_argument("--resolution", default="1920x1080")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--no-shuffle", action="store_true")
    parser.add_argument("--shuffle", action="store_true", help="Shuffle track order")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--tracks-json", default=None)
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--font-dir", default=None)
    parser.add_argument(
        "--fast-scrape",
        action="store_true",
        help="Try the fast HTML scrape first instead of Chromium (default is Playwright/Chromium)",
    )
    parser.add_argument(
        "--force-browser-scrape",
        action="store_true",
        help=argparse.SUPPRESS,  # legacy no-op; Chromium is already the default
    )
    parser.add_argument("--transition-duration", type=float, default=0.6)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--render-workers", type=int, default=None)
    parser.add_argument("--gpu", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--preset", default=None)
    parser.add_argument("--crf", type=int, default=None)
    parser.add_argument("--test-marquee", action="store_true")
    parser.add_argument("--test-marquee-text",
                        default="This Is A Very Long Song Title That Should Definitely Scroll")
    parser.add_argument("--test-marquee-artist", default="A Fairly Long Test Artist Name")
    parser.add_argument("--test-marquee-album", default="An Equally Long Test Album Title")
    parser.add_argument("--test-marquee-duration", type=float, default=12.0)
    parser.add_argument("--test-marquee-resolution", default="960x540")
    parser.add_argument("--test-marquee-output", default="marquee_test.mp4")
    return parser


def config_from_args(args) -> PipelineConfig:
    if args.shuffle:
        shuffle = True
    elif args.no_shuffle:
        shuffle = False
    else:
        shuffle = defaults.SHUFFLE
    return PipelineConfig(
        playlist_url=args.playlist_url,
        output=args.output,
        resolution=args.resolution,
        fps=args.fps,
        limit=args.limit,
        background_images=args.background_image,
        shuffle=shuffle,
        workers=args.workers,
        render_workers=args.render_workers,
        gpu=args.gpu,
        transition_duration=args.transition_duration,
        tracks_json=args.tracks_json,
        workdir=args.workdir,
        font_dir=args.font_dir,
        force_browser_scrape=not args.fast_scrape,
        preset=args.preset,
        crf=args.crf,
        quiet=False,
    )


def _write_silence_wav(path: str, duration: float, sample_rate: int = 44100) -> None:
    import wave
    n_frames = max(1, int(duration * sample_rate))
    with wave.open(path, "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00\x00" * n_frames)


def run_marquee_test(args) -> None:
    resolution = parse_resolution(args.test_marquee_resolution)
    duration = args.test_marquee_duration
    workdir = tempfile.mkdtemp(prefix="amp_marquee_test_")
    font_dir = args.font_dir or try_download_pretendard(os.path.join(workdir, "fonts"))
    silent_wav = os.path.join(workdir, "silence.wav")
    _write_silence_wav(silent_wav, duration)
    track = Track(
        title=args.test_marquee_text,
        artist=args.test_marquee_artist,
        album=args.test_marquee_album,
        index=1, total=1,
    )
    track.audio_path = silent_wav
    track.artwork_path = None
    print(f"Rendering marquee test: {resolution[0]}x{resolution[1]} @ {args.fps}fps, "
          f"{duration}s -> {args.test_marquee_output}")
    make_frame, _audio_duration = build_track_renderer(track, resolution, None, font_dir)
    # Use requested test duration (silence wav length) for frame count.
    encode = resolve_encode_settings(args.gpu, args.preset, args.crf, resolution, args.fps)
    total_frames = max(1, int(round(duration * args.fps)))

    def frames():
        for frame, _t, _i in iter_faded_frames(make_frame, duration, args.fps, 0.0):
            yield frame

    encode_frames_to_file(
        frames(),
        args.test_marquee_output,
        encode,
        resolution=resolution,
        fps=args.fps,
        audio_path=None,
        ffmpeg_threads=os.cpu_count() or 2,
        total_frames=total_frames,
    )
    print("Done:", args.test_marquee_output)


def _argv_from_config():
    """CLI argv equivalent of the defaults in playlist_video.config, used when
    the script is invoked with no arguments at all."""
    argv = [
        defaults.PLAYLIST_URL,
        "--output", defaults.OUTPUT,
        "--resolution", defaults.RESOLUTION,
        "--fps", str(defaults.FPS),
        "--workers", str(defaults.WORKERS),
        "--gpu", defaults.GPU,
        *(["--render-workers", str(defaults.RENDER_WORKERS)] if defaults.RENDER_WORKERS else []),
        "--transition-duration", str(defaults.TRANSITION_DURATION),
    ]
    if defaults.LIMIT is not None:
        argv += ["--limit", str(defaults.LIMIT)]
    if defaults.BACKGROUND_IMAGE:
        images = (
            [defaults.BACKGROUND_IMAGE]
            if isinstance(defaults.BACKGROUND_IMAGE, str)
            else list(defaults.BACKGROUND_IMAGE)
        )
        argv += ["--background-image", *images]
    if defaults.SHUFFLE:
        argv += ["--shuffle"]
    else:
        argv += ["--no-shuffle"]
    return argv


def main(argv=None) -> None:
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        argv = _argv_from_config()
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    if args.test_marquee:
        run_marquee_test(args)
        return
    if not args.playlist_url and not args.tracks_json:
        parser.error("Provide a playlist_url or --tracks-json")
    try:
        run_pipeline(config_from_args(args))
    except (FileNotFoundError, ValueError, RuntimeError) as e:
        print(f"! {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n! Cancelled")
        sys.exit(130)


if __name__ == "__main__":
    main()
