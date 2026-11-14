"""Cuts a moment out of the camera's own recording (Dahua / Imou / Amcrest).

The camera (or its recorder) keeps the video on its memory card; SmartPSS
reads it from there, and so can we: the same RTSP address as the live picture,
but `/cam/playback` with a start and an end time. Nothing is recorded by this
program.
"""
from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import parse_qs, quote, unquote, urlsplit, urlunsplit
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


def playback_urls(live_url: str, start: datetime, end: datetime, tz: str,
                  shift: timedelta = timedelta(0)) -> list[str]:
    """The playback addresses of the same camera for [start, end], the usual one
    first. Firmwares differ a little (some want no `subtype`, some keep the
    recording of the light stream), so a few spellings are tried in turn.

    `start` / `end` are timezone-aware; the camera shows the club's local
    time, so they are converted to the club's time zone first. Empty list if
    the address is not a Dahua one.
    """
    if not supports_playback(live_url):
        return []
    parts = urlsplit(live_url)
    query = parse_qs(parts.query)
    channel = (query.get("channel") or ["1"])[0]
    if not channel.isdigit():
        channel = "1"
    live_subtype = (query.get("subtype") or ["0"])[0]
    zone = ZoneInfo(tz)
    first = (start.astimezone(zone).replace(tzinfo=None) + shift).strftime(STAMP)
    last = (end.astimezone(zone).replace(tzinfo=None) + shift).strftime(STAMP)
    path = parts.path.rstrip("/")
    path = path[: -len("realmonitor")] + "playback"
    stamps = f"starttime={first}&endtime={last}"
    queries = [f"channel={channel}&subtype=0&{stamps}", f"channel={channel}&{stamps}"]
    if live_subtype.isdigit() and live_subtype != "0":
        queries.append(f"channel={channel}&subtype={live_subtype}&{stamps}")
    urls = [urlunsplit((parts.scheme, parts.netloc, path, q, "")) for q in queries]
    # The camera's web interface gives the same recording over HTTP: some
    # cameras refuse it over RTSP (403) but serve it here, like SmartPSS does.
    userinfo = parts.netloc.rpartition("@")[0]
    web = f"{userinfo}@{parts.hostname}" if userinfo else str(parts.hostname)
    web_first = (start.astimezone(zone).replace(tzinfo=None) + shift).strftime("%Y-%m-%d %H:%M:%S")
    web_last = (end.astimezone(zone).replace(tzinfo=None) + shift).strftime("%Y-%m-%d %H:%M:%S")
    urls.append(urlunsplit(("http", web, "/cgi-bin/playBack.cgi", quote(
        f"action=getStream&channel={channel}&subtype=0&startTime={web_first}&endTime={web_last}",
        safe="=&"), "")))
    return urls


def playback_url(live_url: str, start: datetime, end: datetime, tz: str,
                 shift: timedelta = timedelta(0)) -> Optional[str]:
    """The usual playback address of the camera, or None."""
    urls = playback_urls(live_url, start, end, tz, shift)
    return urls[0] if urls else None


# -- the camera's own clock -----------------------------------------------
# The recording is looked up by the camera's time. A camera left on UTC (or
# with a wrong date) would be asked for a moment that, for it, has not come yet
# and refuses (403), or would hand out the wrong moment.
_CLOCK = re.compile(r"result=(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})")


def camera_get(live_url: str, path: str, http=None, timeout: float = 6) -> Optional[str]:
    """Text of a page of the camera's web interface (Dahua CGI), or None. The
    login and password are the ones of the stream address."""
    import requests
    from requests.auth import HTTPBasicAuth, HTTPDigestAuth

    http = http or requests
    try:
        parts = urlsplit(live_url)
        host = parts.hostname
        user, password = unquote(parts.username or ""), unquote(parts.password or "")
    except ValueError:
        return None
    if not host:
        return None
    url = f"http://{host}{path}"
    for auth in (HTTPDigestAuth(user, password), HTTPBasicAuth(user, password)):
        try:
            resp = http.get(url, auth=auth, timeout=timeout)
        except requests.RequestException:
            return None
        if resp.status_code == 200 and (resp.text or "").strip():
            return resp.text
    return None


def camera_clock(live_url: str, http=None, timeout: float = 6) -> Optional[datetime]:
    """The time the camera shows (naive), asked over its web interface, or None."""
    text = camera_get(live_url, "/cgi-bin/global.cgi?action=getCurrentTime", http, timeout)
    m = _CLOCK.search(text or "")
    if not m:
        return None
    y, mo, d, h, mi, sec = map(int, m.groups())
    try:
        return datetime(y, mo, d, h, mi, sec)
    except ValueError:
        return None


def _pairs(text: str) -> dict[str, str]:
    return dict(line.strip().split("=", 1) for line in (text or "").splitlines() if "=" in line)


def camera_report(live_url: str, http=None) -> str:
    """One line for the person (and for me, reading a screenshot): the model
    and the memory card, as the camera itself tells."""
    parts = []
    info = _pairs(camera_get(live_url, "/cgi-bin/magicBox.cgi?action=getSystemInfo", http) or "")
    if info.get("deviceType"):
        parts.append(f"камера {info['deviceType']}")
    storage = camera_get(live_url, "/cgi-bin/storageDevice.cgi?action=getDeviceAllInfo", http)
    if storage is None:
        parts.append("карта памяти: камера не сказала")
    else:
        pairs = _pairs(storage)
        totals = [int(v) for k, v in pairs.items() if k.endswith(".TotalBytes") and v.isdigit()]
        if totals and sum(totals) > 0:
            parts.append(f"карта памяти: есть, {sum(totals) / 1e9:.0f} ГБ")
        else:
            parts.append("карты памяти в камере нет")
    return ", ".join(parts)


def clock_shift(live_url: str, tz: str, now: Optional[datetime] = None,
                http=None) -> Optional[timedelta]:
    """How far the camera's clock is ahead of the club's time (negative: behind).
    Zero when they agree within half a minute; None if the camera's time could
    not be read."""
    shown = camera_clock(live_url, http)
    if shown is None:
        return None
    now = now or datetime.now(timezone.utc)
    here = now.astimezone(ZoneInfo(tz)).replace(tzinfo=None)
    shift = shown - here
    return timedelta(0) if abs(shift) < timedelta(seconds=30) else timedelta(seconds=round(shift.total_seconds()))


def describe_shift(shift: timedelta) -> str:
    total = int(abs(shift.total_seconds()) // 60)
    hours, minutes = divmod(total, 60)
    span = (f"{hours} ч " if hours else "") + (f"{minutes} мин" if minutes or not hours else "")
    return f"{span.strip()} {'впереди' if shift > timedelta(0) else 'позади'}"


def cut_first_working(urls: list[str], seconds: float, out: Path,
                      cut: Callable = None) -> tuple[Optional[str], list[str]]:
    """Tries the addresses one by one until a clip comes out. Returns (None or
    the reason of the first address, the reasons of all that were tried)."""
    cut = cut or cut_clip
    reasons: list[str] = []
    for url in urls:
        why = cut(url, seconds, out)
        if why is None:
            return None, reasons
        reasons.append(why)
        if why in ("NO_FFMPEG", "FFMPEG_START", "TOO_BIG"):
            break  # another spelling will not help
    return (reasons[0] if reasons else "NO_RECORDING"), reasons


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
        # The address holds the camera password: never log it. It is cut out
        # of the whole text first, and only then the end is kept (cutting the
        # end first could leave half of a password in the log).
        text = _hide_password((proc.stderr or b"").decode("utf-8", "replace"), source)
        log.warning("ffmpeg не смог взять запись: %s", text[-300:])
        return _reason_of(text)
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
    # whatever is left in front of an "@" (a user or a password, even a cut
    # one, in any address ffmpeg prints)
    return re.sub(r"[^\s/@]+@", "***@", text)


def _reason_of(text: str) -> str:
    """What ffmpeg's last words mean for the person."""
    low = text.lower()
    if "403" in low or "forbidden" in low:
        return "FORBIDDEN"
    if "401" in low or "unauthorized" in low:
        return "UNAUTHORIZED"
    if "404" in low or "not found" in low:
        return "NOT_FOUND"
    if "refused" in low or "no route" in low or "timed out" in low or "unreachable" in low:
        return "CONNECT"
    return "NO_RECORDING"


# What the person is told when the test clip does not come out.
REASONS = {
    "NO_FFMPEG": "В программе нет видеокодера (ffmpeg). Скачайте программу заново.",
    "TIMEOUT": "Камера слишком долго не отдаёт запись. Проверьте сеть и что камера не занята.",
    "FORBIDDEN": "Камера отказала в доступе к записи (403). Чаще всего это значит, что сама "
                 "камера ничего не хранит: запись идёт на регистратор. Тогда в программе "
                 "укажите адрес регистратора и номер канала этой камеры. Или у этого пользователя нет "
                 "права «Воспроизведение»: впишите в программу тот же логин и пароль, "
                 "под которыми камера добавлена в SmartPSS Lite.",
    "UNAUTHORIZED": "Логин или пароль не подошли (401). Проверьте их, как для входа в камеру.",
    "NOT_FOUND": "Камера не нашла запись за это время (404): на ней нет карты памяти, запись "
                 "выключена, либо запись идёт на регистратор.",
    "CONNECT": "Не удаётся соединиться с камерой. Проверьте, что компьютер и камера в одной сети.",
    "NO_RECORDING": "Камера не отдала запись. Проверьте: в камере есть карта памяти и запись "
                    "включена; логин и пароль верные; камера Dahua (адрес записи у других "
                    "производителей другой).",
    "NO_LOCAL": "Записи за это время нет: программа записывает камеры только пока она запущена, "
                "и хранит запись ограниченное время.",
    "EMPTY": "Камера ответила, но видео пустое: за это время, похоже, нет записи.",
    "TOO_BIG": "Ролик получился слишком большим.",
    "FFMPEG_START": "Не удалось запустить видеокодер.",
}


def check_archive(
    live_url: str, tz: str, now: Optional[datetime] = None,
    cut: Callable = None, minutes_ago: float = 10, seconds: float = 4,
    shift_of: Callable = None, report_of: Callable = None,
) -> tuple[bool, str]:
    """Tries to take a few seconds from the camera's recording of a few minutes
    ago. Returns (worked, sentence for the person)."""
    if not supports_playback(live_url):
        return False, ("Адрес этой камеры не похож на Dahua: запись по времени для неё не "
                       "поддерживается.")
    now = now or datetime.now(timezone.utc)
    shift = (shift_of or clock_shift)(live_url, tz, now)
    note = ""
    if shift is None:
        note = "Время камеры узнать не удалось (проверка идёт по времени компьютера). "
    elif shift:
        note = (f"Часы камеры не совпадают с часами клуба: камера {describe_shift(shift)}. "
                "Программа это учтёт сама, но лучше выставить в камере верное время и пояс. ")
    start = now - timedelta(minutes=minutes_ago)
    urls = playback_urls(live_url, start, start + timedelta(seconds=seconds), tz, shift or timedelta(0))
    out = Path(tempfile.mkdtemp(prefix="vv_check_")) / "check.mp4"
    try:
        why, tried = cut_first_working(urls, seconds, out, cut)
        if why is None:
            kb = out.stat().st_size // 1024
            return True, note + f"✓ Запись камеры читается: взято {seconds:g} с видео ({kb} КБ)."
        text = note + REASONS.get(why, f"Не получилось ({why}).")
        if len(tried) > 1:
            text += f"\n\nПробовал {len(tried)} вариантов адреса записи, ответы: {', '.join(tried)}."
        try:
            about = (report_of or camera_report)(live_url)
        except Exception:
            about = ""
        if about:
            text += f"\n\nСам о себе камера сообщает: {about}."
        return False, text
    finally:
        shutil.rmtree(out.parent, ignore_errors=True)


def check_live(live_url: str, quality: str = "light", cut: Callable = None,
               seconds: float = 4) -> tuple[bool, str]:
    """Can the program record this camera? Takes a few seconds of the live
    picture the way the recording does and encodes them."""
    from .local_record import record_url

    cut = cut or cut_clip
    out = Path(tempfile.mkdtemp(prefix="vv_live_")) / "live.mp4"
    try:
        why = cut(record_url(live_url, quality), seconds, out)
        if why is None:
            return True, "живой поток читается"
        return False, REASONS.get(why, f"поток не читается ({why})")
    finally:
        shutil.rmtree(out.parent, ignore_errors=True)
