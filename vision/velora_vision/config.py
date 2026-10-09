"""What the watching service needs to run, already assembled from the
settings and from what the server told us."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .geometry import Point
from .tracker import Rules


@dataclass
class TableCfg:
    resource: str  # table name as in the program
    # Where the people playing stand, in fractions of the picture (0..1);
    # None if only the cloth is drawn.
    polygon: list[Point] | None = None
    # The cloth of the table itself (for recording shots); None if not drawn.
    felt: list[Point] | None = None


@dataclass
class CameraCfg:
    name: str
    source: str  # rtsp://... or a video file
    tables: list[TableCfg]
    anchor: str = "foot"  # "foot" or "center"
    rotate: int = 0  # degrees clockwise: 0, 90, 180, 270
    widen: bool = False  # stretch to 16:9

    @property
    def is_file(self) -> bool:
        return "://" not in self.source


@dataclass
class Config:
    timezone: str
    poll_seconds: float
    rules: Rules
    interval: float
    offline_after: float
    cameras: list[CameraCfg]
    snapshot_dir: Path = field(default_factory=lambda: Path("snapshots"))
