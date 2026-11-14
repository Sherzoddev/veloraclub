"""The program window: a few tabs, one big button."""
from __future__ import annotations

import logging
import os
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Optional

from .. import __version__, autostart
from .. import settings as settings_mod
from ..camera import mask_url
from ..runtime import FAILED, RUNNING, STARTING, STOPPED, Controller, LogBuffer
from ..settings import CameraSettings, Settings
from .camera_dialog import CameraDialog
from .common import (FONT_BIG, FONT_BOLD, GREEN, GREY, ORANGE, RED, Background,
                     apply_style, clipboard_text, hint, install_clipboard_support)

TAB_HOME, TAB_BOT, TAB_CAMERAS, TAB_SETTINGS, TAB_LOG = range(5)
STEP_TEXTS = ["Токен бота владельца", "Камера", "У камеры выбран стол"]


class MainWindow:
    def __init__(self, root: tk.Tk, folder: Path, controller: Optional[Controller] = None,
                 minimized: bool = False):
        self.root = root
        self.folder = folder
        self.settings: Settings = settings_mod.load(folder)
        self.controller = controller or Controller(lambda: self.settings, folder / "tmp")
        self.bg = Background(root)
        self._save_job = None
        self._log_len = -1
        self.log = LogBuffer()
        logging.getLogger().addHandler(self.log)

        root.title(f"Velora Vision {__version__}: ролики по просьбе клиентов")
        root.minsize(780, 560)
        root.geometry("840x620")
        apply_style(root)
        install_clipboard_support(root)
        root.protocol("WM_DELETE_WINDOW", self._on_close)
        self._menu()

        self.nb = ttk.Notebook(root)
        self.nb.pack(fill="both", expand=True, padx=10, pady=(10, 4))
        self.tab_home = ttk.Frame(self.nb)
        self.tab_bot = ttk.Frame(self.nb)
        self.tab_cams = ttk.Frame(self.nb)
        self.tab_set = ttk.Frame(self.nb)
        self.tab_log = ttk.Frame(self.nb)
        for tab, title in ((self.tab_home, "Главная"), (self.tab_bot, "1. Бот"),
                           (self.tab_cams, "2. Камеры"), (self.tab_set, "Настройки"),
                           (self.tab_log, "Журнал")):
            self.nb.add(tab, text=title)
        self._build_home()
        self._build_bot()
        self._build_cameras()
        self._build_settings()
        self._build_log()

        ttk.Label(root, text="Настройки сохраняются сами. Окно можно свернуть: программа "
                             "продолжит работать.", foreground=GREY).pack(anchor="w", padx=14, pady=(0, 8))

        self._refresh_all()
        self._tick()

        if minimized:
            root.iconify()
        if self.settings.run_on_open and not self.settings.problems():
            self.start()
        else:
            self.nb.select(self._first_incomplete_tab())

    # ================= menu =================
    def _menu(self) -> None:
        bar = tk.Menu(self.root)
        file_menu = tk.Menu(bar, tearoff=0)
        file_menu.add_command(label="Открыть папку с данными", command=self._open_folder)
        file_menu.add_separator()
        file_menu.add_command(label="Выход (программа остановится)", command=self._quit)
        bar.add_cascade(label="Файл", menu=file_menu)
        self.root.config(menu=bar)

    def _open_folder(self) -> None:
        if sys.platform == "win32":  # pragma: no cover
            os.startfile(self.folder)  # type: ignore[attr-defined]

    # ================= home =================
    def _build_home(self) -> None:
        t = self.tab_home
        top = ttk.Frame(t)
        top.pack(fill="x", padx=16, pady=(16, 8))
        self.status_dot = tk.Label(top, text="●", font=FONT_BIG, fg=GREY)
        self.status_dot.pack(side="left")
        self.status_text = ttk.Label(top, text="Остановлено", font=FONT_BIG, wraplength=520)
        self.status_text.pack(side="left", padx=8)
        self.start_btn = ttk.Button(top, text="▶  Запустить", style="Big.TButton", command=self._toggle)
        self.start_btn.pack(side="right")

        self.steps = ttk.LabelFrame(t, text=" Что нужно настроить ")
        self.steps.pack(fill="x", padx=16, pady=8)
        self.step_labels: list[ttk.Label] = []
        for text, tab in zip(STEP_TEXTS, (TAB_BOT, TAB_CAMERAS, TAB_CAMERAS)):
            row = ttk.Frame(self.steps)
            row.pack(fill="x", padx=10, pady=3)
            lab = ttk.Label(row, text=f"✗  {text}", width=48)
            lab.pack(side="left")
            ttk.Button(row, text="Открыть", command=lambda tb=tab: self.nb.select(tb)).pack(side="left")
            self.step_labels.append(lab)

        ttk.Label(t, text="Как это работает", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(14, 2))
        hint(t, "Клиент в боте клуба нажимает «🎬 Мои удары», выбирает стол, день и время. "
                "Программа берёт этот момент из записи камеры (с карты памяти камеры или "
                "регистратора, как в SmartPSS) и бот присылает клиенту видео. Программа должна "
                "быть запущена, а компьютер включён.", 760).pack(anchor="w", padx=16)
        self.count_label = ttk.Label(t, text="", font=FONT_BOLD)
        self.count_label.pack(anchor="w", padx=16, pady=(16, 0))

    # ================= bot =================
    def _build_bot(self) -> None:
        t = self.tab_bot
        pad = {"padx": 16, "pady": 4}
        ttk.Label(t, text="Токен бота владельца", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(16, 2))
        row = ttk.Frame(t)
        row.pack(anchor="w", **pad)
        self.token = tk.StringVar(value=self.settings.bot_token)
        self.token_entry = ttk.Entry(row, textvariable=self.token, width=58, show="•")
        self.token_entry.pack(side="left")
        ttk.Button(row, text="Вставить", command=self._paste_token).pack(side="left", padx=(8, 0))
        self.show_token = tk.BooleanVar(value=False)
        ttk.Checkbutton(row, text="показать", variable=self.show_token,
                        command=lambda: self.token_entry.config(
                            show="" if self.show_token.get() else "•")).pack(side="left", padx=8)
        hint(t, "Токен выдаёт @BotFather. Это тот бот, в котором вы смотрите отчёты клуба. "
                "По нему программа узнаёт, какой это клуб."
             ).pack(anchor="w", **pad)
        row2 = ttk.Frame(t)
        row2.pack(anchor="w", **pad)
        self.check_btn = ttk.Button(row2, text="Проверить подключение", style="Big.TButton",
                                    command=self._check_bot)
        self.check_btn.pack(side="left")
        self.bot_result = ttk.Label(t, text="", wraplength=700, justify="left")
        self.bot_result.pack(anchor="w", padx=16, pady=8)
        self.token.trace_add("write", lambda *_: self._changed())

    def _paste_token(self) -> None:
        """A button, for people who don't know the keys (or the layout is off)."""
        text = clipboard_text(self.root)
        if not text:
            return self._bot_msg("В буфере обмена ничего нет. Скопируйте токен (в Telegram: "
                                 "правая кнопка мыши на токене → «Копировать»).", RED)
        self.token.set(text)
        self._bot_msg("Токен вставлен. Нажмите «Проверить подключение».", GREY)

    def _check_bot(self) -> None:
        self._collect()
        if not self.settings.bot_token.strip():
            return self._bot_msg("Впишите токен бота.", RED)
        self.check_btn.config(state="disabled")
        self._bot_msg("Проверяю…", GREY)
        s = self.settings
        self.bg.run(lambda: self.controller.check_connection(s), self._check_done)

    def _check_done(self, snap, error) -> None:
        self.check_btn.config(state="normal")
        if error is not None:
            return self._bot_msg(str(error), RED)
        self._bot_msg(f"✓ Клуб «{snap.club_name}», столов в программе: {len(snap.resources)}.", GREEN)
        self._refresh_all()

    def _bot_msg(self, text: str, color: str) -> None:
        self.bot_result.config(text=text, foreground=color)

    # ================= cameras =================
    def _build_cameras(self) -> None:
        t = self.tab_cams
        cols = ("name", "table", "addr")
        self.cam_tree = ttk.Treeview(t, columns=cols, show="headings", height=9, selectmode="browse")
        for c, title, w in (("name", "Камера", 170), ("table", "Стол", 170), ("addr", "Адрес", 340)):
            self.cam_tree.heading(c, text=title)
            self.cam_tree.column(c, width=w, anchor="w")
        self.cam_tree.pack(fill="both", expand=True, padx=16, pady=(16, 6))
        self.cam_tree.bind("<Double-1>", lambda e: self._edit_camera())
        row = ttk.Frame(t)
        row.pack(fill="x", padx=16, pady=4)
        ttk.Button(row, text="Добавить камеру…", style="Big.TButton",
                   command=self._add_camera).pack(side="left")
        ttk.Button(row, text="Изменить…", command=self._edit_camera).pack(side="left", padx=6)
        ttk.Button(row, text="Удалить", command=self._delete_camera).pack(side="left")
        row2 = ttk.Frame(t)
        row2.pack(fill="x", padx=16, pady=(6, 4))
        self.check_cam_btn = ttk.Button(row2, text="Проверить запись камеры", command=self._check_camera)
        self.check_cam_btn.pack(side="left")
        self.cam_result = ttk.Label(t, text="", wraplength=760, justify="left")
        self.cam_result.pack(anchor="w", padx=16, pady=(2, 4))
        hint(t, "У каждой камеры укажите, какой стол она снимает (название как в программе "
                "Velora Club). «Проверить запись камеры» берёт несколько секунд из записи "
                "десятиминутной давности: так видно, что камера отдаёт архив.", 760
             ).pack(anchor="w", padx=16, pady=(0, 12))

    def _selected_camera(self) -> Optional[CameraSettings]:
        sel = self.cam_tree.selection()
        if not sel:
            messagebox.showinfo("Камера", "Выберите камеру в списке.", parent=self.root)
            return None
        return self.settings.camera(sel[0])

    def _table_names(self) -> list[str]:
        club = self.controller.club
        return [r.name for r in club.resources] if club else []

    def _add_camera(self) -> None:
        self._load_tables_then(lambda: self._open_camera_dialog(None))

    def _edit_camera(self) -> None:
        cam = self._selected_camera()
        if cam:
            self._load_tables_then(lambda: self._open_camera_dialog(cam))

    def _load_tables_then(self, then) -> None:
        """The list of tables comes from the server; fetch it once, quietly."""
        if self._table_names() or not self.settings.bot_token.strip():
            return then()
        self._collect()
        s = self.settings
        self.bg.run(lambda: self.controller.check_connection(s), lambda snap, err: then())

    def _open_camera_dialog(self, cam: Optional[CameraSettings]) -> None:
        dlg = CameraDialog(self.root, self.bg, cam, f"Камера {len(self.settings.cameras) + 1}",
                           self._table_names())
        self.root.wait_window(dlg)
        if not dlg.result:
            return
        if cam is None:
            new = dlg.result
            new.id = self.settings.new_camera_id()
            self.settings.cameras.append(new)
        else:
            cam.name, cam.url, cam.table = dlg.result.name, dlg.result.url, dlg.result.table
        self._save_now()
        self._refresh_all()

    def _delete_camera(self) -> None:
        cam = self._selected_camera()
        if cam and messagebox.askyesno("Удалить камеру", f"Удалить «{cam.name}»?", parent=self.root):
            self.settings.cameras.remove(cam)
            self._save_now()
            self._refresh_all()

    def _check_camera(self) -> None:
        cam = self._selected_camera()
        if not cam:
            return
        self.check_cam_btn.config(state="disabled")
        self.cam_result.config(text="Проверяю… это может занять до минуты.", foreground=GREY)
        self.bg.run(lambda: self.controller.check_camera(cam.url), self._check_camera_done)

    def _check_camera_done(self, result, error) -> None:
        self.check_cam_btn.config(state="normal")
        if error is not None:
            return self.cam_result.config(text=f"Ошибка: {error}", foreground=RED)
        ok, text = result
        self.cam_result.config(text=text, foreground=GREEN if ok else RED)

    # ================= settings =================
    def _build_settings(self) -> None:
        t = self.tab_set
        ttk.Label(t, text="Запуск", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(16, 0))
        self.autostart = tk.BooleanVar(value=self.settings.autostart)
        ttk.Checkbutton(t, text="Запускать вместе с Windows", variable=self.autostart,
                        command=self._changed,
                        state="normal" if autostart.is_supported() else "disabled"
                        ).pack(anchor="w", padx=28, pady=2)
        self.run_on_open = tk.BooleanVar(value=self.settings.run_on_open)
        ttk.Checkbutton(t, text="Начинать работу сразу при открытии программы",
                        variable=self.run_on_open, command=self._changed).pack(anchor="w", padx=28, pady=2)

    # ================= log =================
    def _build_log(self) -> None:
        t = self.tab_log
        self.log_text = tk.Text(t, state="disabled", wrap="word", height=20)
        sb = ttk.Scrollbar(t, command=self.log_text.yview)
        self.log_text.config(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y", pady=12)
        self.log_text.pack(fill="both", expand=True, padx=(16, 0), pady=12)

    # ================= state =================
    def _collect(self) -> None:
        """Window -> settings."""
        s = self.settings
        s.bot_token = self.token.get().strip()
        s.autostart = bool(self.autostart.get())
        s.run_on_open = bool(self.run_on_open.get())

    def _changed(self) -> None:
        if self._save_job:
            self.root.after_cancel(self._save_job)
        self._save_job = self.root.after(500, self._save_now)

    def _save_now(self) -> None:
        self._save_job = None
        self._collect()
        settings_mod.save(self.folder, self.settings)
        autostart.set_enabled(self.settings.autostart)
        self._refresh_steps()

    def _first_incomplete_tab(self) -> int:
        s = self.settings
        if not s.bot_token.strip():
            return TAB_BOT
        if not s.cameras or not any(c.table.strip() for c in s.cameras):
            return TAB_CAMERAS
        return TAB_HOME

    def _refresh_all(self) -> None:
        self._refresh_cameras()
        self._refresh_steps()

    def _refresh_cameras(self) -> None:
        self.cam_tree.delete(*self.cam_tree.get_children())
        for c in self.settings.cameras:
            self.cam_tree.insert("", "end", iid=c.id,
                                 values=(c.name, c.table or "— выберите —", mask_url(c.url)))

    def _refresh_steps(self) -> None:
        s = self.settings
        done = [bool(s.bot_token.strip()), bool(s.cameras), any(c.table.strip() for c in s.cameras)]
        for lab, ok, text in zip(self.step_labels, done, STEP_TEXTS):
            lab.config(text=f"{'✓' if ok else '✗'}  {text}", foreground=GREEN if ok else RED)

    # ================= start / stop =================
    def _toggle(self) -> None:
        if self.controller.is_active():
            self.controller.stop()
        else:
            self.start()

    def start(self) -> None:
        self._save_now()
        problems = self.settings.problems()
        if problems:
            messagebox.showinfo("Нужно настроить", "\n".join(problems), parent=self.root)
            self.nb.select(self._first_incomplete_tab())
            return
        self.controller.start()

    def _tick(self) -> None:
        c = self.controller
        color = {RUNNING: GREEN, STARTING: ORANGE, FAILED: RED, STOPPED: GREY}[c.state]
        self.status_dot.config(fg=color)
        self.status_text.config(text=c.message)
        self.start_btn.config(text="■  Остановить" if c.is_active() else "▶  Запустить")
        w = c.worker
        self.count_label.config(
            text=f"Роликов отправлено клиентам: {w.sent}, не получилось: {w.failed}"
            if w is not None and c.state == RUNNING else "")
        self._refresh_log()
        self.root.after(1000, self._tick)

    def _refresh_log(self) -> None:
        if self.nb.index(self.nb.select()) != TAB_LOG:
            return
        n = len(self.log.lines)
        if n == self._log_len:
            return
        self._log_len = n
        self.log_text.config(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.insert("end", "\n".join(self.log.lines))
        self.log_text.see("end")
        self.log_text.config(state="disabled")

    # ================= closing =================
    def _on_close(self) -> None:
        if self.controller.is_active():
            answer = messagebox.askyesnocancel(
                "Velora Vision",
                "Программа работает.\n\nДа: свернуть окно, программа продолжит работать.\n"
                "Нет: закрыть программу, ролики по просьбам клиентов перестанут приходить.",
                parent=self.root)
            if answer is None:
                return
            if answer:
                self.root.iconify()
                return
        self._quit()

    def _quit(self) -> None:
        self._save_now()
        self.controller.stop()
        self.root.destroy()
