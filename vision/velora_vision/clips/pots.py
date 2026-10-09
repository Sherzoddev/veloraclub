"""Did a ball go into a pocket.

A ball that goes in does not stop on the cloth: it is moving fast and then it
is gone right at one of the six pockets. A ball that merely stops (or hits a
cushion) is also "gone" from the picture of moving things, but it slowed down
first and is usually not at a pocket. So: follow the moving blobs from look
to look, and when one disappears while still fast and close to a pocket, that
is a ball potted.

Pure logic on blob centres (fractions of the picture), no camera. A first
version to be tuned on real play."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Sequence

from ..geometry import Point


def pocket_points(polygon: Sequence[Point], aspect: float) -> list[Point]:
    """Where the pockets are, from the drawn cloth: its corners and the middle
    of its two longest sides (in a space where x and y have the same scale)."""
    pts = [(x, y * aspect) for x, y in polygon]
    out = list(pts)
    n = len(pts)
    edges = sorted(range(n), key=lambda i: -math.dist(pts[i], pts[(i + 1) % n]))[:2]
    for i in edges:
        a, b = pts[i], pts[(i + 1) % n]
        out.append(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2))
    return out


def polygon_area(pts: Sequence[Point]) -> float:
    s = 0.0
    for i in range(len(pts)):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % len(pts)]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2


@dataclass
class _Track:
    pts: list[tuple[float, float, float]]  # (time, x, y)
    missed: int = 0


class PotTracker:
    def __init__(
        self,
        polygon: Sequence[Point],
        aspect: float = 1.0,
        pocket_radius: float = 0.08,   # in units of sqrt(cloth area)
        max_jump: float = 0.25,        # how far a ball may move between two looks
        vanish_looks: int = 2,         # looks without the ball = it is gone
        min_speed: float = 0.12,       # cloth units per second at the end
    ):
        self.aspect = aspect
        space = [(x, y * aspect) for x, y in polygon]
        self.unit = math.sqrt(max(polygon_area(space), 1e-9))
        self.pockets = pocket_points(polygon, aspect)
        self.pocket_radius = pocket_radius * self.unit
        self.max_jump = max_jump * self.unit
        self.vanish_looks = vanish_looks
        self.min_speed = min_speed * self.unit
        self._tracks: list[_Track] = []
        self.pots: list[float] = []  # times of potted balls (the latest ones)
        self.pot_speeds: list[float] = []  # how fast each of them was, in cloth units per second
        self.total = 0  # all balls seen going in since the start

    def update(self, t: float, blobs: Sequence[Point]) -> int:
        """One look. Returns how many balls were seen going in just now."""
        pts = [(x, y * self.aspect) for x, y in blobs]
        free = list(range(len(pts)))
        # Match each live track with the nearest blob that is close enough.
        pairs = []
        for ti, tr in enumerate(self._tracks):
            _, tx, ty = tr.pts[-1]
            for bi in free:
                d = math.dist((tx, ty), pts[bi])
                if d <= self.max_jump:
                    pairs.append((d, ti, bi))
        used_t, used_b = set(), set()
        for d, ti, bi in sorted(pairs):
            if ti in used_t or bi in used_b:
                continue
            used_t.add(ti)
            used_b.add(bi)
            tr = self._tracks[ti]
            tr.pts.append((t, *pts[bi]))
            tr.missed = 0
        potted = 0
        alive = []
        for ti, tr in enumerate(self._tracks):
            if ti in used_t:
                alive.append(tr)
                continue
            tr.missed += 1
            if tr.missed < self.vanish_looks:
                alive.append(tr)
                continue
            speed = self._went_in(tr)
            if speed:
                potted += 1
                self.total += 1
                self.pots.append(tr.pts[-1][0])
                self.pot_speeds.append(speed / self.unit)
        self._tracks = alive
        for bi in free:
            if bi not in used_b:
                self._tracks.append(_Track([(t, *pts[bi])]))
        if len(self.pots) > 50:
            self.pots = self.pots[-50:]
            self.pot_speeds = self.pot_speeds[-50:]
        return potted

    def _went_in(self, tr: _Track) -> float:
        """The speed of the ball (cloth units per second) if it went into a
        pocket, else 0.0."""
        if len(tr.pts) < 3:
            return 0.0  # a flash of one or two looks is not a ball on its way
        t1, x1, y1 = tr.pts[-1]
        t0, x0, y0 = tr.pts[-2]
        if t1 - t0 <= 0:
            return 0.0
        speed = math.dist((x0, y0), (x1, y1)) / (t1 - t0)
        if speed < self.min_speed:
            return 0.0
        # A fast ball covers a lot between two looks: it may have been last
        # seen well before the pocket it went into, so look where it was heading.
        ahead = (x1 + (x1 - x0), y1 + (y1 - y0))
        _, xa, ya = tr.pts[-3]
        was = self._pocket_distance(xa, ya)
        # It has to be coming closer to the pocket, not going past or away
        # (a ball bouncing off the cushion beside a pocket).
        if self._pocket_distance(x1, y1) > was:
            return 0.0
        if self._pocket_distance(x1, y1) <= self.pocket_radius or self._pocket_distance(*ahead) <= self.pocket_radius:
            return speed
        return 0.0

    def _pocket_distance(self, x: float, y: float) -> float:
        return min(math.dist((x, y), p) for p in self.pockets)

    def fastest_between(self, start: float, end: float) -> float:
        """Speed of the fastest ball potted in this time span (0 if none)."""
        return max((s for t, s in zip(self.pots, self.pot_speeds) if start <= t <= end), default=0.0)

    def last_pot_between(self, start: float, end: float) -> float:
        """When the last ball went in within this span (or `start` if none)."""
        return max((t for t in self.pots if start <= t <= end), default=start)

    def pots_between(self, start: float, end: float) -> int:
        return sum(1 for p in self.pots if start <= p <= end)
