"""The program's own recording of the cameras, for «🎬 Мои удары».

Some cameras do not give their memory-card archive to a program (Dahua's basic
series answers 403 to RTSP playback), while the live picture always works. So
the program keeps the last hours of the live picture itself: one ffmpeg per
camera copies the stream into pieces of a minute (no re-encoding, so the
computer hardly notices), the pieces are named by the clock time they start,
and a client's moment is cut out of them. Old pieces are deleted.
"""
from __future__ import annotations

import logging
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from .archive import MAX_BYTES, VIDEO_FILTER, _hide_password, ffmpeg_exe

log = logging.getLogger("velora_vision.record")

SEGMENT_SECONDS = 60
NAME_FORMAT = "%Y%m%d_%H%M%S"
NAME_RE = re.compile(r"^(\d{8}_\d{6})\.ts$")
RESTART_AFTER = 5.0


def safe_name(text: str) -> str:
    return "".join(c if c.isalnum() else "_" for c in text) or "table"


def record_url(live_url: str, quality: str = "light") -> str:
    """The address to record: Dahua's light stream (`subtype=1`) by default, the
    main one (`subtype=0`) if asked. Other addresses are recorded as they are."""
    parts = urlsplit(live_url)
    if not parts.path.lower().rstrip("/").endswith("/cam/realmonitor"):
        return live_url
    wanted = "0" if quality == "main" else "1"
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "subtype"]
    query.append(("subtype", wanted))
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query, safe="/"), ""))


def _no_window() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0


def segment_command(exe: str, source: str, folder: Path) -> list[str]:
    """ffmpeg that copies the stream into pieces named by their start time."""
    cmd = [exe, "-hide_banner", "-loglevel", "warning"]
    if source.lower().startswith(("rtsp://", "rtsps://")):
        cmd += ["-rtsp_transport", "tcp"]
    cmd += [
        "-i", source, "-map", "0:v:0", "-c", "copy", "-an",
        "-f", "segment", "-segment_time", str(SEGMENT_SECONDS), "-segment_atclocktime", "1",
        "-segment_format", "mpegts", "-reset_timestamps", "1", "-strftime", "1",
        str(folder / f"{NAME_FORMAT}.ts"),
    ]
    return cmd


class CameraRecorder(threading.Thread):
    """Keeps one ffmpeg running for a camera; starts it again if it stops."""

    def __init__(self, table: str, source: str, folder: Path, stop: threading.Event,
                 popen: Callable = subprocess.Popen, exe: Optional[str] = None,
                 restart_after: float = RESTART_AFTER):
        super().__init__(name=f"record-{table}", daemon=True)
        self.table, self.source, self.folder = table, source, folder
        self._stop_event = stop
        self.popen = popen
        self.exe = exe
        self.restart_after = restart_after
        self.starts = 0
        self._warned = False

    def run(self) -> None:
        exe = self.exe or ffmpeg_exe()
        if not exe:
            log.error("Запись на компьютере: нет видеокодера (ffmpeg)")
            return
        self.folder.mkdir(parents=True, exist_ok=True)
        while not self._stop_event.is_set():
            proc = None
            try:
                proc = self.popen(segment_command(exe, self.source, self.folder),
                                  stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.PIPE, creationflags=_no_window())
                self.starts += 1
                if self.starts == 1:
                    log.info("Запись на компьютере: стол «%s» пишется", self.table)
                while proc.poll() is None and not self._stop_event.is_set():
                    self._stop_event.wait(1)
            except OSError as e:
                log.warning("Запись на компьютере: не запустился видеокодер (%s)", e)
            finally:
                if proc is not None:
                    self._finish(proc)
            if self._stop_event.is_set():
                return
            if not self._warned:
                self._warned = True
                log.warning("Запись на компьютере: поток стола «%s» прервался, подключаюсь снова",
                            self.table)
            self._stop_event.wait(self.restart_after)

    def _finish(self, proc) -> None:
        try:
            if proc.poll() is None:
                try:
                    proc.stdin.write(b"q")  # lets ffmpeg close the last piece properly
                    proc.stdin.flush()
                except Exception:
                    pass
                try:
                    proc.wait(timeout=5)
                except Exception:
                    proc.terminate()
            if self._stop_event.is_set():
                return
            tail = b""
            try:
                tail = (proc.stderr.read() or b"")[-300:]
            except Exception:
                pass
            if tail:
                log.warning("Запись на компьютере: %s",
                            _hide_password(tail.decode("utf-8", "replace"), self.source))
        except Exception:
            pass


# -- pieces on the disk ----------------------------------------------------
def list_segments(folder: Path) -> list[tuple[datetime, Path]]:
    """(start as the computer's clock showed it, file), oldest first."""
    out = []
    try:
        for f in folder.iterdir():
            m = NAME_RE.match(f.name)
            if m:
                out.append((datetime.strptime(m.group(1), NAME_FORMAT), f))
    except OSError:
        return []
    return sorted(out)


def segments_for(folder: Path, start: datetime, end: datetime) -> list[tuple[datetime, Path]]:
    """The pieces that hold any of [start, end] (naive computer-clock times)."""
    span = timedelta(seconds=SEGMENT_SECONDS + 2)  # a piece may run a little over
    return [(s, f) for s, f in list_segments(folder) if s <= end and s + span > start]


def clean_old(folder: Path, keep_hours: float, now: Optional[datetime] = None) -> int:
    """Deletes pieces older than `keep_hours`. Returns how many went."""
    now = now or datetime.now()
    limit = now - timedelta(hours=keep_hours)
    gone = 0
    for s, f in list_segments(folder):
        if s < limit:
            try:
                f.unlink()
                gone += 1
            except OSError:
                pass
    return gone


def folder_size(folder: Path) -> int:
    try:
        return sum(f.stat().st_size for f in folder.rglob("*.ts"))
    except OSError:
        return 0


def local_naive(moment: datetime, tz: Optional[tzinfo] = None) -> datetime:
    """A moment as the computer's own clock (the one that named the pieces) showed it."""
    return moment.astimezone(tz).replace(tzinfo=None) if tz else moment.astimezone().replace(tzinfo=None)


def concat_list(files: list[Path]) -> str:
    """The list ffmpeg's concat reads. Forward slashes also on Windows (a
    backslash is an escape character there), a quote in a name is escaped."""
    return "".join(f"file '{f.as_posix().replace(chr(39), chr(39) + chr(92) + chr(39) + chr(39))}'\n"
                   for f in files)


def cut_local(
    folder: Path, moment: datetime, before: float, after: float, out: Path,
    run: Callable = subprocess.run, exe: Optional[str] = None, tz: Optional[tzinfo] = None,
) -> Optional[str]:
    """Cuts [moment-before, moment+after] out of the pieces. None when done,
    else a short reason ("NO_LOCAL": nothing was recorded for that time)."""
    exe = exe or ffmpeg_exe()
    if not exe:
        return "NO_FFMPEG"
    t0 = local_naive(moment, tz) - timedelta(seconds=before)
    t1 = local_naive(moment, tz) + timedelta(seconds=after)
    pieces = segments_for(folder, t0, t1)
    if not pieces:
        return "NO_LOCAL"
    first_start = pieces[0][0]
    offset = max(0.0, (t0 - first_start).total_seconds())
    listing = Path(tempfile.mkdtemp(prefix="vv_cut_")) / "list.txt"
    try:
        listing.write_text(concat_list([f for _, f in pieces]), encoding="utf-8")
        cmd = [exe, "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
               "-i", str(listing), "-ss", f"{offset:.2f}", "-t", f"{before + after:g}", "-an",
               "-vf", VIDEO_FILTER,
               "-c:v", "libx264", "-preset", "veryfast", "-crf", "27",
               "-movflags", "+faststart", str(out)]
        try:
            proc = run(cmd, capture_output=True, timeout=(before + after) * 4 + 60,
                       creationflags=_no_window())
        except subprocess.TimeoutExpired:
            return "TIMEOUT"
        except OSError:
            return "FFMPEG_START"
        if proc.returncode != 0:
            log.warning("Запись на компьютере: не удалось вырезать: %s",
                        (proc.stderr or b"").decode("utf-8", "replace")[-200:])
            return "NO_LOCAL"
        if not out.exists() or out.stat().st_size < 1000:
            return "EMPTY"
        if out.stat().st_size > MAX_BYTES:
            return "TOO_BIG"
        return None
    finally:
        shutil.rmtree(listing.parent, ignore_errors=True)


class LocalRecording:
    """All cameras' recorders of the program and the cleaning of old pieces."""

    def __init__(self, sources: dict[str, str], root: Path, stop: threading.Event,
                 keep_hours: float = 36, quality: str = "light",
                 recorder_factory=CameraRecorder, clean_every: float = 600):
        self.root = root
        self.keep_hours = keep_hours
        self.stop = stop
        self.clean_every = clean_every
        self.folders = {t: root / safe_name(t) for t in sources}
        self.recorders = [
            recorder_factory(t, record_url(url, quality), self.folders[t], stop)
            for t, url in sources.items()
        ]
        self._cleaner = threading.Thread(target=self._clean_loop, name="record-clean", daemon=True)

    def start(self) -> None:
        for r in self.recorders:
            r.start()
        self._cleaner.start()

    def _clean_loop(self) -> None:
        while not self.stop.is_set():
            for folder in self.folders.values():
                try:
                    clean_old(folder, self.keep_hours)
                except Exception:
                    log.exception("Запись на компьютере: не удалось почистить старое")
            self.stop.wait(self.clean_every)

    def cut(self, table: str, moment: datetime, before: float, after: float, out: Path) -> Optional[str]:
        folder = self.folders.get(table)
        return cut_local(folder, moment, before, after, out) if folder else "NO_LOCAL"

    def size_bytes(self) -> int:
        return sum(folder_size(f) for f in self.folders.values())
