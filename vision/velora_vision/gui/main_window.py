"""The program window: a few tabs, one big button."""
from __future__ import annotations

import logging
import os
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Optional

from .. import __version__, autostart, messages
from .. import settings as settings_mod
from ..camera import mask_url
from ..config import CameraCfg, TableCfg
from ..runtime import FAILED, RUNNING, STARTING, STOPPED, Controller, LogBuffer
from ..sessions import SessionsError
from ..settings import CameraSettings, Settings
from .camera_dialog import CameraDialog
from .common import (FONT_BIG, FONT_BOLD, GREEN, GREY, ORANGE, RED, Background,
                     apply_style, hint)
from .preview import PreviewWindow
from .zone_editor import ZoneEditor

TAB_HOME, TAB_BOT, TAB_CAMERAS, TAB_SETTINGS, TAB_LOG = range(5)


class MainWindow:
    def __init__(self, root: tk.Tk, folder: Path, controller: Optional[Controller] = None,
                 minimized: bool = False):
        self.root = root
        self.folder = folder
        self.settings: Settings = settings_mod.load(folder)
        self.controller = controller or Controller(lambda: self.settings, folder / "snapshots")
        self.bg = Background(root)
        self._save_job = None
        self._log_len = -1
        self.log = LogBuffer()
        logging.getLogger().addHandler(self.log)

        root.title(f"Velora Vision {__version__}: камеры в клубе")
        root.minsize(780, 660)
        root.geometry("840x720")
        apply_style(root)
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

        ttk.Label(root, text="Настройки сохраняются сами. Окно можно свернуть: слежение "
                             "продолжится.", foreground=GREY).pack(anchor="w", padx=14, pady=(0, 8))

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
        file_menu.add_command(label="Выход (слежение остановится)", command=self._quit)
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
        self.status_text = ttk.Label(top, text="Остановлено", font=FONT_BIG)
        self.status_text.pack(side="left", padx=8)
        self.start_btn = ttk.Button(top, text="▶  Запустить слежение", style="Big.TButton",
                                    command=self._toggle)
        self.start_btn.pack(side="right")

        self.steps = ttk.LabelFrame(t, text=" Что нужно настроить ")
        self.steps.pack(fill="x", padx=16, pady=8)
        self.step_labels: list[ttk.Label] = []
        for i, (text, tab) in enumerate((("Токен бота владельца", TAB_BOT),
                                         ("Камера", TAB_CAMERAS),
                                         ("Зоны столов на картинке камеры", TAB_CAMERAS))):
            row = ttk.Frame(self.steps)
            row.pack(fill="x", padx=10, pady=3)
            lab = ttk.Label(row, text=f"✗  {text}", width=48)
            lab.pack(side="left")
            ttk.Button(row, text="Открыть", command=lambda tb=tab: self.nb.select(tb)).pack(side="left")
            self.step_labels.append(lab)
        self._step_texts = ["Токен бота владельца", "Камера", "Зоны столов на картинке камеры"]

        self.clips_label = ttk.Label(t, text="", foreground=GREY)
        self.clips_label.pack(anchor="w", padx=16)
        ttk.Label(t, text="Столы сейчас", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(12, 2))
        cols = ("table", "people", "session")
        self.live = ttk.Treeview(t, columns=cols, show="headings", height=8)
        for c, title, w in (("table", "Стол", 220), ("people", "Людей у стола", 140),
                            ("session", "Сеанс в программе", 220)):
            self.live.heading(c, text=title)
            self.live.column(c, width=w, anchor="w")
        self.live.pack(fill="both", expand=True, padx=16, pady=(0, 12))

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
        self.show_token = tk.BooleanVar(value=False)
        ttk.Checkbutton(row, text="показать", variable=self.show_token,
                        command=lambda: self.token_entry.config(
                            show="" if self.show_token.get() else "•")).pack(side="left", padx=8)
        hint(t, "Токен выдаёт @BotFather. Это тот бот, в котором вы смотрите отчёты клуба. "
                "Он же определит клуб и чат, куда придут сообщения.").pack(anchor="w", **pad)
        row2 = ttk.Frame(t)
        row2.pack(anchor="w", **pad)
        self.check_btn = ttk.Button(row2, text="Проверить подключение", style="Big.TButton",
                                    command=self._check_bot)
        self.check_btn.pack(side="left")
        self.test_btn = ttk.Button(row2, text="Отправить тестовое сообщение", command=self._send_test)
        self.test_btn.pack(side="left", padx=10)
        self.bot_result = ttk.Label(t, text="", wraplength=700, justify="left")
        self.bot_result.pack(anchor="w", padx=16, pady=8)

        ttk.Label(t, text="Дополнительный чат (необязательно)", font=FONT_BOLD).pack(
            anchor="w", padx=16, pady=(20, 2))
        self.extra = tk.StringVar(value=self.settings.extra_chat_ids)
        ttk.Entry(t, textvariable=self.extra, width=30).pack(anchor="w", **pad)
        hint(t, "Сообщения всегда приходят владельцу. Если нужно ещё и в группу или канал: "
                "добавьте бота в группу администратором и впишите номер группы (начинается "
                "с -100). Несколько номеров через запятую.").pack(anchor="w", **pad)
        ttk.Label(t, text="Канал для роликов с ударами", font=FONT_BOLD).pack(
            anchor="w", padx=16, pady=(20, 2))
        row3 = ttk.Frame(t)
        row3.pack(anchor="w", **pad)
        self.clips_chat = tk.StringVar(value=self.settings.clips_chat_id)
        ttk.Entry(row3, textvariable=self.clips_chat, width=30).pack(side="left")
        self.chan_btn = ttk.Button(row3, text="Проверить канал", command=self._check_channel)
        self.chan_btn.pack(side="left", padx=10)
        hint(t, "Номер канала (начинается с -100) или его имя вида @mychannel. Бот должен быть "
                "администратором канала. Ролики приходят сюда и сразу удаляются с компьютера."
             ).pack(anchor="w", **pad)
        self.chan_result = ttk.Label(t, text="", wraplength=700, justify="left")
        self.chan_result.pack(anchor="w", padx=16, pady=4)
        self.token.trace_add("write", lambda *_: self._changed())
        self.extra.trace_add("write", lambda *_: self._changed())
        self.clips_chat.trace_add("write", lambda *_: self._changed())

    def _check_channel(self) -> None:
        self._collect()
        self.chan_btn.config(state="disabled")
        self.chan_result.config(text="Отправляю…", foreground=GREY)
        s = self.settings
        self.bg.run(lambda: self.controller.send_channel_test(s), self._channel_done)

    def _channel_done(self, text, error) -> None:
        self.chan_btn.config(state="normal")
        ok = error is None and "отправлено" in str(text)
        self.chan_result.config(text=str(error or text), foreground=GREEN if ok else RED)

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
        chat = ("✓ сообщения придут владельцу в Telegram" if snap.owner_chat_id is not None
                else "⚠ владелец ещё не запускал бота: откройте его в Telegram и нажмите «Старт»")
        self._bot_msg(f"✓ Клуб «{snap.club_name}», столов в программе: {len(snap.resources)}.\n"
                      f"{chat}.", GREEN if snap.owner_chat_id is not None else ORANGE)
        self._refresh_all()

    def _send_test(self) -> None:
        self._collect()
        if not self.settings.bot_token.strip():
            return self._bot_msg("Впишите токен бота.", RED)
        self.test_btn.config(state="disabled")
        s = self.settings
        self.bg.run(lambda: self.controller.send_test(s), self._test_done)

    def _test_done(self, text, error) -> None:
        self.test_btn.config(state="normal")
        if error is not None:
            return self._bot_msg(str(error), RED)
        self._bot_msg(str(text), GREEN if "отправлено" in str(text) else ORANGE)

    def _bot_msg(self, text: str, color: str) -> None:
        self.bot_result.config(text=text, foreground=color)

    # ================= cameras =================
    def _build_cameras(self) -> None:
        t = self.tab_cams
        cols = ("name", "addr", "zones")
        self.cam_tree = ttk.Treeview(t, columns=cols, show="headings", height=9, selectmode="browse")
        for c, title, w in (("name", "Камера", 170), ("addr", "Адрес", 320), ("zones", "Зоны", 200)):
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
        row2.pack(fill="x", padx=16, pady=(6, 14))
        ttk.Button(row2, text="Зоны столов…", style="Big.TButton",
                   command=self._zones).pack(side="left")
        ttk.Button(row2, text="Как видит программа…", command=self._preview).pack(side="left", padx=6)
        self.testclip_btn = ttk.Button(row2, text="Проверочный ролик в канал",
                                       command=self._test_clip)
        self.testclip_btn.pack(side="left")
        hint(t, "Порядок: добавьте камеру, затем «Зоны столов»: обведите мышью место вокруг "
                "каждого стола. Потом «Как видит программа» покажет, правильно ли найдены люди."
             ).pack(anchor="w", padx=16, pady=(0, 12))

    def _selected_camera(self) -> Optional[CameraSettings]:
        sel = self.cam_tree.selection()
        if not sel:
            messagebox.showinfo("Камера", "Выберите камеру в списке.", parent=self.root)
            return None
        return self.settings.camera(sel[0])

    def _add_camera(self) -> None:
        dlg = CameraDialog(self.root, self.bg, None, f"Камера {len(self.settings.cameras) + 1}")
        self.root.wait_window(dlg)
        if dlg.result:
            cam = dlg.result
            cam.id = self.settings.new_camera_id()
            self.settings.cameras.append(cam)
            self._save_now()
            self._refresh_all()

    def _edit_camera(self) -> None:
        cam = self._selected_camera()
        if not cam:
            return
        dlg = CameraDialog(self.root, self.bg, cam, cam.name)
        self.root.wait_window(dlg)
        if dlg.result:
            cam.name, cam.url, cam.anchor = dlg.result.name, dlg.result.url, dlg.result.anchor
            self._save_now()
            self._refresh_all()

    def _delete_camera(self) -> None:
        cam = self._selected_camera()
        if cam and messagebox.askyesno("Удалить камеру", f"Удалить «{cam.name}» и её зоны?",
                                       parent=self.root):
            self.settings.cameras.remove(cam)
            self.settings.zones.pop(cam.id, None)
            self._save_now()
            self._refresh_all()

    def _table_names(self) -> list[str]:
        club = self.controller.club
        return [r.name for r in club.resources] if club else []

    def _zones(self) -> None:
        cam = self._selected_camera()
        if not cam:
            return
        if self._table_names():
            return self._open_zones(cam)
        self._collect()
        if not self.settings.bot_token.strip():
            messagebox.showinfo("Зоны столов", "Сначала введите токен бота (вкладка «Бот»): "
                                "из программы берётся список столов.", parent=self.root)
            return self.nb.select(TAB_BOT)
        s = self.settings
        self.bg.run(lambda: self.controller.check_connection(s),
                    lambda snap, err: self._zones_after_fetch(cam, err))

    def _zones_after_fetch(self, cam: CameraSettings, error) -> None:
        if error is not None:
            messagebox.showerror("Зоны столов", str(error), parent=self.root)
            return
        self._open_zones(cam)

    def _open_zones(self, cam: CameraSettings) -> None:
        names = self._table_names()
        if not names:
            messagebox.showinfo("Зоны столов", "В программе Velora Club у клуба нет столов.",
                                parent=self.root)
            return

        def save(people, felt):
            for store, zones in ((self.settings.zones, people), (self.settings.felt_zones, felt)):
                if zones:
                    store[cam.id] = zones
                else:
                    store.pop(cam.id, None)
            self._save_now()
            self._refresh_all()

        ZoneEditor(self.root, self.bg, cam, names, self.settings.zones.get(cam.id, {}),
                   self.settings.felt_zones.get(cam.id, {}), save)

    def _preview(self) -> None:
        cam = self._selected_camera()
        if not cam:
            return
        cfg = self.settings.to_config("Asia/Tashkent", self.folder)
        tables = next((c.tables for c in cfg.cameras if c.name == cam.name), [])
        if not tables:
            messagebox.showinfo("Как видит программа", "Сначала нарисуйте зоны столов для этой камеры.",
                                parent=self.root)
            return
        accuracy = self.settings.accuracy
        PreviewWindow(self.root, CameraCfg(cam.name, cam.url, tables, cam.anchor),
                      lambda: self.controller.detector(accuracy))

    def _test_clip(self) -> None:
        cam = self._selected_camera()
        if not cam:
            return
        self._collect()
        self.testclip_btn.config(state="disabled")
        s = self.settings
        self.bg.run(lambda: self.controller.send_test_clip(s, cam.url), self._test_clip_done)

    def _test_clip_done(self, text, error) -> None:
        self.testclip_btn.config(state="normal")
        ok = error is None and "отправлен" in str(text)
        (messagebox.showinfo if ok else messagebox.showwarning)(
            "Проверочный ролик", str(error or text), parent=self.root)

    # ================= settings =================
    def _build_settings(self) -> None:
        t = self.tab_set
        self.vars = {}

        def spin(label: str, key: str, lo: int, hi: int, note: str = "") -> None:
            row = ttk.Frame(t)
            row.pack(fill="x", padx=16, pady=(12, 0))
            ttk.Label(row, text=label, width=52).pack(side="left")
            var = tk.StringVar(value=str(int(getattr(self.settings, key))))
            ttk.Spinbox(row, from_=lo, to=hi, width=6, textvariable=var).pack(side="left")
            var.trace_add("write", lambda *_: self._changed())
            self.vars[key] = var
            if note:
                hint(t, note, 700).pack(anchor="w", padx=16)

        ttk.Label(t, text="Когда присылать сообщения", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(16, 0))
        spin("Играют, а сеанса нет, дольше (минут)", "unrecorded_minutes", 1, 60)
        spin("Сеанс идёт, а у стола никого, дольше (минут)", "idle_minutes", 3, 180)
        spin("Одно и то же сообщение про стол не чаще (минут)", "cooldown_minutes", 5, 480)
        spin("Сколько человек у стола считать игрой", "min_people_play", 1, 4,
             "1: ловит и одиночную игру, но чаще ошибается, если кто-то просто стоит рядом. "
             "Много ложных сообщений: поставьте 2.")

        ttk.Label(t, text="Запись красивых ударов", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(20, 0))
        self.clips_enabled = tk.BooleanVar(value=self.settings.clips_enabled)
        ttk.Checkbutton(t, text="Записывать удары и отправлять в канал (нужно нарисовать сукно стола)",
                        variable=self.clips_enabled, command=self._changed).pack(anchor="w", padx=28, pady=2)
        self.clips_mode = tk.StringVar(value=self.settings.clips_mode)
        for value, text in (("learn", "Все удары: чтобы набрать примеры для обучения (не чаще раза в 1,5 минуты на стол)"),
                            ("bright", "Только яркие: когда двигаются несколько шаров сразу"),
                            ("rare", "Только самые яркие (например, разбив пирамиды)")):
            ttk.Radiobutton(t, text=text, value=value, variable=self.clips_mode,
                            command=self._changed).pack(anchor="w", padx=44, pady=1)
        self.clips_owner = tk.BooleanVar(value=self.settings.clips_to_owner)
        ttk.Checkbutton(t, text="Присылать ролики и владельцу в личный чат",
                        variable=self.clips_owner, command=self._changed).pack(anchor="w", padx=28, pady=2)

        ttk.Label(t, text="Распознавание", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(20, 0))
        self.accuracy = tk.StringVar(value=self.settings.accuracy)
        ttk.Radiobutton(t, text="Точнее (рекомендуется)", value="accurate", variable=self.accuracy,
                        command=self._changed).pack(anchor="w", padx=28, pady=2)
        ttk.Radiobutton(t, text="Быстрее (для слабого ноутбука, может пропускать людей)",
                        value="fast", variable=self.accuracy, command=self._changed
                        ).pack(anchor="w", padx=28, pady=2)

        ttk.Label(t, text="Запуск", font=FONT_BOLD).pack(anchor="w", padx=16, pady=(20, 0))
        self.autostart = tk.BooleanVar(value=self.settings.autostart)
        ttk.Checkbutton(t, text="Запускать вместе с Windows", variable=self.autostart,
                        command=self._changed,
                        state="normal" if autostart.is_supported() else "disabled"
                        ).pack(anchor="w", padx=28, pady=2)
        self.run_on_open = tk.BooleanVar(value=self.settings.run_on_open)
        ttk.Checkbutton(t, text="Начинать слежение сразу при открытии программы",
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
        s.extra_chat_ids = self.extra.get().strip()
        for key, var in self.vars.items():
            try:
                setattr(s, key, type(getattr(s, key))(float(var.get())))
            except ValueError:
                pass  # half-typed number: keep the old value
        s.clips_chat_id = self.clips_chat.get().strip()
        s.clips_enabled = bool(self.clips_enabled.get())
        s.clips_mode = self.clips_mode.get()
        s.clips_to_owner = bool(self.clips_owner.get())
        s.accuracy = self.accuracy.get()
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
        if not s.cameras or not any(s.zones.get(c.id) or s.felt_zones.get(c.id) for c in s.cameras):
            return TAB_CAMERAS
        return TAB_HOME

    def _refresh_all(self) -> None:
        self._refresh_cameras()
        self._refresh_steps()

    def _refresh_cameras(self) -> None:
        self.cam_tree.delete(*self.cam_tree.get_children())
        for c in self.settings.cameras:
            people = len(self.settings.zones.get(c.id) or {})
            felt = len(self.settings.felt_zones.get(c.id) or {})
            self.cam_tree.insert("", "end", iid=c.id,
                                 values=(c.name, mask_url(c.url), f"люди: {people}, сукно: {felt}"))

    def _refresh_steps(self) -> None:
        s = self.settings
        done = [bool(s.bot_token.strip()), bool(s.cameras),
                any(s.zones.get(c.id) or s.felt_zones.get(c.id) for c in s.cameras)]
        for lab, ok, text in zip(self.step_labels, done, self._step_texts):
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
        self.start_btn.config(text="■  Остановить" if c.is_active() else "▶  Запустить слежение")
        self._refresh_live()
        self._refresh_clips()
        self._refresh_log()
        self.root.after(1000, self._tick)

    def _refresh_clips(self) -> None:
        c = self.controller
        if c.state == RUNNING and c.sender is not None:
            seen = sum(r.shots_seen for r in c.recorders)
            self.clips_label.config(
                text=f"Удары: найдено {seen}, роликов отправлено {c.sender.sent}"
                     + (f", ждут отправки {c.sender.pending()}" if c.sender.pending() else ""))
        else:
            self.clips_label.config(text="")

    def _refresh_live(self) -> None:
        svc = self.controller.service
        rows = []
        if svc is not None and self.controller.state == RUNNING:
            names = {r.name: r for r in (self.controller.club.resources if self.controller.club else [])}
            for resource, (people, session) in svc.live.items():
                state = {"ACTIVE": "идёт", "PAUSED": "на паузе", "STARTING": "запускается",
                         "STOPPING": "завершается"}.get(session or "", "нет сеанса")
                rows.append((resource, people, state))
        current = [self.live.item(i, "values") for i in self.live.get_children()]
        if [tuple(map(str, r)) for r in rows] != [tuple(map(str, r)) for r in current]:
            self.live.delete(*self.live.get_children())
            for r in rows:
                self.live.insert("", "end", values=r)

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
                "Слежение работает.\n\nДа: свернуть окно, слежение продолжится.\n"
                "Нет: закрыть программу, слежение остановится.",
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
