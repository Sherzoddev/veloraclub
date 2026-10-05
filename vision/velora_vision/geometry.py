"""Plain geometry: is a point inside a table's zone."""
from __future__ import annotations

from typing import Sequence

Point = tuple[float, float]


def point_in_polygon(x: float, y: float, polygon: Sequence[Point]) -> bool:
    """Ray casting. Points exactly on an edge count as inside."""
    n = len(polygon)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = polygon[i]
        xj, yj = polygon[j]
        # On the edge?
        cross = (x - xi) * (yj - yi) - (y - yi) * (xj - xi)
        if (
            abs(cross) < 1e-12
            and min(xi, xj) - 1e-12 <= x <= max(xi, xj) + 1e-12
            and min(yi, yj) - 1e-12 <= y <= max(yi, yj) + 1e-12
        ):
            return True
        if (yi > y) != (yj > y):
            x_cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def box_anchor(
    x1: float, y1: float, x2: float, y2: float, anchor: str = "foot"
) -> Point:
    """The point of a person's box that decides which table they stand at.

    "foot" is the middle of the bottom edge: right for a camera at an angle
    (where the box also covers whatever is behind the person). "center" is
    right for a camera straight above the table.
    """
    cx = (x1 + x2) / 2
    if anchor == "center":
        return cx, (y1 + y2) / 2
    return cx, y2
