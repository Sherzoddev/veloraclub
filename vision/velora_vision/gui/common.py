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


_COPY_PASTE_KEYS = {86: "<<Paste>>", 67: "<<Copy>>", 88: "<<Cut>>"}  # V, C, X on Windows
_ENTRY_CLASSES = ("TEntry", "Entry", "TCombobox", "TSpinbox", "Spinbox", "Text")


def install_clipboard_support(root: tk.Misc, windows: bool | None = None):
    """Copy and paste in every input field, whatever the keyboard layout.

    Tk binds Ctrl+V to the letter "v", so with a Russian layout (Ctrl sends
    "м") nothing is pasted. On Windows the key code is the same in every
    layout, so it is used there. A right-click menu is added too, since
    people look for it."""
    win = sys.platform == "win32" if windows is None else windows

    def select_all(w) -> None:
        if isinstance(w, tk.Text):
            w.tag_add("sel", "1.0", "end")
        else:
            w.select_range(0, "end")
            w.icursor("end")

    def on_ctrl_key(event):
        # With a Latin layout Tk's own binding does it: don't paste twice.
        if not win or event.keysym.lower() in ("v", "c", "x", "a"):
            return None
        w = event.widget
        if event.keycode == 65:  # A
            select_all(w)
            return "break"
        action = _COPY_PASTE_KEYS.get(event.keycode)
        if action:
            w.event_generate(action)
            return "break"
        return None

    menu = tk.Menu(root, tearoff=0)
    target: dict = {}

    def run(action: str) -> None:
        w = target.get("w")
        if w is None:
            return
        w.focus_force()
        if action == "all":
            select_all(w)
        else:
            w.event_generate(action)

    for label, action in (("Вырезать", "<<Cut>>"), ("Копировать", "<<Copy>>"),
                          ("Вставить", "<<Paste>>"), ("Выделить всё", "all")):
        menu.add_command(label=label, command=lambda a=action: run(a))

    def on_right_click(event):
        w = event.widget
        try:
            if str(w.cget("state")) == "disabled":
                return None
        except tk.TclError:
            pass
        target["w"] = w
        w.focus_set()
        menu.tk_popup(event.x_root, event.y_root)
        return "break"

    for cls in _ENTRY_CLASSES:
        root.bind_class(cls, "<Control-KeyPress>", on_ctrl_key, add="+")
        root.bind_class(cls, "<Button-3>", on_right_click, add="+")
    return on_ctrl_key  # returned for the tests


def clipboard_text(widget: tk.Misc) -> str:
    """What is on the clipboard (one line, trimmed), or "" if nothing."""
    try:
        return " ".join(widget.clipboard_get().split())
    except tk.TclError:
        return ""


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
