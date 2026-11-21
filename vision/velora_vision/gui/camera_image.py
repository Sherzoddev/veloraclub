"""«Изображение камеры»: настройки картинки (блик от лампы на столе)."""
from __future__ import annotations

import tkinter as tk
from pathlib import Path
from tkinter import ttk

from .. import camera_image
from ..camera import mask_url
from ..settings import CameraSettings
from .common import FONT_BOLD, GREEN, GREY, RED, Background, center_on, hint


class CameraImageDialog(tk.Toplevel):
    def __init__(self, parent, bg: Background, camera: CameraSettings, backup_dir: Path):
        super().__init__(parent)
        self.bg = bg
        self.camera = camera
        self.backup_dir = backup_dir
        self.title(f"Изображение камеры: {camera.name}")
        self.transient(parent)
        center_on(self, parent, 640, 640)
        pad = {"padx": 16, "pady": 4}

        ttk.Label(self, text=f"{camera.name}  ·  {mask_url(camera.url)}", font=FONT_BOLD).pack(anchor="w", **pad)
        hint(self, "Если лампа над столом даёт блик (сукно «выгорает»), попробуйте «Подавление бликов» "
                   "и посмотрите картинку. Каждое изменение проверяется, а прежние значения можно "
                   "вернуть кнопкой ниже.", 600).pack(anchor="w", **pad)

        row = ttk.Frame(self)
        row.pack(fill="x", **pad)
        self.buttons: list[ttk.Button] = []
        for preset, text in (("hlc", "Подавление бликов (HLC)"), ("wdr", "Широкий диапазон (WDR)"),
                             ("off", "Выключить")):
            b = ttk.Button(row, text=text, command=lambda p=preset: self._apply(p))
            b.pack(side="left", padx=(0, 6))
            self.buttons.append(b)
        row2 = ttk.Frame(self)
        row2.pack(fill="x", **pad)
        for text, cmd in (("Вернуть прежние", self._restore), ("Показать настройки", self._show),
                          ("Копировать", self._copy)):
            b = ttk.Button(row2, text=text, command=cmd)
            b.pack(side="left", padx=(0, 6))
            self.buttons.append(b)

        self.status = ttk.Label(self, text="", wraplength=600, justify="left")
        self.status.pack(anchor="w", **pad)
        self.text = tk.Text(self, height=18, wrap="none", font=("Consolas", 10))
        self.text.pack(fill="both", expand=True, padx=16, pady=(4, 8))
        ttk.Button(self, text="Закрыть", command=self.destroy).pack(pady=(0, 12))
        self._show()

    def _busy(self, on: bool, message: str = "") -> None:
        for b in self.buttons:
            b.config(state="disabled" if on else "normal")
        if message:
            self.status.config(text=message, foreground=GREY)

    def _done(self, result, error) -> None:
        self._busy(False)
        if error is not None:
            return self.status.config(text=f"Ошибка: {error}", foreground=RED)
        ok, text = result
        self.status.config(text=text, foreground=GREEN if ok else RED)
        self._show(quiet=True)

    def _apply(self, preset: str) -> None:
        self._busy(True, "Меняю настройку…")
        url, folder = self.camera.url, self.backup_dir
        self.bg.run(lambda: camera_image.apply_preset(url, preset, folder), self._done)

    def _restore(self) -> None:
        self._busy(True, "Возвращаю…")
        url, folder = self.camera.url, self.backup_dir
        self.bg.run(lambda: camera_image.restore(url, folder), self._done)

    def _show(self, quiet: bool = False) -> None:
        if not quiet:
            self._busy(True, "Читаю настройки камеры…")
        url = self.camera.url
        self.bg.run(lambda: camera_image.read_options(url), self._shown)

    def _shown(self, options, error) -> None:
        self._busy(False)
        self.text.delete("1.0", "end")
        if error is not None or options is None:
            self.text.insert("end", "Камера не отдала настройки изображения.")
            return self.status.config(text="Не удалось прочитать настройки: проверьте адрес, логин, пароль.",
                                      foreground=RED)
        self.text.insert("end", camera_image.format_options(options))
        key = camera_image.mode_key(options)
        if key and not self.status.cget("text"):
            self.status.config(text=f"Сейчас: {key} = {options[key]}", foreground=GREY)

    def _copy(self) -> None:
        self.clipboard_clear()
        self.clipboard_append(self.text.get("1.0", "end").strip())
        self.status.config(text="Скопировано. Вставьте и отправьте разработчику.", foreground=GREEN)
