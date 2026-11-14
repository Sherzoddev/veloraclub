"""Cuts a moment out of the camera's own recording (Dahua / Imou / Amcrest).

The camera (or its recorder) keeps the video on its memory card; SmartPSS
reads it from there, and so can we: the same RTSP address as the live picture,
but `/cam/playback` with a start and an end time. Nothing is recorded by this
program.
"""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import parse_qs, urlsplit, urlunsplit
from zoneinfo import ZoneInfo

log = logging.getLogger("velora_vision.clips")

STAMP = "%Y_%m_%d_%H_%M_%S"
MAX_BYTES = 45 * 1024 * 1024  # what the server can pass on to Telegram


def ffmpeg_exe() -> Optional[str]:
    """The ffmpeg that comes with the program (or the one on the computer)."""
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


def supports_playback(live_url: str) -> bool:
    """Only Dahua-style addresses (`/cam/realmonitor`) have the playback twin."""
    try:
        parts = urlsplit(live_url)
    except ValueError:
        return False
    return parts.scheme in ("rtsp", "rtsps") and parts.path.rstrip("/").lower().endswith("/cam/realmonitor")


def playback_url(live_url: str, start: datetime, end: datetime, tz: str) -> Optional[str]:
    """The playback address of the same camera for [start, end], or None.

    `start` / `end` are timezone-aware; the camera shows the club's local
    time, so they are converted to the club's time zone first.
    """
    if not supports_playback(live_url):
        return None
    parts = urlsplit(live_url)
    channel = (parse_qs(parts.query).get("channel") or ["1"])[0]
    if not channel.isdigit():
        channel = "1"
    zone = ZoneInfo(tz)
    first = start.astimezone(zone).strftime(STAMP)
    last = end.astimezone(zone).strftime(STAMP)
    path = parts.path.rstrip("/")
    path = path[: -len("realmonitor")] + "playback"
    query = f"channel={channel}&subtype=0&starttime={first}&endtime={last}"
    return urlunsplit((parts.scheme, parts.netloc, path, query, ""))


def clip_window(moment: datetime, before: float, after: float) -> tuple[datetime, datetime]:
    return moment - timedelta(seconds=before), moment + timedelta(seconds=after)


def _no_window() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0


def cut_command(exe: str, source: str, seconds: float, out: Path) -> list[str]:
    """ffmpeg reads the playback stream and writes a small H.264 file that
    plays inside Telegram (the camera may send H.265)."""
    cmd = [exe, "-hide_banner", "-loglevel", "error", "-y"]
    if source.lower().startswith(("rtsp://", "rtsps://")):
        cmd += ["-rtsp_transport", "tcp"]
    cmd += [
        "-i", source, "-t", f"{seconds:g}", "-an",
        "-vf", "scale=-2:'min(720,ih)',format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "27",
        "-movflags", "+faststart", str(out),
    ]
    return cmd


def cut_clip(
    source: str, seconds: float, out: Path,
    run: Callable = subprocess.run, exe: Optional[str] = None,
) -> Optional[str]:
    """Writes the clip; returns None when done, else a short reason."""
    exe = exe or ffmpeg_exe()
    if not exe:
        return "NO_FFMPEG"
    try:
        # Playback runs about as fast as the video is long, so allow for it.
        proc = run(cut_command(exe, source, seconds, out), capture_output=True,
                   timeout=seconds * 3 + 90, creationflags=_no_window())
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    except OSError:
        return "FFMPEG_START"
    if proc.returncode != 0:
        # The address holds the camera password: never log it, only ffmpeg's
        # last words with the password cut out.
        tail = (proc.stderr or b"").decode("utf-8", "replace")[-200:]
        log.warning("ffmpeg не смог взять запись: %s", _hide_password(tail, source))
        return "NO_RECORDING"
    if not out.exists() or out.stat().st_size < 1000:
        return "EMPTY"
    if out.stat().st_size > MAX_BYTES:
        return "TOO_BIG"
    return None


def _hide_password(text: str, source: str) -> str:
    try:
        parts = urlsplit(source)
        for secret in {parts.password, parts.username}:
            if secret:
                text = text.replace(secret, "***")
    except ValueError:
        pass
    return text


# What the person is told when the test clip does not come out.
REASONS = {
    "NO_FFMPEG": "В программе нет видеокодера (ffmpeg). Скачайте программу заново.",
    "TIMEOUT": "Камера слишком долго не отдаёт запись. Проверьте сеть и что камера не занята.",
    "NO_RECORDING": "Камера не отдала запись. Проверьте: в камере есть карта памяти и запись "
                    "включена; логин и пароль верные; камера Dahua (адрес записи у других "
                    "производителей другой).",
    "EMPTY": "Камера ответила, но видео пустое: за это время, похоже, нет записи.",
    "TOO_BIG": "Ролик получился слишком большим.",
    "FFMPEG_START": "Не удалось запустить видеокодер.",
}


def check_archive(
    live_url: str, tz: str, now: Optional[datetime] = None,
    cut: Callable = None, minutes_ago: float = 10, seconds: float = 4,
) -> tuple[bool, str]:
    """Tries to take a few seconds from the camera's recording of a few minutes
    ago. Returns (worked, sentence for the person)."""
    cut = cut or cut_clip
    if not supports_playback(live_url):
        return False, ("Адрес этой камеры не похож на Dahua: запись по времени для неё не "
                       "поддерживается.")
    now = now or datetime.now(timezone.utc)
    start = now - timedelta(minutes=minutes_ago)
    url = playback_url(live_url, start, start + timedelta(seconds=seconds), tz)
    out = Path(tempfile.mkdtemp(prefix="vv_check_")) / "check.mp4"
    try:
        why = cut(url, seconds, out)
        if why is None:
            kb = out.stat().st_size // 1024
            return True, f"✓ Запись камеры читается: взято {seconds:g} с видео ({kb} КБ)."
        return False, REASONS.get(why, f"Не получилось ({why}).")
    finally:
        shutil.rmtree(out.parent, ignore_errors=True)
