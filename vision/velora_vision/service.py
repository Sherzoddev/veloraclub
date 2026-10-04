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
from .sessions import ClubSnapshot, SessionsError, match_resource
from .snapshot import render_snapshot
from .tracker import UNKNOWN, Event, TableTracker

log = logging.getLogger("velora_vision")


class Notifier(Protocol):
    def notify(self, text: str, jpeg: Optional[bytes] = None) -> None: ...


class PrintNotifier:
    """Shows what would be sent (tests, trial runs)."""

    def notify(self, text: str, jpeg: Optional[bytes] = None) -> None:
        log.info("[сообщение%s] %s", " + фото" if jpeg else "", text)


class TelegramNotifier:
    def __init__(self, telegram):
        self.telegram = telegram

    def notify(self, text: str, jpeg: Optional[bytes] = None) -> None:
        if jpeg and self.telegram.send_photo(jpeg, text):
            return
        self.telegram.send_message(text)


def count_people(boxes, camera: CameraCfg, frame_w: int, frame_h: int) -> dict[str, int]:
    """People per table: whose anchor point falls inside the table's zone."""
    tables = [t for t in camera.tables if t.polygon is not None]
    counts = {t.resource: 0 for t in tables}
    for b in boxes:
        ax, ay = box_anchor(b.x1, b.y1, b.x2, b.y2, camera.anchor)
        nx, ny = ax / frame_w, ay / frame_h
        for t in tables:
            if point_in_polygon(nx, ny, t.polygon):
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
        sessions=None,
        clock: Callable[[], float] = time.time,
    ):
        self.cfg = cfg
        self.detector = detector
        self.readers = readers
        self.notifier = notifier
        self.sessions = sessions
        self.clock = clock
        self.tz = ZoneInfo(cfg.timezone)
        # One tracker per table, however many cameras see it.
        self.trackers: dict[str, TableTracker] = {}
        for cam in cfg.cameras:
            for t in cam.tables:
                if t.polygon is not None:
                    self.trackers.setdefault(t.resource, TableTracker(t.resource, cfg.rules))
        # For the window: table -> (people now, session status or None).
        self.live: dict[str, tuple[int, Optional[str]]] = {}
        self._cam_state = {c.name: _CameraState() for c in cfg.cameras}
        self._resources: list = []
        self._sessions_ok = sessions is None  # no server: "no session" for all
        self._polled_at = float("-inf")
        self._warned_missing: set[str] = set()

    # -- sessions ---------------------------------------------------------
    def _poll_sessions(self, now: float) -> None:
        if self.sessions is None or now - self._polled_at < self.cfg.poll_seconds:
            return
        self._polled_at = now
        try:
            snap: ClubSnapshot = self.sessions.fetch()
            self._resources = snap.resources
            if not self._sessions_ok:
                log.info("Связь с программой Velora Club есть (столов: %d)", len(snap.resources))
            self._sessions_ok = True
        except SessionsError as e:
            if self._sessions_ok:
                log.warning("Не удалось спросить сеансы: %s", e)
            self._sessions_ok = False

    def _session_of(self, resource: str):
        """None (no session) / a status / UNKNOWN (can't tell)."""
        if self.sessions is None:
            return None
        if not self._sessions_ok:
            return UNKNOWN
        state = match_resource(resource, self._resources)
        if state is None:
            if resource not in self._warned_missing:
                self._warned_missing.add(resource)
                log.warning(
                    "Стол «%s» не найден в программе Velora Club (возможно, его "
                    "переименовали). Есть: %s",
                    resource, ", ".join(r.name for r in self._resources) or "—",
                )
            return UNKNOWN
        return state.session_status

    # -- one pass ---------------------------------------------------------
    def tick(self) -> None:
        now = self.clock()
        self._poll_sessions(now)

        # table -> what each camera that sees it says
        seen: dict[str, list[tuple[int, CameraCfg, object, list, dict]]] = {}
        for cam in self.cfg.cameras:
            frame, age = self.readers[cam.name].latest()
            if frame is None or age > self.cfg.offline_after:
                self._camera_down(cam, now)
                continue
            self._camera_up(cam, now)
            watched = [t for t in cam.tables if t.polygon is not None]
            if not watched:
                continue  # only shots are recorded on this camera
            boxes = self.detector.detect(frame)
            h, w = frame.shape[:2]
            counts = count_people(boxes, cam, w, h)
            for table in watched:
                seen.setdefault(table.resource, []).append(
                    (counts[table.resource], cam, frame, boxes, counts)
                )

        for resource, entries in seen.items():
            # Several cameras on one table: believe the one that sees most.
            people, cam, frame, boxes, counts = max(entries, key=lambda e: e[0])
            session = self._session_of(resource)
            self.live[resource] = (people, None if session == UNKNOWN else session)
            for ev in self.trackers[resource].update(now, people, session):
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
    def _camera_down(self, cam: CameraCfg, now: float) -> None:
        st = self._cam_state[cam.name]
        if st.offline_since is None:
            st.offline_since = now
        if now - st.offline_since < self.cfg.offline_after:
            return
        if st.offline_alerted_at is None or now - st.offline_alerted_at >= 3600:
            st.offline_alerted_at = now
            self.notifier.notify(
                messages.camera_offline(
                    cam.name, now - st.offline_since, datetime.fromtimestamp(now, self.tz)
                )
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
            if self.readers and all(getattr(r, "ended", False) for r in self.readers.values()):
                log.info("Видеофайлы закончились.")
                return
            stop.wait(max(0.0, self.cfg.interval - (time.time() - started)))
