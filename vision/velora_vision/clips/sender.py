"""Encodes a clip, sends it to the channel and deletes the file at once.

Nothing is kept on the disk: the file exists only between encoding and the
end of the upload. A clip that could not be sent is kept in memory for a
few more tries and then dropped."""
from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

from .encoder import encode_mp4, frame_size

log = logging.getLogger("velora_vision.clips")

MAX_ATTEMPTS = 3
RETRY_AFTER = 60.0
MAX_QUEUE = 6  # a long outage must not fill the memory


@dataclass
class ClipJob:
    frames: list[bytes]  # JPEG pictures
    fps: float
    caption: str
    table: str = ""
    score: float = 0.0
    shot_epoch: float = 0.0  # when the shot ended, seconds since 1970
    attempts: int = 0
    not_before: float = 0.0
    created: float = field(default_factory=time.time)


class ClipSender(threading.Thread):
    def __init__(self, telegram, tmp_dir: Path, stop: threading.Event,
                 encode: Callable = encode_mp4, clock: Callable[[], float] = time.time):
        super().__init__(name="clip-sender", daemon=True)
        self.telegram = telegram
        self.tmp_dir = tmp_dir
        self._stop_event = stop
        self.encode = encode
        self.clock = clock
        self._q: queue.Queue[ClipJob] = queue.Queue()
        self.sent = 0
        self.dropped = 0
        self._clean_leftovers()

    def _clean_leftovers(self) -> None:
        """A crash or a power cut may leave a half-made file: remove it."""
        try:
            self.tmp_dir.mkdir(parents=True, exist_ok=True)
            for f in self.tmp_dir.glob("clip_*.mp4"):
                f.unlink(missing_ok=True)
        except OSError:
            pass

    def submit(self, job: ClipJob) -> bool:
        if self._q.qsize() >= MAX_QUEUE:
            self.dropped += 1
            log.warning("Очередь роликов полна, ролик отброшен")
            return False
        self._q.put(job)
        return True

    def pending(self) -> int:
        return self._q.qsize()

    def run(self) -> None:
        while not self._stop_event.is_set():
            try:
                job = self._q.get(timeout=1)
            except queue.Empty:
                continue
            if job.not_before > self.clock():
                self._q.put(job)
                self._stop_event.wait(1)
                continue
            self.process(job)

    def process(self, job: ClipJob) -> bool:
        path = self.tmp_dir / f"clip_{int(self.clock() * 1000)}_{id(job) % 10000}.mp4"
        try:
            if not self.encode(job.frames, job.fps, path):
                return self._failed(job, "не удалось собрать видео")
            width, height = frame_size(job.frames[0])
            ok = self.telegram.send_video(
                path, job.caption, width, height, int(len(job.frames) / job.fps)
            )
            if not ok:
                return self._failed(job, "Telegram не принял ролик")
            self.sent += 1
            log.info("Ролик отправлен: %s", job.caption.splitlines()[0])
            return True
        finally:
            try:
                path.unlink(missing_ok=True)  # always, whatever happened
            except OSError:
                log.warning("Не удалось удалить временный файл %s", path.name)

    def _failed(self, job: ClipJob, why: str) -> bool:
        job.attempts += 1
        if job.attempts >= MAX_ATTEMPTS:
            self.dropped += 1
            log.warning("Ролик отброшен после %d попыток (%s)", job.attempts, why)
        else:
            job.not_before = self.clock() + RETRY_AFTER
            self._q.put(job)
            log.warning("Ролик не ушёл (%s), попробую позже", why)
        return False
