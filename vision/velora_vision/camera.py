"""Opens a camera to take one picture (checking an address, a thumbnail)."""
from __future__ import annotations

import logging
import os
import re
import cv2

# TCP is slower than UDP but doesn't smear the picture on a busy Wi-Fi.
os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")

log = logging.getLogger("velora_vision.camera")


def mask_url(url: str) -> str:
    """rtsp://user:secret@host/x -> rtsp://user:***@host/x, for logs and lists."""
    return re.sub(r"(://[^:/@\s]+:)[^@/\s]*@", r"\1***@", url)


def open_capture(source: str, timeout_ms: int = 5000):
    if "://" in source:
        return cv2.VideoCapture(
            source, cv2.CAP_FFMPEG,
            [cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, timeout_ms, cv2.CAP_PROP_READ_TIMEOUT_MSEC, timeout_ms],
        )
    return cv2.VideoCapture(source)


def grab_frame(source: str, timeout_ms: int = 5000, attempts: int = 8):
    """One good picture from the camera, or None."""
    cap = open_capture(source, timeout_ms)
    try:
        if not cap.isOpened():
            return None
        frame = None
        for _ in range(attempts):  # the first frames of a stream are often grey
            ok, f = cap.read()
            if ok and f is not None:
                frame = f
        return frame
    finally:
        cap.release()
