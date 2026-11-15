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
            if _delete(f):
                gone += 1
    return gone


_warned_delete: set[str] = set()


def _delete(f: Path) -> bool:
    try:
        f.unlink()
        return True
    except FileNotFoundError:
        return True
    except OSError as e:
        # Said once per file: a piece that Windows will not let go of (an
        # antivirus, a player) must not stay unnoticed.
        if f.name not in _warned_delete:
            _warned_delete.add(f.name)
            log.warning("Запись на компьютере: не удалось удалить %s (%s)", f.name, e.strerror or e)
        return False


MIN_FREE_BYTES = 3 * 1024**3  # below this the oldest pieces go whatever their age


def all_pieces(root: Path) -> list[tuple[datetime, Path]]:
    """Every piece under `root`, in every table's folder -- also folders of
    tables that were renamed or removed long ago -- oldest first."""
    out: list[tuple[datetime, Path]] = []
    try:
        folders = [root] + [d for d in root.iterdir() if d.is_dir()]
    except OSError:
        return []
    for folder in folders:
        out += list_segments(folder)
    return sorted(out)


def clean_all(
    root: Path, keep_hours: float, max_bytes: float, now: Optional[datetime] = None,
    free_bytes: Optional[Callable[[Path], int]] = None, protect_newest: int = 3,
) -> dict:
    """Keeps the disk from filling up with recordings:

    1. every piece older than `keep_hours` goes (in all folders under `root`);
    2. if the pieces still take more than `max_bytes`, the oldest go until they fit;
    3. if the disk has less than 3 GB free, the oldest go until there is room.

    The newest pieces of each folder are never taken by 2 and 3 (they are
    being written or may be asked for). Returns what was done."""
    now = now or datetime.now()
    free_of = free_bytes or (lambda p: shutil.disk_usage(p).free)
    removed = {"old": 0, "over_cap": 0, "low_disk": 0, "failed": 0}
    limit = now - timedelta(hours=keep_hours)
    pieces = all_pieces(root)
    for s, f in pieces:
        if s < limit:
            if _delete(f):
                removed["old"] += 1
            else:
                removed["failed"] += 1
    pieces = [(s, f) for s, f in all_pieces(root)]
    newest: set[Path] = set()
    by_folder: dict[Path, list[Path]] = {}
    for s, f in pieces:
        by_folder.setdefault(f.parent, []).append(f)
    for files in by_folder.values():
        newest.update(files[-protect_newest:])
    sizes = {}
    for s, f in pieces:
        try:
            sizes[f] = f.stat().st_size
        except OSError:
            sizes[f] = 0
    total = sum(sizes.values())
    for s, f in pieces:  # oldest first
        if f in newest:
            continue
        try:
            free = free_of(root)
        except OSError:
            free = MIN_FREE_BYTES
        over = total > max_bytes
        low = free < MIN_FREE_BYTES
        if not (over or low):
            break
        if _delete(f):
            total -= sizes.get(f, 0)
            removed["over_cap" if over else "low_disk"] += 1
        else:
            removed["failed"] += 1
    # a folder of a table nobody records any more, now empty
    try:
        for d in root.iterdir():
            if d.is_dir() and not any(d.iterdir()):
                d.rmdir()
    except OSError:
        pass
    return removed


def folder_size(folder: Path) -> int:
    try:
        return sum(f.stat().st_size for f in folder.rglob("*.ts"))
    except OSError:
        return 0


def root_size(root: Path) -> int:
    """All recordings under `root`, whichever table they belong to."""
    return folder_size(root)


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
        cmd = [exe, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "concat", "-safe", "0",
               "-i", str(listing), "-ss", f"{offset:.2f}", "-t", f"{before + after:g}", "-an",
               "-vf", VIDEO_FILTER,
               "-c:v", "libx264", "-preset", "veryfast", "-crf", "27",
               "-movflags", "+faststart", str(out)]
        try:
            proc = run(cmd, capture_output=True, stdin=subprocess.DEVNULL,
                       timeout=(before + after) * 6 + 120, creationflags=_no_window())
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
                 keep_hours: float = 24, quality: str = "light",
                 recorder_factory=CameraRecorder, clean_every: float = 300,
                 max_gb: float = 60):
        self.root = root
        self.keep_hours = keep_hours
        self.max_gb = max_gb
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

    def clean_now(self) -> dict:
        return clean_all(self.root, self.keep_hours, self.max_gb * 1024**3)

    def _clean_loop(self) -> None:
        while not self.stop.is_set():
            try:
                done = self.clean_now()
                if any(done[k] for k in ("old", "over_cap", "low_disk")):
                    log.info("Запись на компьютере: удалено старых кусков %d, сверх лимита %d, "
                             "из-за нехватки места %d", done["old"], done["over_cap"], done["low_disk"])
                if done["low_disk"]:
                    log.warning("На диске мало места (меньше 3 ГБ): удаляю самое старое. Выберите "
                                "другой диск или сократите срок хранения (вкладка «Настройки»).")
            except Exception:
                log.exception("Запись на компьютере: не удалось почистить старое")
            self.stop.wait(self.clean_every)

    def cut(self, table: str, moment: datetime, before: float, after: float, out: Path) -> Optional[str]:
        folder = self.folders.get(table)
        return cut_local(folder, moment, before, after, out) if folder else "NO_LOCAL"

    def size_bytes(self) -> int:
        return root_size(self.root)
