"""Starts and stops the watching in the background, so the window never
freezes. The window only reads `state` and `message` and the log lines."""
from __future__ import annotations

import logging
import threading
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

from . import messages
from .camera import CameraReader
from .clips.encoder import encode_mp4
from .clips.recorder import ClipRecorder
from .clips.sender import ClipJob, ClipSender
from .paths import model_file
from .service import Service, TelegramNotifier
from .sessions import ClubSnapshot, SessionsClient, SessionsError
from .settings import Settings
from .telegram import Telegram

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


def make_detector(accuracy: str, confidence: float = 0.4):
    from .detector import PersonDetector  # opencv: only when really needed

    path, size = model_file(accuracy)
    if not path.exists():
        raise FileNotFoundError(
            f"Не найден файл модели {path.name}. Переустановите программу."
        )
    return PersonDetector(str(path), confidence, size)


class Controller:
    def __init__(
        self,
        get_settings: Callable[[], Settings],
        snapshot_dir: Path,
        detector_factory: Callable[[str], object] = make_detector,
        tmp_dir: Optional[Path] = None,
    ):
        self.get_settings = get_settings
        self.snapshot_dir = snapshot_dir
        self.tmp_dir = tmp_dir or snapshot_dir.parent / "tmp"
        self.sender: Optional[ClipSender] = None
        self.recorders: list[ClipRecorder] = []
        self.detector_factory = detector_factory
        self.state = STOPPED
        self.message = "Остановлено"
        self.club: Optional[ClubSnapshot] = None  # last answer of the server
        self.service: Optional[Service] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._detectors: dict[str, object] = {}

    # -- used by the window -----------------------------------------------
    def check_connection(self, settings: Settings) -> ClubSnapshot:
        """The bot token works and the club is found. Raises SessionsError."""
        snap = SessionsClient(settings.supabase_url, settings.bot_token).fetch()
        self.club = snap
        return snap

    def detector(self, accuracy: str):
        if accuracy not in self._detectors:
            self._detectors[accuracy] = self.detector_factory(accuracy)
        return self._detectors[accuracy]

    def chats_for(self, settings: Settings, snap: Optional[ClubSnapshot]) -> list[str]:
        chats = []
        if snap and snap.owner_chat_id is not None:
            chats.append(str(snap.owner_chat_id))
        chats += [c for c in settings.extra_chats() if c not in chats]
        return chats

    def send_test(self, settings: Settings) -> str:
        """Returns a sentence for the person about how it went."""
        snap = self.check_connection(settings)
        chats = self.chats_for(settings, snap)
        if not chats:
            return ("Владелец ещё не запускал бота. Откройте бота в Telegram, нажмите "
                    "«Старт» и повторите.")
        tg = Telegram(settings.bot_token, chats)
        if tg.send_message(messages.test_message(snap.club_name)):
            return f"Сообщение отправлено ({len(chats)} чат.). Проверьте Telegram."
        return "Не удалось отправить. Проверьте интернет и что бот не заблокирован."

    def send_channel_test(self, settings: Settings) -> str:
        chat = settings.clips_chat_id.strip()
        if not chat:
            return "Впишите канал для роликов."
        tg = Telegram(settings.bot_token, [chat])
        if tg.send_message("🎱 Проверка: сюда будут приходить ролики с ударами (Velora Vision)"):
            return "Сообщение отправлено в канал. Если не пришло: бот должен быть администратором канала."
        return ("Не удалось отправить в канал. Проверьте номер канала и что бот добавлен в "
                "канал администратором.")

    def send_test_clip(self, settings: Settings, source: str, seconds: float = 4.0) -> str:
        """Records a few seconds from the camera and sends them as a clip, to
        check the whole way (camera, video, channel)."""
        chat = settings.clips_chat_id.strip()
        if not chat:
            return "Впишите канал для роликов (вкладка «Бот»)."
        from .clips.recorder import capture_clip

        frames = capture_clip(source, seconds, 15.0)
        if len(frames) < 5:
            return "Не удалось снять ролик с камеры."
        sender = ClipSender(Telegram(settings.bot_token, [chat]), self.tmp_dir, threading.Event())
        ok = sender.process(ClipJob(frames, 15.0, "🎱 Проверочный ролик (Velora Vision)"))
        return ("Проверочный ролик отправлен в канал и удалён с компьютера." if ok
                else "Не удалось отправить ролик. Проверьте канал и интернет.")

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop = threading.Event()
        self.state, self.message = STARTING, "Запуск…"
        self._thread = threading.Thread(target=self._run, name="watch", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=10)
        self.service = None
        self.state, self.message = STOPPED, "Остановлено"

    def is_active(self) -> bool:
        return self.state in (STARTING, RUNNING)

    def _start_clips(self, settings, cfg, snap, readers, service, stop) -> None:
        self.sender, self.recorders = None, []
        cams = [c for c in cfg.cameras if any(t.felt for t in c.tables)]
        if not settings.clips_enabled or not cams:
            return
        chat = settings.clips_chat_id.strip()
        if not chat:
            log.warning("Запись ударов выключена: не указан канал (вкладка «Бот»)")
            return
        chats = [chat]
        if settings.clips_to_owner and snap.owner_chat_id is not None:
            chats.append(str(snap.owner_chat_id))
        self.sender = ClipSender(Telegram(settings.bot_token, chats), self.tmp_dir, stop)
        self.sender.start()

        def busy(name: str) -> bool:
            people, session = service.live.get(name, (1, None))  # not watched: assume yes
            return people > 0 or session == "ACTIVE"

        for cam in cams:
            rec = ClipRecorder(cam, readers[cam.name], self.sender, stop,
                               mode=settings.clips_mode, timezone=snap.timezone, table_busy=busy)
            rec.start()
            self.recorders.append(rec)
        log.info("Запись ударов включена (режим «%s», камер: %d)", settings.clips_mode, len(cams))

    # -- the thread -------------------------------------------------------
    def _fail(self, text: str) -> None:
        log.error("%s", text)
        self.state, self.message = FAILED, text

    def _run(self) -> None:
        stop = self._stop
        readers: dict[str, CameraReader] = {}
        try:
            settings = self.get_settings()
            problems = settings.problems()
            if problems:
                return self._fail(problems[0])
            try:
                snap = self.check_connection(settings)
            except SessionsError as e:
                return self._fail(str(e))
            cfg = settings.to_config(snap.timezone, self.snapshot_dir)
            if not cfg.cameras:
                return self._fail("Нет камер с нарисованными зонами столов.")
            known = {r.name.strip().casefold() for r in snap.resources}
            for cam in cfg.cameras:
                for t in cam.tables:
                    if t.resource.strip().casefold() not in known:
                        log.warning("Зона «%s» (%s): такого стола нет в программе Velora Club",
                                    t.resource, cam.name)
            try:
                detector = self.detector(settings.accuracy)
            except Exception as e:
                return self._fail(f"Не удалось загрузить распознавание: {e}")

            chats = self.chats_for(settings, snap)
            if not chats:
                log.warning("Некуда слать сообщения: владелец не запускал бота в Telegram")
            telegram = Telegram(settings.bot_token, chats)
            notifier = TelegramNotifier(telegram)
            readers = {c.name: CameraReader(c.name, c.source, stop, c.rotate, c.widen) for c in cfg.cameras}
            self.sender, self.recorders = None, []
            for r in readers.values():
                r.start()
            service = Service(
                cfg, detector, readers, notifier,
                SessionsClient(settings.supabase_url, settings.bot_token),
            )
            self.service = service
            self._start_clips(settings, cfg, snap, readers, service, stop)
            tables = len(service.trackers)
            notifier.notify(messages.started(snap.club_name, tables, len(cfg.cameras)))
            self.state = RUNNING
            self.message = f"Работает: столов {tables}, камер {len(cfg.cameras)}"
            service.run(stop)
        except Exception as e:  # never die silently
            log.exception("Слежение остановилось из-за ошибки")
            self._fail(f"Ошибка: {e}")
            return
        finally:
            stop.set()
            if self.state == RUNNING:
                self.state, self.message = STOPPED, "Остановлено"
