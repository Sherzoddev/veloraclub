"""Turns the buffered pictures into an MP4 that Telegram plays right in the
channel (H.264). Uses the ffmpeg that comes with the program."""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

import cv2
import numpy as np

log = logging.getLogger("velora_vision.clips")


def ffmpeg_exe() -> Optional[str]:
    override = os.environ.get("VELORA_FFMPEG")
    if override and Path(override).exists():
        return override
    try:
        import imageio_ffmpeg

        exe = imageio_ffmpeg.get_ffmpeg_exe()
        if exe and Path(exe).exists():
            return exe
    except Exception:
        pass
    return shutil.which("ffmpeg")


def _no_window() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0


def encode_mp4(frames: list[bytes], fps: float, out: Path) -> bool:
    """frames are JPEG bytes. Returns True if `out` now holds a playable MP4."""
    if not frames:
        return False
    exe = ffmpeg_exe()
    if exe:
        cmd = [
            exe, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "image2pipe", "-framerate", f"{fps:g}", "-vcodec", "mjpeg", "-i", "-",
            # JPEG pictures are full-range; players expect the usual limited
            # range, or the colours look washed out. Even sides for H.264.
            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2:in_range=pc:out_range=tv,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "27",
            "-color_range", "tv", "-movflags", "+faststart", "-an", str(out),
        ]
        try:
            proc = subprocess.run(
                cmd, input=b"".join(frames), capture_output=True, timeout=120,
                creationflags=_no_window(),
            )
            if proc.returncode == 0 and out.exists() and out.stat().st_size > 0:
                return True
            log.warning("ffmpeg не справился: %s", proc.stderr.decode("utf-8", "replace")[-300:])
        except (OSError, subprocess.TimeoutExpired) as e:
            log.warning("ffmpeg не запустился: %s", e)
    else:
        log.warning("ffmpeg не найден, пишу запасным способом (может не играть в Telegram)")
    return _encode_cv2(frames, fps, out)


def _encode_cv2(frames: list[bytes], fps: float, out: Path) -> bool:
    first = cv2.imdecode(np.frombuffer(frames[0], np.uint8), cv2.IMREAD_COLOR)
    if first is None:
        return False
    h, w = first.shape[:2]
    writer = cv2.VideoWriter(str(out), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    if not writer.isOpened():
        return False
    try:
        for jpg in frames:
            img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
            if img is not None:
                writer.write(img)
    finally:
        writer.release()
    return out.exists() and out.stat().st_size > 0


def frame_size(jpeg: bytes) -> tuple[int, int]:
    img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return 0, 0
    h, w = img.shape[:2]
    return w, h
