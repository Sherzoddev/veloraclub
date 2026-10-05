"""Small helpers shared by the windows."""
from __future__ import annotations

import base64
import queue
import sys
import threading
import tkinter as tk
from tkinter import ttk
from typing import Callable

import cv2

GREEN = "#1a9c55"
RED = "#c0392b"
GREY = "#6b7280"
ORANGE = "#d97706"

FONT = ("Segoe UI", 10) if sys.platform == "win32" else ("TkDefaultFont", 10)
FONT_BOLD = (FONT[0], 10, "bold")
FONT_BIG = (FONT[0], 15, "bold")


def apply_style(root: tk.Misc) -> None:
    style = ttk.Style(root)
    for theme in ("vista", "winnative", "clam"):
        if theme in style.theme_names():
            style.theme_use(theme)
            break
    root.option_add("*Font", FONT)
    style.configure("TLabel", font=FONT)
    style.configure("TButton", font=FONT, padding=(10, 5))
    style.configure("Big.TButton", font=FONT_BOLD, padding=(16, 9))
    style.configure("TNotebook.Tab", font=FONT, padding=(14, 7))
    style.configure("Treeview", rowheight=26, font=FONT)
    style.configure("Treeview.Heading", font=FONT_BOLD)


class Background:
    """Runs slow work (network, camera) off the window thread and brings the
    result back on it. Tk is not thread-safe, so results go through a queue
    that the window thread reads."""

    def __init__(self, root: tk.Misc):
        self.root = root
        self._q: queue.Queue = queue.Queue()
        self._poll()

    def run(self, work: Callable[[], object], done: Callable[[object, BaseException | None], None]):
        def target():
            try:
                self._q.put((done, work(), None))
            except BaseException as e:  # reported to the window, never lost
                self._q.put((done, None, e))

        threading.Thread(target=target, daemon=True).start()

    def _poll(self) -> None:
        try:
            while True:
                done, result, error = self._q.get_nowait()
                try:
                    done(result, error)
                except tk.TclError:
                    pass  # the window was closed meanwhile
        except queue.Empty:
            pass
        try:
            self.root.after(100, self._poll)
        except tk.TclError:
            pass


def photo_from_frame(frame, max_w: int, max_h: int):
    """A Tk image of an OpenCV frame, scaled to fit; also returns the scale."""
    h, w = frame.shape[:2]
    scale = min(max_w / w, max_h / h, 1.0)
    if scale < 1.0:
        frame = cv2.resize(frame, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".png", frame)
    img = tk.PhotoImage(data=base64.b64encode(buf.tobytes()))
    return img, scale


def center_on(win: tk.Toplevel, parent: tk.Misc, w: int, h: int) -> None:
    parent.update_idletasks()
    x = parent.winfo_rootx() + max(0, (parent.winfo_width() - w) // 2)
    y = parent.winfo_rooty() + max(0, (parent.winfo_height() - h) // 3)
    win.geometry(f"{w}x{h}+{x}+{y}")


def hint(parent, text: str, wrap: int = 560) -> ttk.Label:
    return ttk.Label(parent, text=text, foreground=GREY, wraplength=wrap, justify="left")
