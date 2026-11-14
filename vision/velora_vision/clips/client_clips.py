"""«🎬 Мой удар»: клиент называет в боте стол и время, программа вырезает этот
момент из записи камеры, сервер отправляет ролик клиенту.

Раз в несколько секунд программа спрашивает у сервера, нет ли заявок на её
столы (заодно сообщает, какие столы умеет резать: так кнопка в боте
появляется сама и пропадает, если компьютер выключен). Файл существует
только пока режется и отправляется, потом удаляется.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

import requests

from .archive import (clip_window, clock_shift, cut_clip, cut_first_working, describe_shift,
                      playback_urls, supports_playback)

log = logging.getLogger("velora_vision.clips")

BEFORE = 12.0  # seconds shown before the named moment
AFTER = 18.0  # and after it
POLL_EVERY = 8.0


@dataclass(frozen=True)
class ClipRequest:
    id: str
    table: str
    moment: datetime  # timezone-aware


class ClipsError(Exception):
    pass


class ClipsClient:
    """Talks to the Supabase function vision-clips (same token as the rest)."""

    def __init__(self, supabase_url: str, bot_token: str, http=requests, timeout: float = 20):
        self.url = f"{supabase_url.rstrip('/')}/functions/v1/vision-clips"
        self.token = bot_token.strip()
        self.http = http
        self.timeout = timeout

    def _post(self, **kw):
        try:
            return self.http.post(self.url, timeout=kw.pop("timeout", self.timeout), **kw)
        except requests.RequestException as e:
            raise ClipsError(f"нет связи с сервером ({type(e).__name__})") from e

    def poll(self, tables: list[str]) -> tuple[list[ClipRequest], str]:
        """Open requests for these tables and the club's time zone."""
        import json

        resp = self._post(json={"bot_token": self.token, "action": "clips_poll",
                                "tables": json.dumps(tables, ensure_ascii=False)})
        try:
            data = resp.json()
        except ValueError:
            data = None
        if resp.status_code != 200 or not isinstance(data, dict):
            raise ClipsError(f"сервер ответил {resp.status_code}")
        out = []
        for r in data.get("requests") or []:
            try:
                moment = datetime.fromisoformat(str(r["moment"]).replace("Z", "+00:00"))
                if moment.tzinfo is None:
                    moment = moment.replace(tzinfo=timezone.utc)
                out.append(ClipRequest(str(r["id"]), str(r.get("table") or ""), moment))
            except (KeyError, ValueError):
                continue
        return out, str(data.get("timezone") or "Asia/Tashkent")

    def done(self, request_id: str, path: Path) -> bool:
        with open(path, "rb") as f:
            resp = self._post(
                data={"bot_token": self.token, "action": "clip_done", "request_id": request_id},
                files={"file": ("clip.mp4", f, "video/mp4")}, timeout=180,
            )
        try:
            return resp.status_code == 200 and bool(resp.json().get("ok"))
        except ValueError:
            return False

    def fail(self, request_id: str, reason: str) -> None:
        try:
            self._post(json={"bot_token": self.token, "action": "clip_fail",
                             "request_id": request_id, "reason": reason})
        except ClipsError as e:
            log.warning("Не удалось сообщить серверу об ошибке ролика: %s", e)


def table_sources(cameras) -> dict[str, str]:
    """table name -> live address of the camera that can be cut (Dahua only).

    `cameras` are CameraSettings; a camera without a table is skipped and the
    first suitable camera of a table wins.
    """
    out: dict[str, str] = {}
    for cam in cameras:
        table = cam.table.strip()
        if table and "://" in cam.url and supports_playback(cam.url):
            out.setdefault(table, cam.url)
    return out


class ClipRequestWorker(threading.Thread):
    def __init__(self, client: ClipsClient, sources: dict[str, str], tmp_dir: Path,
                 stop: threading.Event, cut: Callable = cut_clip,
                 poll_every: float = POLL_EVERY, shift_of: Callable = clock_shift,
                 local=None):
        super().__init__(name="client-clips", daemon=True)
        self.client = client
        self.sources = sources
        self.tmp_dir = tmp_dir
        self._stop_event = stop
        self.cut = cut
        self.poll_every = poll_every
        self.shift_of = shift_of
        self.local = local  # the program's own recording (LocalRecording) or None
        self._shifts: dict[str, tuple[float, timedelta]] = {}  # camera -> (asked at, shift)
        self.sent = 0
        self.failed = 0
        self._warned = False

    def run(self) -> None:
        log.info("«Мой удар» включён, столов: %d", len(self.sources))
        while not self._stop_event.is_set():
            try:
                self.step()
            except Exception:  # one bad request must not stop the loop
                log.exception("Ошибка в «Мой удар», продолжаю")
            self._stop_event.wait(self.poll_every)

    def step(self) -> int:
        """One round: ask, cut what was asked. Returns how many were handled."""
        try:
            requests_, tz = self.client.poll(list(self.sources))
            self._warned = False
        except ClipsError as e:
            if not self._warned:
                log.warning("«Мой удар»: %s", e)
                self._warned = True
            return 0
        for req in requests_:
            self.handle(req, tz)
        return len(requests_)

    def _shift(self, source: str, tz: str) -> timedelta:
        """The camera's clock against the club's, asked at most every 10 minutes."""
        hit = self._shifts.get(source)
        if hit and time.time() - hit[0] < 600:
            return hit[1]
        try:
            shift = self.shift_of(source, tz)
        except Exception:  # never let a clock question stop a clip
            shift = None
        if shift is None:
            return hit[1] if hit else timedelta(0)
        if shift and (not hit or hit[1] != shift):
            log.warning("Часы камеры не совпадают с часами клуба: камера %s. Это учтено.",
                        describe_shift(shift))
        self._shifts[source] = (time.time(), shift)
        return shift

    def _make_clip(self, req: ClipRequest, tz: str, out: Path) -> Optional[str]:
        """Cuts the clip into `out`: from the program's own recording if it
        holds that time, else from the camera's archive. None when done, else
        the reason."""
        local_why = None
        if self.local is not None:
            local_why = self.local.cut(req.table, req.moment, BEFORE, AFTER, out)
            if local_why is None:
                return None
        source = self.sources.get(req.table)
        shift = self._shift(source, tz) if source else timedelta(0)
        urls = playback_urls(source, *clip_window(req.moment, BEFORE, AFTER), tz, shift) if source else []
        if not urls:
            return local_why or "NO_CAMERA"
        why, _ = cut_first_working(urls, BEFORE + AFTER, out, self.cut)
        # Told to the person: the camera's own refusal says less than "we have
        # no recording of that time", which is what a recording of ours means.
        return None if why is None else (local_why if local_why == "NO_LOCAL" else why)

    def handle(self, req: ClipRequest, tz: str) -> bool:
        if req.table not in self.sources:
            self.failed += 1
            self.client.fail(req.id, "NO_CAMERA")
            return False
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        out = self.tmp_dir / f"clip_ask_{req.id[:8]}.mp4"
        try:
            why = self._make_clip(req, tz, out)
            if why is not None:
                self.failed += 1
                log.warning("Ролик по заявке не получился (%s, %s)", req.table, why)
                self.client.fail(req.id, why)
                return False
            try:
                uploaded = self.client.done(req.id, out)
            except ClipsError as e:
                log.warning("Не удалось передать ролик серверу: %s", e)
                uploaded = False
            if not uploaded:
                self.failed += 1
                log.warning("Сервер не принял ролик (%s)", req.table)
                self.client.fail(req.id, "UPLOAD")
                return False
            self.sent += 1
            log.info("Ролик по заявке отправлен клиенту (%s)", req.table)
            return True
        finally:
            try:
                out.unlink(missing_ok=True)  # always, whatever happened
            except OSError:
                log.warning("Не удалось удалить временный файл %s", out.name)
