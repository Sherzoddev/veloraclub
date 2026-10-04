"""Draw the zone of each table on the camera picture.

    python tools/draw_zones.py            (or zones.bat)

For every table in config.yaml: click the corners of the area where people
playing at that table stand (the floor around it, not only the cloth), press
Enter. The zones are saved to zones.yaml, in fractions of the picture, so
they survive a change of camera resolution.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from velora_vision.config import ConfigError, load_config, load_env  # noqa: E402


def to_fractions(points_px, width: int, height: int):
    """Pixel clicks -> fractions of the picture, rounded for a readable file."""
    return [[round(x / width, 4), round(y / height, 4)] for x, y in points_px]


def merge_zone(zones: dict, camera: str, resource: str, polygon) -> dict:
    out = {cam: dict(tables) for cam, tables in zones.items()}
    out.setdefault(camera, {})[resource] = polygon
    return out


def _grab_frame(source: str):
    import cv2

    cap = cv2.VideoCapture(source)
    frame = None
    for _ in range(10):  # the first frames of a stream are often grey
        ok, f = cap.read()
        if ok:
            frame = f
    cap.release()
    return frame


def _draw_one(frame, title: str, existing: dict):
    """Returns the clicked points in pixels, [] to skip, None to quit."""
    import cv2
    import numpy as np

    h, w = frame.shape[:2]
    points: list[tuple[int, int]] = []
    state = {"done": False}

    def on_mouse(event, x, y, *_):
        if event == cv2.EVENT_LBUTTONDOWN:
            points.append((x, y))

    win = "Zones"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.setMouseCallback(win, on_mouse)
    while not state["done"]:
        img = frame.copy()
        for name, poly in existing.items():
            pts = np.array([[int(x * w), int(y * h)] for x, y in poly], np.int32)
            cv2.polylines(img, [pts], True, (160, 160, 160), 2)
            cv2.putText(img, name, tuple(pts[0]), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                        (160, 160, 160), 2)
        if len(points) >= 2:
            cv2.polylines(img, [np.array(points, np.int32)], len(points) >= 3, (0, 255, 0), 2)
        for p in points:
            cv2.circle(img, p, 4, (0, 255, 0), -1)
        cv2.rectangle(img, (0, 0), (w, 56), (0, 0, 0), -1)
        cv2.putText(img, title, (10, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cv2.putText(img, "click = corner | Enter = done | Backspace = undo | S = skip | Esc = quit",
                    (10, 46), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (200, 200, 200), 1)
        cv2.imshow(win, img)
        key = cv2.waitKey(30) & 0xFF
        if key in (13, 10) and len(points) >= 3:
            break
        if key == 8 and points:
            points.pop()
        if key in (ord("s"), ord("S")):
            points = []
            break
        if key == 27:
            cv2.destroyWindow(win)
            return None
    cv2.destroyWindow(win)
    return points


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(ROOT / "config.yaml"))
    ap.add_argument("--zones", default=str(ROOT / "zones.yaml"))
    ap.add_argument("--env", default=str(ROOT / ".env"))
    ap.add_argument("--camera", help="только эта камера (name из config.yaml)")
    args = ap.parse_args()

    load_env(Path(args.env))
    try:
        cfg = load_config(Path(args.config), Path(args.zones),
                          need_supabase=False, need_telegram=False)
    except ConfigError as e:
        print(e)
        return 2

    zones_path = Path(args.zones)
    zones = {}
    if zones_path.exists():
        zones = yaml.safe_load(zones_path.read_text(encoding="utf-8")) or {}

    for cam in cfg.cameras:
        if args.camera and cam.name != args.camera:
            continue
        frame = _grab_frame(cam.source)
        if frame is None:
            print(f"Камера {cam.name}: не удалось получить картинку. Проверьте адрес в .env.")
            continue
        h, w = frame.shape[:2]
        for table in cam.tables:
            others = {k: v for k, v in (zones.get(cam.name) or {}).items()
                      if k != table.resource}
            pts = _draw_one(frame, f"{cam.name}: {table.resource}", others)
            if pts is None:
                zones_path.write_text(yaml.safe_dump(zones, allow_unicode=True), encoding="utf-8")
                print("Сохранено, выход.")
                return 0
            if pts:
                zones = merge_zone(zones, cam.name, table.resource, to_fractions(pts, w, h))

    zones_path.write_text(yaml.safe_dump(zones, allow_unicode=True), encoding="utf-8")
    print(f"Зоны сохранены в {zones_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
