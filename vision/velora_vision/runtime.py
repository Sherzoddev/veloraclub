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

from .clips.archive import check_archive, check_live
from .clips.client_clips import ClipRequestWorker, ClipsClient, table_sources
from .clips.local_record import LocalRecording
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
                 worker_factory=ClipRequestWorker, records_dir: Optional[Path] = None,
                 local_factory=LocalRecording):
        self.get_settings = get_settings
        self.tmp_dir = tmp_dir
        self.worker_factory = worker_factory
        self.records_dir = records_dir or tmp_dir.parent / "records"
        self.local_factory = local_factory
        self.local: Optional[LocalRecording] = None
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

    def check_camera(self, url: str, quality: str = "light") -> tuple[bool, str]:
        """Can the program record this camera, and does the camera give its own
        archive? Takes a few seconds of each."""
        live_ok, live_text = check_live(url, quality)
        arch_ok, arch_text = check_archive(url, self.timezone())
        if live_ok:
            tail = ("Архив самой камеры тоже читается." if arch_ok else
                    "Архив самой камеры недоступен: это не мешает, видео берётся из записи на компьютере.")
            return True, f"✓ Запись на компьютере возможна ({live_text}). {tail}"
        if arch_ok:
            return True, f"{arch_text}\nЖивой поток не читается ({live_text}): запись на компьютере вестись не будет."
        return False, f"Живой поток не читается: {live_text}\n\n{arch_text}"

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
        if self.local:
            for r in self.local.recorders:
                r.join(timeout=8)
        self.worker = None
        self.local = None
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
            for table in list(sources):
                if table.strip().casefold() not in known:
                    log.warning("Стол «%s»: такого стола нет в программе Velora Club", table)
                    del sources[table]
            if not sources:
                names = ", ".join(r.name for r in snap.resources) or "—"
                return self._fail("Выбранные у камер столы не найдены в Velora Club. Выберите "
                                  f"стол из списка (вкладка «2. Камеры»). Столы клуба: {names}.")
            self.local = None
            if settings.local_record:
                root = Path(settings.records_dir.strip()) if settings.records_dir.strip() else self.records_dir
                self.local = self.local_factory(sources, root, stop, settings.keep_hours,
                                                settings.record_quality)
                self.local.start()
            self.worker = self.worker_factory(
                ClipsClient(settings.supabase_url, settings.bot_token), sources, self.tmp_dir, stop,
                local=self.local)
            self.worker.start()
            self.state = RUNNING
            self.message = (f"Работает: столов {len(sources)}"
                            f"{', запись на компьютере идёт' if self.local else ''}. "
                            "Жду заявок клиентов из бота.")
        except Exception as e:  # never die silently
            log.exception("Запуск не удался из-за ошибки")
            self._fail(f"Ошибка: {e}")
