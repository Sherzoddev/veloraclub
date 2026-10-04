import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.draw_zones import merge_zone, to_fractions  # noqa: E402


def test_to_fractions():
    assert to_fractions([(320, 180), (640, 360)], 640, 360) == [[0.5, 0.5], [1.0, 1.0]]


def test_merge_zone_keeps_other_tables_and_cameras():
    zones = {"cam1": {"1 Stol": [[0, 0]]}, "cam2": {"9 Stol": [[1, 1]]}}
    out = merge_zone(zones, "cam1", "2 Stol", [[0.1, 0.2]])
    assert out["cam1"] == {"1 Stol": [[0, 0]], "2 Stol": [[0.1, 0.2]]}
    assert out["cam2"] == {"9 Stol": [[1, 1]]}
    assert "2 Stol" not in zones["cam1"]  # the original is untouched
