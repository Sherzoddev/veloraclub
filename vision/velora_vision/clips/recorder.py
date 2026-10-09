"""Watches one camera for shots and hands finished clips to the sender.

Keeps the last seconds of the picture in memory (compressed), so when a shot
ends the clip can start a few seconds BEFORE it. Nothing is written to disk
here."""
from __future__ import annotations

import logging
import threading
import time
from collections import deque
from dataclasses import replace
from datetime import datetime
from typing import Callable, Optional
from zoneinfo import ZoneInfo

import cv2

from ..config import CameraCfg
from .motion import BallMotion
from .pots import PotTracker
from .sender import ClipJob, ClipSender
from .shots import Shot, ShotDetector

log = logging.getLogger("velora_vision.clips")

# mode -> (lowest score that is sent, seconds between clips of one table,
# clips per hour for the whole club). First guesses, to be tuned on real play.
MODES = {
    "pot": (0.0, 20.0, 60),      # only shots after which a ball went into a pocket
    "learn": (0.0, 90.0, 40),    # every shot: collect examples to learn from
    "bright": (5.0, 180.0, 20),  # several balls at once
    "rare": (8.0, 300.0, 10),    # only the most striking
}

PRE_ROLL = 4.0
POST_ROLL = 3.0
CLIP_WIDTH = 640


class _TableWatch:
    def __init__(self, name: str, motion: BallMotion):
        self.name = name
        self.motion = motion
        self.detector = ShotDetector()
        self.pots: Optional[PotTracker] = None  # made on the first picture (needs its shape)
        self.last_sent = float("-inf")


class ClipRecorder(threading.Thread):
    def __init__(
        self,
        camera: CameraCfg,
        reader,
        sender: ClipSender,
        stop: threading.Event,
        mode: str = "learn",
        fps: float = 15.0,
        timezone: str = "Asia/Tashkent",
        table_busy: Optional[Callable[[str], bool]] = None,
        clock: Callable[[], float] = time.time,
        sleep: Optional[Callable[[float], None]] = None,
    ):
        super().__init__(name=f"clips-{camera.name}", daemon=True)
        self.camera = camera
        self.reader = reader
        self.sender = sender
        self._stop_event = stop
        self.mode = mode if mode in MODES else "pot"
        self.min_score, self.cooldown, self.per_hour = MODES[self.mode]
        self.fps = fps
        self.tz = ZoneInfo(timezone)
        self.table_busy = table_busy or (lambda name: True)
        self.clock = clock
        self._sleep = sleep or (lambda s: stop.wait(s))
        self.watches = [
            _TableWatch(t.resource, BallMotion(t.felt))
            for t in camera.tables if t.felt is not None
        ]
        self.keep = PRE_ROLL + 20.0 + POST_ROLL + 2.0  # seconds of picture kept in memory
        self.ring: deque[tuple[float, bytes]] = deque()
        self._pending: list[tuple[_TableWatch, Shot, float]] = []
        self._sent_times: deque[float] = deque()
        self.shots_seen = 0

    @property
    def pots_seen(self) -> int:
        return sum(w.pots.total for w in self.watches if w.pots)

    # -- one look -----------------------------------------------------------
    def step(self, frame, now: float) -> None:
        h, w = frame.shape[:2]
        small = frame if w <= CLIP_WIDTH else cv2.resize(
            frame, (CLIP_WIDTH, int(h * CLIP_WIDTH / w)), interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 72])
        if ok:
            self.ring.append((now, buf.tobytes()))
        while self.ring and now - self.ring[0][0] > self.keep:
            self.ring.popleft()
        for watch in self.watches:
            blobs = watch.motion.count(frame)
            if watch.pots is None:
                watch.pots = PotTracker(watch.motion.polygon, h / w)
            watch.pots.update(now, watch.motion.last_blobs)
            shot = watch.detector.update(now, blobs)
            if shot is not None:
                self.shots_seen += 1
                self._shot_finished(watch, shot, now)
        self._flush_due(now)

    def _shot_finished(self, watch: _TableWatch, shot: Shot, now: float) -> None:
        if not self.table_busy(watch.name):
            return  # balls "moving" with nobody at the table: a reflection
        pots = watch.pots.pots_between(shot.start - 0.5, shot.end + 1.5) if watch.pots else 0
        shot = replace(shot, pots=pots)
        if self.mode == "pot" and pots == 0:
            log.debug("%s: удар без забитого шара, не отправляю", watch.name)
            return
        if shot.score < self.min_score:
            log.debug("%s: удар %.1f < %.1f, не отправляю", watch.name, shot.score, self.min_score)
            return
        if now - watch.last_sent < self.cooldown:
            return
        while self._sent_times and now - self._sent_times[0] > 3600:
            self._sent_times.popleft()
        if len(self._sent_times) >= self.per_hour:
            return
        watch.last_sent = now
        self._sent_times.append(now)
        self._pending.append((watch, shot, shot.end + POST_ROLL))

    def _flush_due(self, now: float) -> None:
        still = []
        for watch, shot, due in self._pending:
            if now < due:
                still.append((watch, shot, due))
                continue
            taken = [(t, j) for t, j in self.ring if shot.start - PRE_ROLL <= t <= shot.end + POST_ROLL]
            if len(taken) < 5:
                continue
            frames = [j for _, j in taken]
            # Play at the speed it was filmed: the picture comes at whatever
            # rate the camera and the computer manage, not at a fixed one.
            span = taken[-1][0] - taken[0][0]
            fps = min(30.0, max(4.0, (len(taken) - 1) / span)) if span > 0 else self.fps
            when = datetime.fromtimestamp(shot.end, self.tz).strftime("%H:%M")
            head = (f"🎯 {watch.name}: шар в лузу, {when}" if shot.pots
                    else f"🎱 {watch.name}: удар в {when}")
            caption = (f"{head}\n"
                       f"шаров в движении: {shot.peak}, длится {span:.0f} с, "
                       f"оценка {shot.score:.1f}")
            self.sender.submit(ClipJob(frames, fps, caption, table=watch.name,
                                       score=shot.score, shot_epoch=shot.end))
        self._pending = still

    # -- thread -------------------------------------------------------------
    def run(self) -> None:
        if not self.watches:
            return
        period = 1.0 / self.fps
        last_frame = None
        while not self._stop_event.is_set():
            started = self.clock()
            frame, age = self.reader.latest()
            if frame is last_frame:
                # The camera has not sent a new picture yet. Looking at the
                # same one again would read as "nothing moved".
                self._sleep(0.01)
                continue
            last_frame = frame
            if frame is not None and age < 2.0:
                try:
                    self.step(frame, started)
                except Exception:
                    log.exception("Ошибка записи ударов, продолжаю")
            self._sleep(max(0.0, period - (self.clock() - started)))


def capture_clip(source: str, seconds: float, fps: float) -> list[bytes]:
    """A few seconds from a camera (or file) as JPEG pictures, in real time."""
    from ..camera import open_capture

    cap = open_capture(source, 8000)
    frames: list[bytes] = []
    if not cap.isOpened():
        cap.release()
        return frames
    is_file = "://" not in source  # a file is read at once, a camera in real time
    try:
        end = time.time() + seconds
        next_at = 0.0
        while time.time() < end and not (is_file and len(frames) >= seconds * fps):
            ok, frame = cap.read()
            if not ok:
                break
            if not is_file and time.time() < next_at:
                continue
            next_at = time.time() + 1.0 / fps
            h, w = frame.shape[:2]
            if w > CLIP_WIDTH:
                frame = cv2.resize(frame, (CLIP_WIDTH, int(h * CLIP_WIDTH / w)), interpolation=cv2.INTER_AREA)
            ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 72])
            if ok:
                frames.append(buf.tobytes())
    finally:
        cap.release()
    return frames
