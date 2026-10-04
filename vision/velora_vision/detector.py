"""Finds people in a frame with a YOLO model."""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Box:
    x1: float
    y1: float
    x2: float
    y2: float
    conf: float


class PersonDetector:
    def __init__(self, model: str = "yolov8n.pt", confidence: float = 0.4, image_size: int = 640):
        # Heavy import (torch): only when really detecting.
        from ultralytics import YOLO

        self._model = YOLO(model)  # downloads the weights on the first run
        self.confidence = confidence
        self.image_size = image_size

    def detect(self, frame) -> list[Box]:
        result = self._model.predict(
            frame,
            classes=[0],  # 0 = person
            conf=self.confidence,
            imgsz=self.image_size,
            verbose=False,
        )[0]
        boxes = []
        for xyxy, conf in zip(result.boxes.xyxy.tolist(), result.boxes.conf.tolist()):
            boxes.append(Box(xyxy[0], xyxy[1], xyxy[2], xyxy[3], float(conf)))
        return boxes
