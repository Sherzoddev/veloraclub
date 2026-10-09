"""Counts the balls lying on the cloth in one picture.

A ball is a small, roundish spot that does not look like the cloth: white or
bright (low colour), or of another colour (yellow, red, blue...). Its size is
taken relative to the cloth, so it does not matter how far the camera is.
People, cues and hands are much bigger or longer and are left out.

Counting lying balls is steadier than following a flying one: a fast ball is
a smear for the camera, but "there were three balls, now there is one" is easy
to see. Found on a real recording from a club camera."""
from __future__ import annotations

import cv2
import numpy as np

from ..geometry import Point


class BallCounter:
    def __init__(
        self,
        polygon: list[Point],
        width: int = 640,
        min_ratio: float = 0.0008,   # ball area / cloth area
        max_ratio: float = 0.0086,
        shrink: float = 0.012,       # stay off the cushions (fraction of the width)
        max_aspect: float = 2.0,
        min_fill: float = 0.55,
    ):
        self.polygon = polygon
        self.width = width
        self.min_ratio = min_ratio
        self.max_ratio = max_ratio
        self.shrink = shrink
        self.max_aspect = max_aspect
        self.min_fill = min_fill
        self._size = None
        self._mask = None
        self._area = 1

    def _prepare(self, h: int, w: int) -> None:
        self._size = (h, w)
        mask = np.zeros((h, w), np.uint8)
        pts = np.array([[int(x * w), int(y * h)] for x, y in self.polygon], np.int32)
        cv2.fillPoly(mask, [pts], 255)
        self._area = max(1, int(cv2.countNonZero(mask)))
        k = max(1, int(self.shrink * w))
        self._mask = cv2.erode(mask, np.ones((k, k), np.uint8))

    def balls(self, frame) -> list[tuple[float, float]]:
        """Centres of the balls seen, as fractions of the picture."""
        h0, w0 = frame.shape[:2]
        scale = self.width / w0
        small = cv2.resize(frame, (self.width, max(1, int(h0 * scale))), interpolation=cv2.INTER_AREA)
        if self._size != small.shape[:2]:
            self._prepare(*small.shape[:2])
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        inside = self._mask > 0
        if not inside.any():
            return []
        hue = hsv[..., 0].astype(np.int16)
        sat = hsv[..., 1].astype(np.int16)
        val = hsv[..., 2].astype(np.int16)
        cloth_hue = int(np.median(hue[inside]))
        cloth_val = int(np.median(val[inside]))
        d = np.abs(hue - cloth_hue)
        d = np.minimum(d, 180 - d)
        odd = ((d > 22) & (sat > 70)) | ((sat < 70) & (val > cloth_val + 35))
        odd = (odd & inside).astype(np.uint8) * 255
        odd = cv2.morphologyEx(odd, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
        n, _, stats, cen = cv2.connectedComponentsWithStats(odd, connectivity=8)
        sh, sw = small.shape[:2]
        out = []
        for i in range(1, n):
            area = stats[i, cv2.CC_STAT_AREA]
            bw, bh = stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT]
            if not (self.min_ratio <= area / self._area <= self.max_ratio):
                continue
            if max(bw, bh) / max(1, min(bw, bh)) > self.max_aspect:
                continue
            if area / (bw * bh) < self.min_fill:
                continue
            out.append((float(cen[i][0]) / sw, float(cen[i][1]) / sh))
        return out
