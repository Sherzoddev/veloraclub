"""Finds people in a frame with a YOLOX model through OpenCV's own neural
network module: no torch, no onnxruntime, so the program stays small.

YOLOX is Apache-2.0 licensed, so the program can be handed to other clubs.
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class Box:
    x1: float
    y1: float
    x2: float
    y2: float
    conf: float


def _decode(raw: np.ndarray, size: int, strides=(8, 16, 32)) -> np.ndarray:
    """YOLOX writes offsets per grid cell; turns them into pixels of the
    letterboxed input (centre x, centre y, width, height)."""
    grids, scales = [], []
    for s in strides:
        n = size // s
        xv, yv = np.meshgrid(np.arange(n), np.arange(n))
        grid = np.stack((xv, yv), 2).reshape(1, -1, 2)
        grids.append(grid)
        scales.append(np.full((1, grid.shape[1], 1), s))
    grids = np.concatenate(grids, 1).astype(np.float32)
    scales = np.concatenate(scales, 1).astype(np.float32)
    out = raw.copy()
    out[..., :2] = (out[..., :2] + grids) * scales
    out[..., 2:4] = np.exp(out[..., 2:4]) * scales
    return out


def postprocess(
    raw: np.ndarray,
    size: int,
    ratio: float,
    confidence: float,
    nms_iou: float = 0.45,
) -> list[Box]:
    """raw: (1, anchors, 85) straight from the network. Returns people only."""
    out = _decode(raw[0:1], size)[0]
    scores = out[:, 4] * out[:, 5]  # objectness * class 0 ("person")
    keep = scores > confidence
    if not keep.any():
        return []
    out, scores = out[keep], scores[keep]
    cx, cy, w, h = out[:, 0], out[:, 1], out[:, 2], out[:, 3]
    xywh = np.stack([cx - w / 2, cy - h / 2, w, h], 1) / ratio
    idx = cv2.dnn.NMSBoxes(xywh.tolist(), scores.tolist(), confidence, nms_iou)
    boxes = []
    for i in np.array(idx).reshape(-1):
        x, y, bw, bh = xywh[i]
        boxes.append(Box(float(x), float(y), float(x + bw), float(y + bh), float(scores[i])))
    return boxes


class PersonDetector:
    def __init__(self, model_path: str, confidence: float = 0.4, image_size: int = 640):
        self.net = cv2.dnn.readNetFromONNX(model_path)
        self.confidence = confidence
        self.size = image_size

    def detect(self, frame) -> list[Box]:
        h, w = frame.shape[:2]
        ratio = min(self.size / h, self.size / w)
        nh, nw = int(h * ratio), int(w * ratio)
        padded = np.full((self.size, self.size, 3), 114, np.uint8)
        padded[:nh, :nw] = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_LINEAR)
        # YOLOX takes BGR pixels 0..255 as they are.
        blob = cv2.dnn.blobFromImage(padded, 1.0, (self.size, self.size), swapRB=False)
        self.net.setInput(blob)
        raw = self.net.forward()
        return postprocess(raw, self.size, ratio, self.confidence)
