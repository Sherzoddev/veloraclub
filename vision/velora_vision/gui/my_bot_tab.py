"""Вкладка «Мой бот»: личный Telegram-бот владельца с камерами в телефоне."""
from __future__ import annotations

import tkinter as tk
from pathlib import Path
from tkinter import ttk
from typing import Callable, Optional

from ..live_view import LiveService
from ..personal_bot import PAIR_MINUTES, PersonalBot
from ..settings import Settings
from .common import FONT_BOLD, GREEN, GREY, RED, clipboard_text, hint


class MyBotTab:
    def __init__(self, frame: ttk.Frame, settings: Callable[[], Settings], changed: Callable[[], None],
                 tmp_dir: Path, local: Callable[[], object], bot_factory=PersonalBot,
                 live_factory=LiveService, data_dir: Optional[Path] = None):
        self.settings = settings
        self.changed = changed
        self.tmp_dir = tmp_dir
        self.local = local
        self.bot_factory = bot_factory
        self.live_factory = live_factory
        self.data_dir = data_dir or tmp_dir.parent
        self.bot: Optional[PersonalBot] = None
        self.live: Optional[LiveService] = None
        t = frame
        pad = {"padx": 16, "pady": 4}

        ttk.Label(t, text="Мой бот: камеры клуба у вас в телефоне", font=FONT_BOLD).pack(
            anchor="w", padx=16, pady=(16, 2))
        hint(t, "Отдельный бот только для вас: камеры онлайн (кнопка «📺 Онлайн»), фото, видео и "
                "последняя минута записи. "
                "Работает, пока этот компьютер включён и программа открыта (можно свёрнутой). "
                "В роутере ничего настраивать не нужно.", 720).pack(anchor="w", **pad)
        hint(t, "1) В Telegram откройте @BotFather → /newbot, придумайте имя. Он пришлёт токен.\n"
                "   Нужен НОВЫЙ бот, не бот клуба.\n"
                "2) Вставьте токен ниже.\n"
                "3) Нажмите «Привязать мой Telegram» и отправьте боту показанный код.", 720
             ).pack(anchor="w", **pad)

        row = ttk.Frame(t)
        row.pack(anchor="w", **pad)
        self.token = tk.StringVar(value=settings().my_bot_token)
        self.entry = ttk.Entry(row, textvariable=self.token, width=58, show="•")
        self.entry.pack(side="left")
        ttk.Button(row, text="Вставить", command=self._paste).pack(side="left", padx=(8, 0))
        self.show = tk.BooleanVar(value=False)
        ttk.Checkbutton(row, text="показать", variable=self.show,
                        command=lambda: self.entry.config(show="" if self.show.get() else "•")
                        ).pack(side="left", padx=8)
        self.token.trace_add("write", lambda *_: self.changed())

        row2 = ttk.Frame(t)
        row2.pack(anchor="w", **pad)
        self.pair_btn = ttk.Button(row2, text="Привязать мой Telegram", command=self._pair)
        self.pair_btn.pack(side="left")
        self.unpair_btn = ttk.Button(row2, text="Отвязать", command=self._unpair)
        self.unpair_btn.pack(side="left", padx=8)
        self.code_label = ttk.Label(t, text="", font=FONT_BOLD, foreground=GREEN, wraplength=700,
                                    justify="left")
        self.code_label.pack(anchor="w", **pad)
        self.status = ttk.Label(t, text="", wraplength=700, justify="left")
        self.status.pack(anchor="w", padx=16, pady=(8, 0))
        self.live_label = ttk.Label(t, text="", wraplength=700, justify="left", foreground=GREY)
        self.live_label.pack(anchor="w", padx=16, pady=(2, 8))

    # -- the window's state -> the bot ---------------------------------------
    def collect(self, s: Settings) -> None:
        s.my_bot_token = self.token.get().strip()

    def sync(self) -> None:
        """Starts, restarts or stops the bot so it matches the settings."""
        s = self.settings()
        token = s.my_bot_token.strip()
        wanted = bool(token) and token != s.bot_token.strip()
        if self.bot is not None and (not wanted or self.bot.token != token):
            self.stop()
        if wanted and self.bot is None:
            cams = lambda: list(self.settings().cameras)  # noqa: E731
            try:
                self.live = self.live_factory(lambda: token, lambda: self.settings().my_bot_owner,
                                              cams, self.data_dir)
                self.live.start()
            except OSError as e:  # no free port: the rest of the bot still works
                self.live = None
                self.live_label.config(text=f"Онлайн не запустился: {e}", foreground=RED)
            live = self.live
            self.bot = self.bot_factory(token, s.my_bot_owner, cams, self.tmp_dir, local=self.local,
                                        live=(lambda: live.url()) if live else (lambda: None),
                                        live_status=(lambda: live.status()) if live else (lambda: ""))
            self.bot.start()

    def running(self) -> bool:
        return self.bot is not None and self.bot.is_alive()

    def stop(self) -> None:
        if self.bot is not None:
            self.bot.stop()
            self.bot = None
        if self.live is not None:
            self.live.stop()
            self.live = None

    def tick(self) -> None:
        """Every second, on the window thread."""
        s = self.settings()
        bot = self.bot
        if bot is not None and bot.paired and bot.paired != s.my_bot_owner:
            s.my_bot_owner = bot.paired
            self.code_label.config(text="✓ Привязано. Пишите боту в Telegram.", foreground=GREEN)
            self.changed()
        token = s.my_bot_token.strip()
        if not token:
            text, color = "Бот не настроен: вставьте токен.", GREY
        elif token == s.bot_token.strip():
            text, color = ("Это токен бота клуба (вкладка «1. Бот»). Для себя создайте в @BotFather "
                           "нового бота: бот клуба нельзя опрашивать отсюда, он перестанет работать."), RED
        elif bot is None:
            text, color = "Запускается…", GREY
        else:
            text, color = bot.status, (GREEN if bot.ok else GREY if bot.status == "Запускается…" else RED)
        if self.status.cget("text") != text:
            self.status.config(text=text, foreground=color)
        self.unpair_btn.config(state="normal" if s.my_bot_owner else "disabled")
        if self.live is not None:
            ready = self.live.url() is not None
            live_text = ("📺 Онлайн: готов, в боте кнопка «📺 Онлайн»." if ready
                         else f"📺 Онлайн: {self.live.status()}")
            if self.live_label.cget("text") != live_text:
                self.live_label.config(text=live_text, foreground=GREEN if ready else GREY)

    # -- buttons ---------------------------------------------------------------
    def _paste(self) -> None:
        text = clipboard_text(self.entry)
        if text:
            self.token.set(text)

    def _pair(self) -> None:
        s = self.settings()
        if self.bot is None:
            self.code_label.config(text="Сначала вставьте токен нового бота.", foreground=RED)
            return
        if s.my_bot_owner:
            self.code_label.config(text="Бот уже привязан. Чтобы привязать другой Telegram, нажмите «Отвязать».",
                                   foreground=GREY)
            return
        code = self.bot.new_pair_code()
        name = f"@{self.bot.username}" if self.bot.username else "вашему боту"
        self.code_label.config(text=f"Отправьте {name} в Telegram этот код: {code}\n"
                                    f"(код действует {PAIR_MINUTES} минут)", foreground=GREEN)

    def _unpair(self) -> None:
        s = self.settings()
        s.my_bot_owner = ""
        if self.bot is not None:
            self.bot.owner = ""
            self.bot.paired = None
        self.code_label.config(text="Отвязано. Бот никому не отвечает, пока его снова не привяжут.",
                               foreground=GREY)
        self.changed()
