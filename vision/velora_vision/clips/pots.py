"""Did a ball go into a pocket during a shot.

Compare how many balls lay on the cloth before the shot and after it. If
there are fewer afterwards, they went into pockets. Before: the usual count
in the two seconds before the shot (a hand or the cue may hide a ball for a
moment, so a typical value, not the lowest). After: a high value from a few
seconds once everything has stopped (someone standing in front of the table
hides balls: any moment when they are all visible counts).

Pure logic on a history of (time, balls seen); no camera."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

BEFORE_SPAN = (2.5, 0.2)   # seconds before the shot start
AFTER_SPAN = (1.5, 4.5)    # seconds after the shot end
MIN_LOOKS = 4              # fewer looks than this in a window: no verdict


@dataclass(frozen=True)
class Verdict:
    before: int
    after: int

    @property
    def pots(self) -> int:
        return max(0, self.before - self.after)


def _window(history: Sequence[tuple[float, int]], a: float, b: float) -> list[int]:
    return [n for t, n in history if a <= t <= b]


def _percentile(values: list[int], q: float) -> int:
    s = sorted(values)
    return s[min(len(s) - 1, int(q * len(s)))]


def judge(history: Sequence[tuple[float, int]], start: float, end: float) -> Verdict | None:
    """Balls before and after a shot that ran from `start` to `end`, or None
    if the history does not cover both sides well enough."""
    before = _window(history, start - BEFORE_SPAN[0], start - BEFORE_SPAN[1])
    after = _window(history, end + AFTER_SPAN[0], end + AFTER_SPAN[1])
    if len(before) < MIN_LOOKS or len(after) < MIN_LOOKS:
        return None
    return Verdict(before=_percentile(before, 0.5), after=_percentile(after, 0.75))
