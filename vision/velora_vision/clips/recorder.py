"""Watches one camera for shots and hands finished clips to the sender.

Keeps the last seconds of the picture in memory (compressed), so when a shot
ends the clip can start a few seconds BEFORE it. Nothing is written to disk
here."""
from __future__ import annotations

import logging
import threading
import time
from collections import deque
from datetime import datetime
from typing import Callable, Optional
from zoneinfo import ZoneInfo

import cv2

from ..config import CameraCfg
from .motion import BallMotion
from .sender import ClipJob, ClipSender
from .shots import Shot, ShotDetector

log = logging.getLogger("velora_vision.clips")

# mode -> (lowest score that is sent, seconds between clips of one table,
# clips per hour for the whole club). First guesses, to be tuned on real play.
MODES = {
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
        self.min_score, self.cooldown, self.per_hour = MODES.get(mode, MODES["learn"])
        self.fps = fps
        self.tz = ZoneInfo(timezone)
        self.table_busy = table_busy or (lambda name: True)
        self.clock = clock
        self._sleep = sleep or (lambda s: stop.wait(s))
        self.watches = [
            _TableWatch(t.resource, BallMotion(t.felt))
            for t in camera.tables if t.felt is not None
        ]
        keep = PRE_ROLL + 20.0 + POST_ROLL + 2.0
        self.ring: deque[tuple[float, bytes]] = deque(maxlen=int(keep * fps))
        self._pending: list[tuple[_TableWatch, Shot, float]] = []
        self._sent_times: deque[float] = deque()
        self.shots_seen = 0

    # -- one look -----------------------------------------------------------
    def step(self, frame, now: float) -> None:
        h, w = frame.shape[:2]
        small = frame if w <= CLIP_WIDTH else cv2.resize(
            frame, (CLIP_WIDTH, int(h * CLIP_WIDTH / w)), interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 72])
        if ok:
            self.ring.append((now, buf.tobytes()))
        for watch in self.watches:
            shot = watch.detector.update(now, watch.motion.count(frame))
            if shot is not None:
                self.shots_seen += 1
                self._shot_finished(watch, shot, now)
        self._flush_due(now)

    def _shot_finished(self, watch: _TableWatch, shot: Shot, now: float) -> None:
        if not self.table_busy(watch.name):
            return  # balls "moving" with nobody at the table: a reflection
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
            frames = [j for t, j in self.ring if shot.start - PRE_ROLL <= t <= shot.end + POST_ROLL]
            if len(frames) < 5:
                continue
            when = datetime.fromtimestamp(shot.end, self.tz).strftime("%H:%M")
            caption = (f"🎱 {watch.name}: удар в {when}\n"
                       f"шаров в движении: {shot.peak}, длится {shot.seconds:.0f} с, "
                       f"оценка {shot.score:.1f}")
            self.sender.submit(ClipJob(frames, self.fps, caption))
        self._pending = still

    # -- thread -------------------------------------------------------------
    def run(self) -> None:
        if not self.watches:
            return
        period = 1.0 / self.fps
        while not self._stop_event.is_set():
            started = self.clock()
            frame, age = self.reader.latest()
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
