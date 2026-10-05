"""Reads a camera (or a video file). A background thread keeps the newest
frame, so a slow detector never makes the picture lag behind."""
from __future__ import annotations

import logging
import os
import re
import threading
import time

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


class CameraReader(threading.Thread):
    def __init__(self, name: str, source: str, stop: threading.Event):
        super().__init__(name=f"camera-{name}", daemon=True)
        self.cam_name = name
        self.source = source
        self.is_file = "://" not in source
        self._stop_event = stop
        self._lock = threading.Lock()
        self._frame = None
        self._frame_at = 0.0
        self.ended = False  # a video file reached its end

    def latest(self):
        """(frame or None, seconds since that frame was read)."""
        with self._lock:
            if self._frame is None:
                return None, float("inf")
            return self._frame, time.time() - self._frame_at

    def run(self) -> None:
        while not self._stop_event.is_set():
            cap = open_capture(self.source, 8000)
            if not cap.isOpened():
                log.warning("Камера %s: не открывается, повтор через 5 с", self.cam_name)
                cap.release()
                if self.is_file:
                    self.ended = True
                    return
                self._stop_event.wait(5)
                continue
            fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
            log.info("Камера %s: подключена", self.cam_name)
            while not self._stop_event.is_set():
                ok, frame = cap.read()
                if not ok:
                    break
                with self._lock:
                    self._frame = frame
                    self._frame_at = time.time()
                if self.is_file:
                    # A recorded file would otherwise be read in a flash.
                    self._stop_event.wait(1.0 / fps)
            cap.release()
            if self.is_file:
                self.ended = True
                return
            log.warning("Камера %s: поток прервался, переподключение", self.cam_name)
            self._stop_event.wait(3)
