"""When does a burst of moving balls count as one shot.

Pure logic: fed once per look at the table with the number of moving balls
seen, it says when a shot has started and, once the balls settle, returns it
with a score. No cameras, so every rule can be tested.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Shot:
    start: float
    end: float
    peak: int  # most balls moving at the same moment
    pots: int = 0  # balls that went into a pocket during the shot

    @property
    def seconds(self) -> float:
        return self.end - self.start

    @property
    def score(self) -> float:
        """Crude "how striking": many balls at once, and long play. To be
        replaced by a trained model once there are rated clips."""
        return self.peak + 0.5 * self.seconds + 5.0 * self.pots


class ShotDetector:
    def __init__(
        self,
        min_blobs: int = 2,
        start_frames: int = 3,
        settle: float = 1.0,
        max_len: float = 20.0,
        refractory: float = 0.5,
    ):
        self.min_blobs = min_blobs
        self.start_frames = start_frames
        self.settle = settle
        self.max_len = max_len
        self.refractory = refractory
        self._run = 0  # consecutive looks with enough moving balls
        self._run_start = 0.0
        self._run_peak = 0  # most balls during the looks that confirm a shot
        self._active = False
        self._start = 0.0
        self._last_motion = 0.0
        self._peak = 0
        self._quiet_until = float("-inf")

    @property
    def active(self) -> bool:
        return self._active

    def update(self, t: float, blobs: int) -> Optional[Shot]:
        if t < self._quiet_until:
            return None
        if not self._active:
            if blobs >= self.min_blobs:
                if self._run == 0:
                    self._run_start = t
                    self._run_peak = 0
                self._run += 1
                self._run_peak = max(self._run_peak, blobs)
                if self._run >= self.start_frames:
                    self._active = True
                    self._start = self._run_start
                    self._last_motion = t
                    self._peak = self._run_peak
            else:
                self._run = 0
            return None

        self._peak = max(self._peak, blobs)
        if blobs >= 1:
            self._last_motion = t
        if t - self._last_motion >= self.settle or t - self._start >= self.max_len:
            shot = Shot(self._start, self._last_motion, self._peak)
            self._active = False
            self._run = 0
            self._peak = 0
            self._quiet_until = t + self.refractory
            return shot
        return None
