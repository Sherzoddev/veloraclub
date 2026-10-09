"""A live look at what the program sees: the camera picture with the table
zones and the people it found. For checking the setup."""
from __future__ import annotations

import threading
import time
import tkinter as tk
from tkinter import ttk
from typing import Callable

from ..camera import open_capture, reshape
from ..config import CameraCfg
from ..service import count_people
from ..snapshot import draw_overlay
from .common import GREEN, GREY, RED, center_on, hint, photo_from_frame

MAX_W, MAX_H = 900, 560


class PreviewWindow(tk.Toplevel):
    def __init__(self, parent, camera: CameraCfg, detector_factory: Callable[[], object]):
        super().__init__(parent)
        self.camera = camera
        self.title(f"Как видит программа: {camera.name}")
        self.transient(parent)
        center_on(self, parent, MAX_W + 40, MAX_H + 120)
        self.protocol("WM_DELETE_WINDOW", self._close)

        self.status = ttk.Label(self, text="Подключаюсь к камере…", foreground=GREY)
        self.status.pack(anchor="w", padx=14, pady=(10, 2))
        hint(self, "Зелёные рамки: зоны столов с людьми, жёлтые: найденные люди. Если людей "
                   "не видно или лишние: поправьте зоны.", MAX_W).pack(anchor="w", padx=14)
        self.label = tk.Label(self, bg="#202124")
        self.label.pack(padx=14, pady=10)

        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._latest = None  # (frame_with_overlay, counts) | str error
        self._photo = None
        threading.Thread(target=self._work, args=(detector_factory,), daemon=True).start()
        self.after(300, self._show)

    def _work(self, detector_factory) -> None:
        try:
            detector = detector_factory()
        except Exception as e:
            self._put(f"Не удалось загрузить распознавание: {e}")
            return
        last = 0.0
        failures = 0
        while not self._stop.is_set():
            cap = open_capture(self.camera.source, 8000)
            if not cap.isOpened():
                cap.release()
                failures += 1
                self._put("Камера не отвечает. Пробую снова…")
                if failures >= 5:
                    return
                self._stop.wait(2)
                continue
            failures = 0
            try:
                while not self._stop.is_set():
                    ok, frame = cap.read()
                    if not ok:
                        break  # the stream dropped (or a test file ended): reconnect
                    if time.time() - last < 0.7:
                        continue
                    last = time.time()
                    frame = reshape(frame, self.camera.rotate, self.camera.widen)
                    boxes = detector.detect(frame)
                    h, w = frame.shape[:2]
                    counts = count_people(boxes, self.camera, w, h)
                    self._put((draw_overlay(frame, self.camera, boxes, counts), counts))
            finally:
                cap.release()
            self._stop.wait(1)

    def _put(self, item) -> None:
        with self._lock:
            self._latest = item

    def _show(self) -> None:
        with self._lock:
            item, self._latest = self._latest, None
        if isinstance(item, str):
            self.status.config(text=item, foreground=RED)
        elif item is not None:
            frame, counts = item
            self._photo, _ = photo_from_frame(frame, MAX_W, MAX_H)
            self.label.config(image=self._photo)
            self.status.config(
                text="   ".join(f"{name}: {n} чел." for name, n in counts.items()) or "—",
                foreground=GREEN)
        if not self._stop.is_set():
            self.after(300, self._show)

    def _close(self) -> None:
        self._stop.set()
        self.destroy()
