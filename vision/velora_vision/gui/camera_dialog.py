"""Add or change a camera: type its IP, login and password and the program
finds the stream address by itself."""
from __future__ import annotations

import tkinter as tk
from tkinter import messagebox, ttk
from typing import Optional

from .. import camera_find
from ..camera import grab_frame, mask_url
from ..settings import CameraSettings
from .common import FONT_BOLD, GREEN, GREY, RED, Background, center_on, hint, photo_from_frame

ANGLES = {
    "Сбоку или под углом (обычно так)": "foot",
    "Строго сверху над столом": "center",
}


class CameraDialog(tk.Toplevel):
    def __init__(self, parent, bg: Background, camera: Optional[CameraSettings], default_name: str):
        super().__init__(parent)
        self.bg = bg
        self.result: Optional[CameraSettings] = None
        self._editing = camera
        self._cancel = False
        self._busy = False
        self._found_url: Optional[str] = None
        self._thumb = None
        self._progress_text = ""

        self.title("Камера" if camera is None else "Изменить камеру")
        self.transient(parent)
        self.resizable(False, False)
        center_on(self, parent, 560, 640)
        self.protocol("WM_DELETE_WINDOW", self._close)
        self.grab_set()

        pad = {"padx": 16, "pady": 4}
        ttk.Label(self, text="Название").pack(anchor="w", **pad)
        self.name = tk.StringVar(value=camera.name if camera else default_name)
        ttk.Entry(self, textvariable=self.name, width=40).pack(anchor="w", **pad)

        self.mode = tk.StringVar(value="url" if camera and "://" in camera.url else "ip")
        if camera and "://" in camera.url:
            self.mode.set("url")
        modes = ttk.Frame(self)
        modes.pack(anchor="w", padx=16, pady=(12, 0))
        ttk.Radiobutton(modes, text="Ввести данные камеры", value="ip", variable=self.mode,
                        command=self._switch).pack(side="left")
        ttk.Radiobutton(modes, text="У меня есть готовый адрес (rtsp://…)", value="url",
                        variable=self.mode, command=self._switch).pack(side="left", padx=16)

        self.holder = ttk.Frame(self)
        self.holder.pack(fill="x")

        # -- by IP / login / password ---
        self.ip_box = ttk.LabelFrame(self.holder, text=" Данные камеры ")
        self.ip = tk.StringVar()
        self.user = tk.StringVar(value="admin")
        self.password = tk.StringVar()
        row = ttk.Frame(self.ip_box)
        row.pack(fill="x", padx=10, pady=(8, 2))
        ttk.Label(row, text="IP-адрес", width=10).pack(side="left")
        ttk.Entry(row, textvariable=self.ip, width=18).pack(side="left")
        self.scan_btn = ttk.Button(row, text="Найти камеры в сети", command=self._scan)
        self.scan_btn.pack(side="left", padx=8)
        self.found_list = tk.Listbox(self.ip_box, height=3, exportselection=False)
        self.found_list.bind("<<ListboxSelect>>", self._pick_found)
        r2 = ttk.Frame(self.ip_box)
        r2.pack(fill="x", padx=10, pady=2)
        self._login_row = r2
        ttk.Label(r2, text="Логин", width=10).pack(side="left")
        ttk.Entry(r2, textvariable=self.user, width=18).pack(side="left")
        r3 = ttk.Frame(self.ip_box)
        r3.pack(fill="x", padx=10, pady=2)
        ttk.Label(r3, text="Пароль", width=10).pack(side="left")
        self.pw_entry = ttk.Entry(r3, textvariable=self.password, width=18, show="•")
        self.pw_entry.pack(side="left")
        self.show_pw = tk.BooleanVar(value=False)
        ttk.Checkbutton(r3, text="показать", variable=self.show_pw,
                        command=lambda: self.pw_entry.config(show="" if self.show_pw.get() else "•")
                        ).pack(side="left", padx=8)
        hint(self.ip_box, "IP, логин и пароль такие же, как для входа в камеру через приложение "
                          "производителя. Адрес потока программа подберёт сама.", 500
             ).pack(anchor="w", padx=10, pady=(4, 8))

        # -- ready address ---
        self.url_box = ttk.LabelFrame(self.holder, text=" Адрес потока ")
        self.url = tk.StringVar(value=camera.url if camera and "://" in camera.url else "")
        ttk.Entry(self.url_box, textvariable=self.url, width=60).pack(padx=10, pady=(8, 2))
        hint(self.url_box, "Например rtsp://admin:пароль@192.168.1.64:554/Streaming/Channels/102 "
                           "(или путь к видеофайлу для проверки).", 500).pack(anchor="w", padx=10, pady=(0, 8))

        ttk.Label(self, text="Как стоит камера").pack(anchor="w", padx=16, pady=(12, 0))
        self.angle = tk.StringVar()
        values = list(ANGLES)
        cur = camera.anchor if camera else "foot"
        self.angle.set(next(k for k, v in ANGLES.items() if v == cur))
        ttk.Combobox(self, textvariable=self.angle, values=values, state="readonly",
                     width=38).pack(anchor="w", padx=16, pady=4)

        self.status = ttk.Label(self, text="", wraplength=520, justify="left")
        self.status.pack(anchor="w", padx=16, pady=(10, 2))
        self.thumb = tk.Label(self)
        self.thumb.pack(pady=2)

        btns = ttk.Frame(self)
        btns.pack(side="bottom", fill="x", padx=16, pady=14)
        self.save_btn = ttk.Button(btns, text="Проверить и сохранить", style="Big.TButton",
                                   command=self._check)
        self.save_btn.pack(side="left")
        self.force_btn = ttk.Button(btns, text="Сохранить без проверки", command=self._force_save)
        ttk.Button(btns, text="Отмена", command=self._close).pack(side="right")

        self._switch()

    # -- layout -----------------------------------------------------------
    def _switch(self) -> None:
        self.ip_box.pack_forget()
        self.url_box.pack_forget()
        box = self.ip_box if self.mode.get() == "ip" else self.url_box
        box.pack(fill="x", padx=16, pady=8)

    def _set_status(self, text: str, color: str = GREY) -> None:
        self.status.config(text=text, foreground=color)

    def _close(self) -> None:
        self._cancel = True
        self.destroy()

    # -- scan -------------------------------------------------------------
    def _scan(self) -> None:
        if self._busy:
            return
        self._busy = True
        self.scan_btn.config(state="disabled")
        self._set_status("Ищу камеры в сети…")
        self.bg.run(lambda: camera_find.scan_rtsp(cancelled=lambda: self._cancel), self._scan_done)

    def _scan_done(self, hosts, error) -> None:
        self._busy = False
        self.scan_btn.config(state="normal")
        if error or not hosts:
            self._set_status("Камеры в сети не найдены. Введите IP вручную (он указан в "
                             "приложении камеры или на её наклейке).", RED)
            return
        self.found_list.delete(0, "end")
        for h in hosts:
            self.found_list.insert("end", h)
        self.found_list.pack(fill="x", padx=10, pady=2, before=self._login_row)
        self._set_status(f"Найдено: {len(hosts)}. Выберите свою камеру в списке.", GREEN)

    def _pick_found(self, _event=None) -> None:
        sel = self.found_list.curselection()
        if sel:
            self.ip.set(self.found_list.get(sel[0]))

    # -- check ------------------------------------------------------------
    def _anchor(self) -> str:
        return ANGLES.get(self.angle.get(), "foot")

    def _check(self) -> None:
        if self._busy:
            return
        name = self.name.get().strip()
        if not name:
            return self._set_status("Впишите название камеры.", RED)
        self.force_btn.pack_forget()
        self._busy = True
        self.save_btn.config(state="disabled")
        if self.mode.get() == "url":
            url = self.url.get().strip()
            if not url:
                self._busy = False
                self.save_btn.config(state="normal")
                return self._set_status("Впишите адрес камеры.", RED)
            self._set_status("Проверяю адрес…")
            self.bg.run(lambda: self._probe_url(url), self._checked)
        else:
            ip = self.ip.get().strip()
            if not ip:
                self._busy = False
                self.save_btn.config(state="normal")
                return self._set_status("Впишите IP-адрес камеры.", RED)
            self._set_status("Подбираю адрес потока… это может занять до минуты.")
            self._progress_text = ""
            self.bg.run(lambda: self._probe_ip(ip), self._checked)
            self.after(300, self._poll_progress)

    def _probe_url(self, url: str):
        frame = grab_frame(url, 6000, 5)
        if frame is None:
            return None
        h, w = frame.shape[:2]
        return camera_find.Found(url, "ваш адрес", w, h), frame

    def _probe_ip(self, ip: str):
        found = camera_find.autodetect(
            ip, self.user.get().strip(), self.password.get(),
            progress=lambda i, n, label: self._progress(i, n, label),
            cancelled=lambda: self._cancel,
        )
        if found is None:
            return None
        return found, grab_frame(found.url, 4000, 3)

    def _progress(self, i: int, n: int, label: str) -> None:
        # Worker thread: only sets a plain attribute; the window reads it.
        self._progress_text = f"Пробую вариант {i} из {n}: {label}…"

    def _poll_progress(self) -> None:
        if self._busy and self._progress_text:
            self._set_status(self._progress_text)
        if self._busy:
            self.after(300, self._poll_progress)

    def _checked(self, result, error) -> None:
        self._busy = False
        self.save_btn.config(state="normal")
        if error or result is None:
            self._set_status(
                "Картинку получить не удалось. Проверьте:\n"
                "• IP, логин и пароль (как для входа в камеру);\n"
                "• что компьютер и камера в одной сети;\n"
                "• что в настройках камеры включён RTSP;\n"
                "• что камера не занята другой программой (часть камер даёт только 1–2 потока).",
                RED)
            self.force_btn.pack(side="left", padx=8)
            return
        found, frame = result
        self._found_url = found.url
        self._set_status(f"✓ Картинка получена: {found.width}×{found.height} ({found.label}).", GREEN)
        if frame is not None:
            self._thumb, _ = photo_from_frame(frame, 300, 170)
            self.thumb.config(image=self._thumb)
        self.after(600, self._finish_ok)

    def _finish_ok(self) -> None:
        self._save(self._found_url or "")

    def _force_save(self) -> None:
        url = self.url.get().strip() if self.mode.get() == "url" else self._guess_url()
        if not url:
            return self._set_status("Нечего сохранять: впишите IP или адрес.", RED)
        if not messagebox.askyesno(
            "Сохранить без проверки",
            "Камера не отвечает. Сохранить как есть? Потом можно изменить.", parent=self):
            return
        self._save(url)

    def _guess_url(self) -> str:
        ip = self.ip.get().strip()
        if not ip:
            return ""
        return camera_find.build_url(ip, self.user.get().strip(), self.password.get(),
                                     camera_find.PATHS[0][1])

    def _save(self, url: str) -> None:
        cam = self._editing
        self.result = CameraSettings(
            id=cam.id if cam else "",
            name=self.name.get().strip(),
            url=url,
            anchor=self._anchor(),
        )
        self.destroy()

    def shown_url(self) -> str:
        return mask_url(self._found_url or "")
