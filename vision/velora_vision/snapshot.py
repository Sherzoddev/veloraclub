"""A picture for the message and for the preview: the frame with the table
zones and the people found."""
from __future__ import annotations

import cv2
import numpy as np

from .config import CameraCfg


def draw_overlay(frame, camera: CameraCfg, boxes, counts: dict[str, int]):
    img = frame.copy()
    h, w = img.shape[:2]
    for table in camera.tables:
        if table.felt is not None:  # the cloth, thin and blue
            fp = np.array([[int(x * w), int(y * h)] for x, y in table.felt], np.int32)
            cv2.polylines(img, [fp], True, (255, 160, 60), 1)
        if table.polygon is None:
            continue
        pts = np.array([[int(x * w), int(y * h)] for x, y in table.polygon], np.int32)
        n = counts.get(table.resource, 0)
        color = (0, 200, 0) if n else (160, 160, 160)
        cv2.polylines(img, [pts], True, color, 2)
        cv2.putText(
            img, f"{table.resource}: {n}", (int(pts[0][0]), max(20, int(pts[0][1]) - 8)),
            cv2.FONT_HERSHEY_SIMPLEX, 0.7, color, 2, cv2.LINE_AA,
        )
    for b in boxes:
        cv2.rectangle(img, (int(b.x1), int(b.y1)), (int(b.x2), int(b.y2)), (0, 215, 255), 2)
    return img


def render_snapshot(frame, camera: CameraCfg, boxes, counts: dict[str, int]) -> bytes:
    img = draw_overlay(frame, camera, boxes, counts)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return buf.tobytes() if ok else b""
