"""Counts moving balls on the table cloth by what changed between two
pictures. Only ball-sized, roundish changes count: a hand, a cue or a
person leaning over the table is much bigger or much longer."""
from __future__ import annotations

import cv2
import numpy as np

from ..geometry import Point


class BallMotion:
    def __init__(
        self,
        polygon: list[Point],
        width: int = 320,
        min_ratio: float = 0.0004,
        max_ratio: float = 0.006,
        max_aspect: float = 3.0,
        threshold: int = 25,
        global_change: float = 0.25,
    ):
        self.polygon = polygon
        self.width = width
        self.min_ratio = min_ratio
        self.max_ratio = max_ratio
        self.max_aspect = max_aspect
        self.threshold = threshold
        self.global_change = global_change
        self._prev = None
        self._mask = None
        self._mask_area = 1
        self._size = None

    def _prepare(self, h: int, w: int) -> None:
        self._size = (h, w)
        mask = np.zeros((h, w), np.uint8)
        pts = np.array([[int(x * w), int(y * h)] for x, y in self.polygon], np.int32)
        cv2.fillPoly(mask, [pts], 255)
        self._mask = mask
        self._mask_area = max(1, int(cv2.countNonZero(mask)))
        self._prev = None

    def count(self, frame) -> int:
        h0, w0 = frame.shape[:2]
        scale = self.width / w0
        small = cv2.resize(frame, (self.width, max(1, int(h0 * scale))), interpolation=cv2.INTER_AREA)
        gray = cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (5, 5), 0)
        if self._size != gray.shape[:2]:
            self._prepare(*gray.shape[:2])
        prev, self._prev = self._prev, gray
        if prev is None:
            return 0
        diff = cv2.absdiff(gray, prev)
        _, moving = cv2.threshold(diff, self.threshold, 255, cv2.THRESH_BINARY)
        moving = cv2.bitwise_and(moving, self._mask)
        if cv2.countNonZero(moving) > self.global_change * self._mask_area:
            return 0  # the light or the camera changed, not the balls
        moving = cv2.morphologyEx(moving, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
        moving = cv2.dilate(moving, np.ones((3, 3), np.uint8))
        n, _, stats, _ = cv2.connectedComponentsWithStats(moving, connectivity=8)
        blobs = 0
        for i in range(1, n):
            w, h, area = stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT], stats[i, cv2.CC_STAT_AREA]
            ratio = area / self._mask_area
            if not (self.min_ratio <= ratio <= self.max_ratio):
                continue
            if max(w, h) / max(1, min(w, h)) > self.max_aspect:
                continue
            blobs += 1
        return blobs
