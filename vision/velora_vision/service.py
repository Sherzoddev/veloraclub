"""The main loop: look at the cameras, count people at each table, compare
with the sessions in the program and send a message when they disagree."""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional, Protocol
from zoneinfo import ZoneInfo

from . import messages
from .config import CameraCfg, Config
from .geometry import box_anchor, point_in_polygon
from .sessions import ResourceState, SessionsClient, SessionsError, match_resource
from .snapshot import render_snapshot
from .tracker import UNKNOWN, Event, TableTracker

log = logging.getLogger("velora_vision")


class Notifier(Protocol):
    def notify(self, text: str, jpeg: Optional[bytes] = None) -> None: ...


class PrintNotifier:
    """--dry-run: show what would be sent."""

    def notify(self, text: str, jpeg: Optional[bytes] = None) -> None:
        log.info("[сообщение%s] %s", " + фото" if jpeg else "", text)


class TelegramNotifier:
    def __init__(self, telegram):
        self.telegram = telegram

    def notify(self, text: str, jpeg: Optional[bytes] = None) -> None:
        if jpeg:
            if self.telegram.send_photo(jpeg, text):
                return
        self.telegram.send_message(text)


def count_people(boxes, camera: CameraCfg, frame_w: int, frame_h: int) -> dict[str, int]:
    """People per table: whose anchor point falls inside the table's zone."""
    counts = {t.resource: 0 for t in camera.tables if t.polygon is not None}
    for b in boxes:
        ax, ay = box_anchor(b.x1, b.y1, b.x2, b.y2, camera.anchor)
        nx, ny = ax / frame_w, ay / frame_h
        for t in camera.tables:
            if t.polygon is not None and point_in_polygon(nx, ny, t.polygon):
                counts[t.resource] += 1
    return counts


@dataclass
class _CameraState:
    offline_since: Optional[float] = None
    offline_alerted_at: Optional[float] = None


class Service:
    def __init__(
        self,
        cfg: Config,
        detector,
        readers: dict,
        notifier: Notifier,
        sessions: Optional[SessionsClient] = None,
        clock: Callable[[], float] = time.time,
    ):
        self.cfg = cfg
        self.detector = detector
        self.readers = readers
        self.notifier = notifier
        self.sessions = sessions
        self.clock = clock
        self.tz = ZoneInfo(cfg.timezone)
        self.trackers: dict[tuple[str, str], TableTracker] = {}
        self._cam_state = {c.name: _CameraState() for c in cfg.cameras}
        self._resources: list[ResourceState] = []
        self._sessions_ok = sessions is None  # no server: "no session" for all
        self._polled_at = float("-inf")
        self._warned_missing: set[str] = set()
        for cam in cfg.cameras:
            for t in cam.tables:
                if t.polygon is None:
                    log.warning(
                        "Камера %s, %s: зона не нарисована (запустите zones.bat), стол пропущен",
                        cam.name, t.resource,
                    )
                    continue
                self.trackers[(cam.name, t.resource)] = TableTracker(t.resource, cfg.rules)

    # -- sessions ---------------------------------------------------------
    def _poll_sessions(self, now: float) -> None:
        if self.sessions is None or now - self._polled_at < self.cfg.poll_seconds:
            return
        self._polled_at = now
        try:
            self._resources = self.sessions.fetch()
            if not self._sessions_ok:
                log.info("Связь с программой есть, столов в ответе: %d", len(self._resources))
            self._sessions_ok = True
        except SessionsError as e:
            if self._sessions_ok:
                log.warning("Не удалось спросить сеансы: %s", e)
            self._sessions_ok = False

    def _session_of(self, resource: str):
        """None (no session) / status / UNKNOWN."""
        if self.sessions is None:
            return None
        if not self._sessions_ok:
            return UNKNOWN
        state = match_resource(resource, self._resources)
        if state is None:
            if resource not in self._warned_missing:
                self._warned_missing.add(resource)
                log.warning(
                    "Стол «%s» из config.yaml не найден в программе. Есть: %s",
                    resource, ", ".join(r.name for r in self._resources) or "—",
                )
            return UNKNOWN
        return state.session_status

    # -- one pass ---------------------------------------------------------
    def tick(self) -> None:
        now = self.clock()
        self._poll_sessions(now)
        for cam in self.cfg.cameras:
            reader = self.readers[cam.name]
            frame, age = reader.latest()
            if frame is None or age > self.cfg.offline_after:
                self._camera_down(cam, now, age)
                continue
            self._camera_up(cam, now)

            boxes = self.detector.detect(frame)
            h, w = frame.shape[:2]
            counts = count_people(boxes, cam, w, h)
            for table in cam.tables:
                tracker = self.trackers.get((cam.name, table.resource))
                if tracker is None:
                    continue
                events = tracker.update(
                    now, counts[table.resource], self._session_of(table.resource)
                )
                for ev in events:
                    self._send(ev, frame, cam, boxes, counts, now)

    def _send(self, ev: Event, frame, cam, boxes, counts, now: float) -> None:
        text = messages.format_event(ev, datetime.fromtimestamp(now, self.tz))
        jpeg = render_snapshot(frame, cam, boxes, counts)
        self._save_snapshot(jpeg, ev, now)
        log.info(text)
        self.notifier.notify(text, jpeg)

    def _save_snapshot(self, jpeg: bytes, ev: Event, now: float) -> None:
        try:
            folder: Path = self.cfg.snapshot_dir
            folder.mkdir(parents=True, exist_ok=True)
            stamp = datetime.fromtimestamp(now, self.tz).strftime("%Y%m%d_%H%M%S")
            safe = "".join(c if c.isalnum() else "_" for c in ev.table)
            (folder / f"{stamp}_{ev.kind}_{safe}.jpg").write_bytes(jpeg)
        except OSError as e:
            log.warning("Не удалось сохранить снимок: %s", e)

    # -- camera health ----------------------------------------------------
    def _camera_down(self, cam: CameraCfg, now: float, age: float) -> None:
        st = self._cam_state[cam.name]
        if st.offline_since is None:
            st.offline_since = now
        if now - st.offline_since < self.cfg.offline_after:
            return
        if st.offline_alerted_at is None or now - st.offline_alerted_at >= 3600:
            st.offline_alerted_at = now
            self.notifier.notify(
                messages.camera_offline(cam.name, now - st.offline_since, datetime.fromtimestamp(now, self.tz))
            )

    def _camera_up(self, cam: CameraCfg, now: float) -> None:
        st = self._cam_state[cam.name]
        if st.offline_alerted_at is not None:
            self.notifier.notify(
                messages.camera_online(cam.name, datetime.fromtimestamp(now, self.tz))
            )
        st.offline_since = None
        st.offline_alerted_at = None

    # -- loop -------------------------------------------------------------
    def run(self, stop) -> None:
        log.info("Слежение запущено. Камер: %d, столов: %d", len(self.cfg.cameras), len(self.trackers))
        while not stop.is_set():
            started = time.time()
            try:
                self.tick()
            except Exception:  # a bad frame must not stop the watch
                log.exception("Ошибка в цикле, продолжаю")
            if all(getattr(r, "ended", False) for r in self.readers.values()):
                log.info("Видеофайлы закончились.")
                return
            stop.wait(max(0.0, self.cfg.interval - (time.time() - started)))
