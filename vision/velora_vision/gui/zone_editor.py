"""Draw the zone of every table on the camera picture: the area around the
table where people playing at it stand."""
from __future__ import annotations

import tkinter as tk
from tkinter import ttk
from typing import Callable, Optional

from ..camera import grab_frame
from ..settings import CameraSettings
from .common import FONT_BOLD, GREEN, GREY, ORANGE, RED, Background, center_on, hint, photo_from_frame

MAX_W, MAX_H = 860, 540
DONE_COLOR = "#2ecc71"
FELT_COLOR = "#3498db"
DRAW_COLOR = "#f1c40f"
OTHER_COLOR = "#95a5a6"

KINDS = {
    "people": "Где стоят играющие (для подсчёта людей)",
    "felt": "Сукно стола (для записи ударов)",
}
HELP = {
    "people": "Кликайте по углам места, где стоят играющие: пол вокруг стола, а не только сукно.",
    "felt": "Кликайте по четырём углам игрового поля: только сукно, без бортов и людей вокруг.",
}


class ZoneEditor(tk.Toplevel):
    def __init__(
        self,
        parent,
        bg: Background,
        camera: CameraSettings,
        tables: list[str],
        people: dict[str, list[list[float]]],
        felt: dict[str, list[list[float]]],
        on_save: Callable[[dict, dict], None],
    ):
        super().__init__(parent)
        self.bg = bg
        self.on_save = on_save
        self.all = {
            "people": {k: [list(p) for p in v] for k, v in people.items()},
            "felt": {k: [list(p) for p in v] for k, v in felt.items()},
        }
        extra = [z for kind in self.all.values() for z in kind if z not in tables]
        self.names = list(tables) + list(dict.fromkeys(extra))
        self.kind = tk.StringVar(value="people")
        self.current: Optional[str] = None
        self.points: list[tuple[float, float]] = []
        self.drawing = False
        self.photo = None
        self.img_w = self.img_h = 0

        self.title(f"Зоны столов: {camera.name}")
        self.transient(parent)
        center_on(self, parent, MAX_W + 330, MAX_H + 170)
        self.minsize(960, 600)
        self.grab_set()

        left = ttk.Frame(self, width=290)
        left.pack(side="left", fill="y", padx=(12, 6), pady=12)
        ttk.Label(left, text="Что рисуем", font=FONT_BOLD).pack(anchor="w")
        for key, text in KINDS.items():
            ttk.Radiobutton(left, text=text, value=key, variable=self.kind, command=self._kind_changed
                            ).pack(anchor="w", pady=1)
        ttk.Label(left, text="Столы клуба", font=FONT_BOLD).pack(anchor="w", pady=(10, 0))
        self.listbox = tk.Listbox(left, height=11, width=34, exportselection=False, activestyle="none")
        self.listbox.pack(fill="y", pady=6)
        self.listbox.bind("<<ListboxSelect>>", self._select)
        ttk.Button(left, text="Готово (Enter)", command=self._finish).pack(fill="x", pady=2)
        ttk.Button(left, text="Убрать точку (Backspace)", command=self._undo).pack(fill="x", pady=2)
        ttk.Button(left, text="Стереть зону стола", command=self._erase).pack(fill="x", pady=2)

        right = ttk.Frame(self)
        right.pack(side="left", fill="both", expand=True, padx=(6, 12), pady=12)
        self.help = hint(right, "", 760)
        self.help.pack(anchor="w")
        self.status = ttk.Label(right, text="Получаю картинку с камеры…", foreground=GREY)
        self.status.pack(anchor="w", pady=(4, 4))
        self.canvas = tk.Canvas(right, width=MAX_W, height=MAX_H, bg="#202124", highlightthickness=0)
        self.canvas.pack()
        self.canvas.bind("<Button-1>", self._click)
        self.canvas.bind("<Double-Button-1>", lambda e: self._finish())
        self.bind("<Return>", lambda e: self._finish())
        self.bind("<BackSpace>", lambda e: self._undo())

        bottom = ttk.Frame(right)
        bottom.pack(fill="x", pady=(10, 0))
        self.save_btn = ttk.Button(bottom, text="Сохранить и закрыть", style="Big.TButton",
                                   command=self._save, state="disabled")
        self.save_btn.pack(side="left")
        ttk.Button(bottom, text="Отмена", command=self.destroy).pack(side="right")

        self._refresh_list()
        bg.run(lambda: grab_frame(camera.url, 7000, 6, camera.rotate, camera.widen), self._got_frame)

    # -- picture ----------------------------------------------------------
    def _got_frame(self, frame, error) -> None:
        if error or frame is None:
            self.status.config(
                text="Не удалось получить картинку с камеры. Проверьте камеру и попробуйте снова.",
                foreground=RED)
            return
        self.photo, _ = photo_from_frame(frame, MAX_W, MAX_H)
        self.img_w, self.img_h = self.photo.width(), self.photo.height()
        self.canvas.config(width=self.img_w, height=self.img_h)
        self.save_btn.config(state="normal")
        self._set_status()
        self._redraw()

    @property
    def zones(self) -> dict:
        return self.all[self.kind.get()]

    def _kind_changed(self) -> None:
        self.points, self.drawing = [], False
        self._refresh_list()
        self._set_status()
        self._redraw()

    def _set_status(self) -> None:
        self.help.config(text="1. Выберите стол слева.   2. " + HELP[self.kind.get()]
                              + "   3. Нажмите «Готово» (или Enter, или двойной клик).")
        if not self.names:
            self.status.config(text="Нет столов. Проверьте токен бота на вкладке «Бот».",
                               foreground=RED)
        elif self.current is None:
            self.status.config(text="Выберите стол в списке слева.", foreground=GREY)
        elif self.drawing:
            self.status.config(
                text=f"{self.current}: точек {len(self.points)}. Нужно минимум 3, затем «Готово».",
                foreground=ORANGE)
        elif self.current in self.zones:
            self.status.config(text=f"{self.current}: зона есть. Кликните по картинке, чтобы "
                                    "нарисовать заново.", foreground=GREEN)
        else:
            self.status.config(text=f"{self.current}: кликайте по углам зоны.", foreground=GREY)

    # -- list -------------------------------------------------------------
    def _refresh_list(self) -> None:
        sel = self.current
        self.listbox.delete(0, "end")
        for i, name in enumerate(self.names):
            marks = (f"люди {'✓' if name in self.all['people'] else '–'}   "
                     f"сукно {'✓' if name in self.all['felt'] else '–'}")
            self.listbox.insert("end", f"{name}   ({marks})")
            if name == sel:
                self.listbox.selection_set(i)

    def _select(self, _event=None) -> None:
        idx = self.listbox.curselection()
        if not idx:
            return
        self.current = self.names[idx[0]]
        self.points, self.drawing = [], False
        self._set_status()
        self._redraw()

    # -- drawing ----------------------------------------------------------
    def _click(self, event) -> None:
        if self.photo is None:
            return
        if self.current is None:
            self.status.config(text="Сначала выберите стол в списке слева.", foreground=RED)
            return
        x = min(max(event.x, 0), self.img_w)
        y = min(max(event.y, 0), self.img_h)
        self.drawing = True
        self.points.append((x, y))
        self._set_status()
        self._redraw()

    def _undo(self) -> None:
        if self.points:
            self.points.pop()
            self.drawing = bool(self.points)
            self._set_status()
            self._redraw()

    def _finish(self) -> None:
        if self.current is None or not self.drawing:
            return
        if len(self.points) < 3:
            self.status.config(text="Нужно минимум 3 точки.", foreground=RED)
            return
        self.zones[self.current] = [
            [round(x / self.img_w, 4), round(y / self.img_h, 4)] for x, y in self.points
        ]
        self.points, self.drawing = [], False
        self._refresh_list()
        self._set_status()
        self._redraw()

    def _erase(self) -> None:
        if self.current and self.current in self.zones:
            del self.zones[self.current]
        self.points, self.drawing = [], False
        self._refresh_list()
        self._set_status()
        self._redraw()

    def _redraw(self) -> None:
        c = self.canvas
        c.delete("all")
        if self.photo is None:
            return
        c.create_image(0, 0, anchor="nw", image=self.photo)
        for kind, zones in self.all.items():
            mine = kind == self.kind.get()
            base = DONE_COLOR if kind == "people" else FELT_COLOR
            for name, poly in zones.items():
                coords = [v for x, y in poly for v in (x * self.img_w, y * self.img_h)]
                active = mine and name == self.current and not self.drawing
                c.create_polygon(coords, outline=base if (mine or active) else OTHER_COLOR,
                                 fill="", width=3 if active else 2, dash=() if mine else (4, 3))
                c.create_text(coords[0] + 4, coords[1] - 10, text=name, anchor="w",
                              fill=base if mine else "#ecf0f1", font=FONT_BOLD)
        if self.points:
            flat = [v for p in self.points for v in p]
            if len(self.points) >= 2:
                c.create_line(*flat, fill=DRAW_COLOR, width=3)
            for x, y in self.points:
                c.create_oval(x - 4, y - 4, x + 4, y + 4, fill=DRAW_COLOR, outline="")

    # -- finish -----------------------------------------------------------
    def _save(self) -> None:
        if self.drawing and len(self.points) >= 3:
            self._finish()  # the person forgot to press "Готово"
        self.on_save(self.all["people"], self.all["felt"])
        self.destroy()
