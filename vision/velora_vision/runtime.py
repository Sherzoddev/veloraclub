"""Starts and stops the work in the background, so the window never freezes.
The window only reads `state`, `message` and the log lines.

The program does one thing: a client asks in the club bot for the moment of
his shot, the program cuts it out of the camera's own recording."""
from __future__ import annotations

import logging
import threading
from collections import deque
from pathlib import Path
from typing import Callable, Optional

from .clips.archive import check_archive
from .clips.client_clips import ClipRequestWorker, ClipsClient, table_sources
from .sessions import ClubSnapshot, SessionsClient, SessionsError
from .settings import Settings

log = logging.getLogger("velora_vision")

STOPPED, STARTING, RUNNING, FAILED = "stopped", "starting", "running", "failed"


class LogBuffer(logging.Handler):
    """Keeps the last log lines for the "Журнал" tab."""

    def __init__(self, size: int = 400):
        super().__init__()
        self.lines: deque[str] = deque(maxlen=size)
        self.setFormatter(logging.Formatter("%(asctime)s  %(message)s", "%H:%M:%S"))

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.lines.append(self.format(record))
        except Exception:
            pass


class Controller:
    def __init__(self, get_settings: Callable[[], Settings], tmp_dir: Path,
                 worker_factory=ClipRequestWorker):
        self.get_settings = get_settings
        self.tmp_dir = tmp_dir
        self.worker_factory = worker_factory
        self.state = STOPPED
        self.message = "Остановлено"
        self.club: Optional[ClubSnapshot] = None  # last answer of the server
        self.worker: Optional[ClipRequestWorker] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    # -- used by the window -----------------------------------------------
    def check_connection(self, settings: Settings) -> ClubSnapshot:
        """The bot token works and the club is found. Raises SessionsError."""
        snap = SessionsClient(settings.supabase_url, settings.bot_token).fetch()
        self.club = snap
        return snap

    def timezone(self) -> str:
        return self.club.timezone if self.club else "Asia/Tashkent"

    def check_camera(self, url: str) -> tuple[bool, str]:
        """Takes a few seconds from the camera's recording, to show the way works."""
        return check_archive(url, self.timezone())

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop = threading.Event()
        self.state, self.message = STARTING, "Запуск…"
        self._thread = threading.Thread(target=self._run, name="start", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=10)
        if self.worker:
            self.worker.join(timeout=10)
        self.worker = None
        self.state, self.message = STOPPED, "Остановлено"

    def is_active(self) -> bool:
        return self.state in (STARTING, RUNNING)

    # -- the thread -------------------------------------------------------
    def _fail(self, text: str) -> None:
        log.error("%s", text)
        self.state, self.message = FAILED, text

    def _run(self) -> None:
        stop = self._stop
        try:
            settings = self.get_settings()
            problems = settings.problems()
            if problems:
                return self._fail(problems[0])
            try:
                snap = self.check_connection(settings)
            except SessionsError as e:
                return self._fail(str(e))
            sources = table_sources(settings.cameras)
            if not sources:
                return self._fail("Нет камер Dahua с выбранным столом (вкладка «2. Камеры»).")
            known = {r.name.strip().casefold() for r in snap.resources}
            for table in sources:
                if table.strip().casefold() not in known:
                    log.warning("Стол «%s»: такого стола нет в программе Velora Club", table)
            self.worker = self.worker_factory(
                ClipsClient(settings.supabase_url, settings.bot_token), sources, self.tmp_dir, stop)
            self.worker.start()
            self.state = RUNNING
            self.message = f"Работает: столов {len(sources)}. Жду заявок клиентов из бота."
        except Exception as e:  # never die silently
            log.exception("Запуск не удался из-за ошибки")
            self._fail(f"Ошибка: {e}")
