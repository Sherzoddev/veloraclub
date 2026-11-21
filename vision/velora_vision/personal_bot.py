"""«Мой бот»: a Telegram bot of the owner's own, that only answers the owner.

It runs on the computer next to the cameras and asks Telegram for messages
itself (long polling), so nothing has to be opened in the router. From the
phone the owner gets:

* a photo of every camera, or of one;
* 20 seconds of live video of a camera;
* the last minute from the program's own recording (when it records).

Pairing: the window shows a one-time code; the first person who sends that
code to the bot becomes its owner. Everybody else gets one polite sentence.
"""
from __future__ import annotations

import json
import logging
import os
import secrets
import tempfile
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable, Optional

import requests

from .clips.archive import REASONS, cut_clip

log = logging.getLogger("velora_vision.mybot")

API = "https://api.telegram.org/bot{token}/{method}"
LIVE_SECONDS = 20
PAIR_MINUTES = 10

BTN_LIVE = "📺 Онлайн"
BTN_ALL = "📸 Все камеры"
BTN_ONE = "📷 Выбрать камеру"
BTN_VIDEO = "🎥 Видео с камеры"
KEYBOARD = {"keyboard": [[{"text": BTN_LIVE}, {"text": BTN_ALL}], [{"text": BTN_ONE}, {"text": BTN_VIDEO}]],
            "resize_keyboard": True, "is_persistent": True}


class TelegramError(Exception):
    def __init__(self, text: str, code: int = 0):
        super().__init__(text)
        self.code = code


class Telegram:
    def __init__(self, token: str, http=requests):
        self.token = token
        self.http = http

    def call(self, method: str, files: Optional[dict] = None, http_timeout: float = 40, **params):
        data = {k: (json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v)
                for k, v in params.items() if v is not None}
        try:
            r = self.http.post(API.format(token=self.token, method=method), data=data,
                               files=files, timeout=http_timeout)
            body = r.json()
        except (requests.RequestException, ValueError) as e:
            raise TelegramError(f"нет связи с Telegram ({type(e).__name__})") from None
        if not body.get("ok"):
            raise TelegramError(str(body.get("description") or "ошибка Telegram"),
                                int(body.get("error_code") or 0))
        return body.get("result")


# -- the camera side ----------------------------------------------------------
def snapshot_jpeg(url: str) -> Optional[bytes]:
    """One picture of the camera as JPEG; a squeezed light stream is stretched
    back to 16:9 (like the clips)."""
    import cv2

    from .camera import grab_frame

    frame = grab_frame(url)
    if frame is None:
        return None
    h, w = frame.shape[:2]
    if w / h < 1.6:
        w = int(h * 16 / 9)
    if w > 1920:
        h, w = int(h * 1920 / w), 1920
    if (w, h) != frame.shape[1::-1]:
        frame = cv2.resize(frame, (w, h), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return buf.tobytes() if ok else None


def live_clip(url: str, out: Path) -> Optional[str]:
    return cut_clip(url, LIVE_SECONDS, out)


def reason_text(reason: str) -> str:
    return REASONS.get(reason, f"Не получилось ({reason}).")


# -- the bot ------------------------------------------------------------------
class PersonalBot(threading.Thread):
    def __init__(self, token: str, owner: str, cameras: Callable[[], list], tmp_dir: Path,
                 local: Callable[[], object] = lambda: None, http=requests,
                 live: Callable[[], Optional[str]] = lambda: None,
                 live_status: Callable[[], str] = lambda: "",
                 snap: Callable[[str], Optional[bytes]] = snapshot_jpeg,
                 clip: Callable[[str, Path], Optional[str]] = live_clip,
                 poll_timeout: int = 25):
        super().__init__(name="mybot", daemon=True)
        self.tg = Telegram(token, http)
        self.token = token
        self.owner = owner.strip()      # chat id of the owner, "" until paired
        self.cameras = cameras          # -> current CameraSettings list
        self.tmp_dir = tmp_dir
        self.local = local              # -> LocalRecording or None
        self.live = live                # -> https address of «📺 Онлайн», or None
        self.live_status = live_status
        self._menu_for: tuple = (None, None)  # (owner, address) the menu button shows
        self.snap = snap
        self.clip = clip
        self.poll_timeout = poll_timeout
        self.stop_event = threading.Event()
        self.offset = 0
        self.username = ""
        self.status = "Запускается…"
        self.ok = False
        self.paired: Optional[str] = None   # set when somebody paired; the window saves it
        self.pair_code = ""
        self.pair_until = 0.0

    # -- used by the window ------------------------------------------------
    def new_pair_code(self) -> str:
        self.pair_code = f"{secrets.randbelow(900000) + 100000}"
        self.pair_until = time.time() + PAIR_MINUTES * 60
        return self.pair_code

    def stop(self) -> None:
        self.stop_event.set()

    # -- the thread ----------------------------------------------------------
    def run(self) -> None:
        while not self.stop_event.is_set():
            try:
                if not self.username:
                    self.start_up()
                self.step()
                self.sync_menu()
                self.ok = True
            except TelegramError as e:
                self.ok = False
                if e.code == 401 or e.code == 404:
                    self.status = "Токен не подходит: проверьте, что скопировали его из @BotFather целиком."
                    self.stop_event.wait(300)
                elif e.code == 409:
                    self.status = ("Этот бот уже где-то работает (у него вебхук или его опрашивает другая "
                                   "программа). Создайте в @BotFather нового бота именно для себя.")
                    self.stop_event.wait(120)
                else:
                    self.status = f"Нет связи с Telegram, пробую снова… ({e})"
                    self.stop_event.wait(15)
            except Exception:
                log.exception("Мой бот: ошибка")
                self.stop_event.wait(10)

    def start_up(self) -> None:
        me = self.tg.call("getMe", http_timeout=20)
        # Whatever was pressed while the program was off is not done now:
        # ten photos arriving at once in the morning help nobody.
        old = self.tg.call("getUpdates", offset=-1, http_timeout=20) or []
        if old:
            self.offset = old[-1]["update_id"] + 1
        self.username = me.get("username") or ""
        self.status = (f"Работает: @{self.username}, отвечает только вам." if self.owner else
                       f"Работает: @{self.username}. Осталось привязать ваш Telegram.")
        log.info("Мой бот @%s запущен", self.username)

    def sync_menu(self) -> None:
        """The button left of the message field opens «📺 Онлайн»; its address
        changes when the tunnel starts again, so it is kept up to date."""
        url = self.live() if self.owner else None
        if (self.owner, url) == self._menu_for or not self.owner:
            return
        button = ({"type": "web_app", "text": "📺 Онлайн", "web_app": {"url": url}} if url
                  else {"type": "default"})
        self.tg.call("setChatMenuButton", chat_id=self.owner, menu_button=button, http_timeout=20)
        self._menu_for = (self.owner, url)

    def step(self) -> int:
        updates = self.tg.call("getUpdates", http_timeout=self.poll_timeout + 15, offset=self.offset,
                               timeout=self.poll_timeout, allowed_updates=["message", "callback_query"])
        for u in updates or []:
            self.offset = u["update_id"] + 1
            try:
                self.handle(u)
            except TelegramError as e:
                log.warning("Мой бот: Telegram не принял ответ: %s", e)
            except Exception:
                log.exception("Мой бот: не удалось ответить")
        return len(updates or [])

    # -- answers -------------------------------------------------------------
    def send(self, chat: str, text: str, **kw):
        return self.tg.call("sendMessage", chat_id=chat, text=text, **kw)

    def handle(self, u: dict) -> None:
        if "callback_query" in u:
            return self._callback(u["callback_query"])
        msg = u.get("message") or {}
        chat = msg.get("chat") or {}
        if chat.get("type") != "private":
            return
        chat_id = str(chat.get("id"))
        text = (msg.get("text") or "").strip()
        if not self.owner:
            if self.pair_code and time.time() < self.pair_until and text == self.pair_code:
                self.owner = self.paired = chat_id
                self.pair_code = ""
                self.status = f"Работает: @{self.username}, отвечает только вам."
                log.info("Мой бот: привязан к Telegram владельца")
                self.send(chat_id, "✅ Готово, бот привязан к вам. Теперь он отвечает только вам.",
                          reply_markup=KEYBOARD)
                return
            self.send(chat_id, "Бот ещё не привязан. На компьютере откройте Velora Vision → «Мой бот» "
                               "→ «Привязать мой Telegram» и отправьте сюда код.")
            return
        if chat_id != self.owner:
            self.send(chat_id, "Это личный бот, он отвечает только владельцу.")
            return
        if text == BTN_LIVE or text == "/live":
            return self.send_live_link(chat_id)
        if text == BTN_ALL:
            return self.send_all(chat_id)
        if text in (BTN_ONE, BTN_VIDEO):
            return self.choose(chat_id, "s" if text == BTN_ONE else "v")
        self.send(chat_id, "Камеры клуба у вас в телефоне. Выберите кнопку внизу.",
                  reply_markup=KEYBOARD)

    def _callback(self, q: dict) -> None:
        user = str((q.get("from") or {}).get("id"))
        chat = str(((q.get("message") or {}).get("chat") or {}).get("id") or user)
        if not self.owner or user != self.owner:
            self.tg.call("answerCallbackQuery", callback_query_id=q.get("id"),
                         text="Это личный бот.")
            return
        kind, _, cam_id = (q.get("data") or "").partition(":")
        cam = next((c for c in self.cameras() if c.id == cam_id), None)
        self.tg.call("answerCallbackQuery", callback_query_id=q.get("id"),
                     text="" if cam else "Такой камеры больше нет.")
        if cam is None:
            return
        if kind == "s":
            self.send_photo(chat, cam)
        elif kind == "v":
            self.send_live(chat, cam)
        elif kind == "p":
            self.send_past(chat, cam)

    def send_live_link(self, chat: str) -> None:
        url = self.live()
        if not url:
            status = self.live_status() or "готовится"
            return self.send(chat, f"📺 Онлайн пока не готов: {status}. Попробуйте через минуту.")
        self.send(chat, "📺 Камеры в реальном времени. Нажмите кнопку (открывается внутри Telegram).",
                  reply_markup={"inline_keyboard": [[{"text": "📺 Открыть камеры", "web_app": {"url": url}}]]})

    def choose(self, chat: str, kind: str) -> None:
        cams = self.cameras()
        if not cams:
            return self.send(chat, "В программе нет камер (вкладка «2. Камеры»).")
        rows = [[{"text": c.name + (f" · {c.table}" if c.table else ""), "callback_data": f"{kind}:{c.id}"}]
                for c in cams]
        self.send(chat, "Какая камера?" if kind == "s" else f"Видео {LIVE_SECONDS} секунд, какая камера?",
                  reply_markup={"inline_keyboard": rows})

    def send_all(self, chat: str) -> None:
        cams = self.cameras()
        if not cams:
            return self.send(chat, "В программе нет камер (вкладка «2. Камеры»).")
        for cam in cams:
            self.send_photo(chat, cam)

    def _buttons(self, cam) -> dict:
        row = [{"text": "🔄 Обновить", "callback_data": f"s:{cam.id}"},
               {"text": f"🎥 {LIVE_SECONDS} с", "callback_data": f"v:{cam.id}"}]
        if self._recording(cam):
            row.append({"text": "⏪ Минуту назад", "callback_data": f"p:{cam.id}"})
        return {"inline_keyboard": [row]}

    def _recording(self, cam) -> bool:
        loc = self.local()
        return bool(loc is not None and cam.table.strip() and cam.table.strip() in getattr(loc, "folders", {}))

    def send_photo(self, chat: str, cam) -> None:
        self.tg.call("sendChatAction", chat_id=chat, action="upload_photo", http_timeout=15)
        jpeg = self.snap(cam.url)
        if not jpeg:
            self.send(chat, f"📷 {cam.name}: камера не отдала картинку. Проверьте, что она включена и в сети.")
            return
        caption = f"📷 {cam.name} · {datetime.now():%H:%M:%S}"
        self.tg.call("sendPhoto", files={"photo": ("camera.jpg", jpeg, "image/jpeg")}, http_timeout=90,
                     chat_id=chat, caption=caption, reply_markup=self._buttons(cam))

    def _send_video(self, chat: str, cam, path: Path, caption: str) -> None:
        with open(path, "rb") as f:
            self.tg.call("sendVideo", files={"video": ("video.mp4", f, "video/mp4")}, http_timeout=300,
                         chat_id=chat, caption=caption, supports_streaming="true",
                         reply_markup=self._buttons(cam))

    def _with_tmp(self, work: Callable[[Path], None]) -> None:
        self.tmp_dir.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="mybot_", suffix=".mp4", dir=self.tmp_dir)
        os.close(fd)
        path = Path(name)
        try:
            work(path)
        finally:
            try:
                path.unlink()
            except OSError:
                pass

    def send_live(self, chat: str, cam) -> None:
        self.send(chat, f"🎥 {cam.name}: снимаю {LIVE_SECONDS} секунд, пришлю через полминуты…")
        started = datetime.now()

        def work(path: Path) -> None:
            self.tg.call("sendChatAction", chat_id=chat, action="record_video", http_timeout=15)
            why = self.clip(cam.url, path)
            if why:
                return self.send(chat, f"🎥 {cam.name}: {reason_text(why)}")
            self.tg.call("sendChatAction", chat_id=chat, action="upload_video", http_timeout=15)
            self._send_video(chat, cam, path, f"🎥 {cam.name} · {started:%H:%M:%S}")

        self._with_tmp(work)

    def send_past(self, chat: str, cam) -> None:
        loc = self.local()
        if loc is None or not self._recording(cam):
            return self.send(chat, "Запись на компьютере сейчас не идёт: нажмите «Запустить» в программе.")
        # The piece being written now is not finished: take the minute before it.
        moment = datetime.now().astimezone() - timedelta(seconds=90)
        self.send(chat, f"⏪ {cam.name}: вырезаю минуту с {moment:%H:%M:%S}…")

        def work(path: Path) -> None:
            why = loc.cut(cam.table.strip(), moment, 0, 60, path)
            if why:
                return self.send(chat, f"⏪ {cam.name}: {reason_text(why)}")
            self._send_video(chat, cam, path, f"⏪ {cam.name} · с {moment:%H:%M:%S}")

        self._with_tmp(work)
