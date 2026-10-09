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
from .balls import BallCounter
from .pots import judge
from .sender import ClipJob, ClipSender
from .shots import Shot, ShotDetector

log = logging.getLogger("velora_vision.clips")

# mode -> (lowest score that is sent, seconds between clips of one table,
# clips per hour for the whole club). First guesses, to be tuned on real play.
MODES = {
    "pot_bright": (10.0, 30.0, 30),  # a ball potted AND a striking shot (the default)
    "pot": (0.0, 20.0, 60),      # every shot after which a ball went into a pocket
    "learn": (0.0, 90.0, 40),    # every shot: collect examples to learn from
    "bright": (5.0, 180.0, 20),  # several balls at once
    "rare": (8.0, 300.0, 10),    # only the most striking
}

PRE_ROLL = 5.0
POST_ROLL = 3.0
POST_POT_ROLL = 5.0  # after a ball goes in: the ball dropping, the others rolling on, the reaction
CLIP_WIDTH = 640           # width of the test clip and of the clip when there is no table to zoom to
TABLE_CLIP_WIDTH = 800     # the clip is the table with some room around it, not the whole room
TABLE_MARGIN = 0.14        # room around the cloth, fraction of its size: the player stays in


POT_MODES = ("pot", "pot_bright")


class _TableWatch:
    def __init__(self, name: str, motion: BallMotion, counter: BallCounter, mode: str):
        self.name = name
        self.motion = motion
        self.counter = counter
        # When only the shots with a ball potted matter, a lone moving ball
        # is enough to look at; whether it went in is decided by the count.
        self.detector = ShotDetector(min_blobs=1, start_frames=2) if mode in POT_MODES else ShotDetector()
        self.history: deque[tuple[float, int]] = deque()  # (time, balls on the cloth)
        self.ring: deque[tuple[float, bytes]] = deque()   # the table's picture of the last seconds
        self.felt = counter.polygon
        self.pots_total = 0
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
        self.mode = mode if mode in MODES else "pot_bright"
        self.min_score, self.cooldown, self.per_hour = MODES[self.mode]
        self.fps = fps
        self.tz = ZoneInfo(timezone)
        self.table_busy = table_busy or (lambda name: True)
        self.clock = clock
        self._sleep = sleep or (lambda s: stop.wait(s))
        self.watches = [
            _TableWatch(t.resource, BallMotion(t.felt), BallCounter(t.felt), self.mode)
            for t in camera.tables if t.felt is not None
        ]
        self.keep = PRE_ROLL + 20.0 + POST_POT_ROLL + 4.0  # seconds of picture kept in memory
        self._pending: list[tuple[_TableWatch, Shot, float]] = []  # shot, when to decide
        self._sent_times: deque[float] = deque()
        self.shots_seen = 0

    @property
    def pots_seen(self) -> int:
        return sum(w.pots_total for w in self.watches)

    # -- one look -----------------------------------------------------------
    def step(self, frame, now: float) -> None:
        for watch in self.watches:
            self._remember(watch, frame, now)
            blobs = watch.motion.count(frame)
            watch.history.append((now, len(watch.counter.balls(frame))))
            while watch.history and now - watch.history[0][0] > self.keep:
                watch.history.popleft()
            shot = watch.detector.update(now, blobs)
            if shot is not None:
                self._shot_finished(watch, shot, now)
        self._flush_due(now)

    def _remember(self, watch: _TableWatch, frame, now: float) -> None:
        """Keeps the picture of this table (cropped to it) for the lead-in of a clip."""
        h, w = frame.shape[:2]
        xs = [x for x, _ in watch.felt]
        ys = [y for _, y in watch.felt]
        bw, bh = (max(xs) - min(xs)) * w, (max(ys) - min(ys)) * h
        mx, my = TABLE_MARGIN * max(bw, bh), TABLE_MARGIN * max(bw, bh)
        x0, x1 = max(0, int(min(xs) * w - mx)), min(w, int(max(xs) * w + mx))
        y0, y1 = max(0, int(min(ys) * h - my)), min(h, int(max(ys) * h + my))
        crop = frame[y0:y1, x0:x1]
        ch, cw = crop.shape[:2]
        if cw > TABLE_CLIP_WIDTH:
            crop = cv2.resize(crop, (TABLE_CLIP_WIDTH, int(ch * TABLE_CLIP_WIDTH / cw)),
                              interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, 78])
        if ok:
            watch.ring.append((now, buf.tobytes()))
        while watch.ring and now - watch.ring[0][0] > self.keep:
            watch.ring.popleft()

    def _shot_finished(self, watch: _TableWatch, shot: Shot, now: float) -> None:
        if not self.table_busy(watch.name):
            return  # balls "moving" with nobody at the table: a reflection
        self.shots_seen += 1
        # Whether a ball went in shows only a few seconds after the shot, when
        # everything has stopped and the balls can be counted again.
        self._pending.append((watch, shot, shot.end + POST_POT_ROLL))

    def _decide(self, watch: _TableWatch, shot: Shot, now: float) -> Optional[Shot]:
        """The shot with the number of potted balls, if it is to be sent."""
        verdict = judge(list(watch.history), shot.start, shot.end)
        pots = verdict.pots if verdict else 0
        watch.pots_total += pots
        shot = replace(shot, pots=pots)
        log.info("%s: удар, шаров в движении %d, на сукне было %s, стало %s, забито %d, оценка %.1f",
                 watch.name, shot.peak, verdict.before if verdict else "?",
                 verdict.after if verdict else "?", pots, shot.score)
        if self.mode in POT_MODES and pots == 0:
            return None
        if shot.score < self.min_score:
            return None
        if shot.end - watch.last_sent < self.cooldown:
            return None
        while self._sent_times and shot.end - self._sent_times[0] > 3600:
            self._sent_times.popleft()
        if len(self._sent_times) >= self.per_hour:
            return None
        watch.last_sent = shot.end
        self._sent_times.append(shot.end)
        return shot

    def _flush_due(self, now: float) -> None:
        still = []
        for watch, shot, decide_at in self._pending:
            if now < decide_at:
                still.append((watch, shot, decide_at))
                continue
            shot = self._decide(watch, shot, now)
            if shot is None:
                continue
            # The clip runs on past the moment the ball drops: the pot is the point.
            end = shot.end + (POST_POT_ROLL if shot.pots else POST_ROLL)
            taken = [(t, j) for t, j in watch.ring if shot.start - PRE_ROLL <= t <= end]
            if len(taken) < 5:
                continue
            frames = [j for _, j in taken]
            # Play at the speed it was filmed: the picture comes at whatever
            # rate the camera and the computer manage, not at a fixed one.
            span = taken[-1][0] - taken[0][0]
            fps = min(30.0, max(4.0, (len(taken) - 1) / span)) if span > 0 else self.fps
            when = datetime.fromtimestamp(shot.end, self.tz).strftime("%H:%M")
            head = (f"🎯 {watch.name}: забито шаров {shot.pots}, {when}" if shot.pots
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
