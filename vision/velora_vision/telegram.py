"""Sends messages and pictures to Telegram."""
from __future__ import annotations

import logging
from typing import Optional

import requests

log = logging.getLogger("velora_vision.telegram")


class Telegram:
    def __init__(self, token: str, chats: list[str] | None = None, http=requests, timeout: float = 30):
        self.base = f"https://api.telegram.org/bot{token.strip()}"
        self.chats: list[str] = list(chats or [])
        self.http = http
        self.timeout = timeout

    def get_me(self) -> Optional[str]:
        """The bot's @username if the token works, else None."""
        try:
            resp = self.http.get(f"{self.base}/getMe", timeout=self.timeout)
            if resp.status_code == 200 and resp.json().get("ok"):
                return str(resp.json()["result"].get("username") or "")
        except (requests.RequestException, ValueError):
            pass
        return None

    def send_message(self, text: str) -> bool:
        ok = bool(self.chats)
        for chat in self.chats:
            ok &= self._post("sendMessage", {"chat_id": chat, "text": text})
        return ok

    def send_photo(self, jpeg: bytes, caption: str) -> bool:
        ok = bool(self.chats)
        for chat in self.chats:
            ok &= self._post(
                "sendPhoto",
                {"chat_id": chat, "caption": caption[:1000]},
                files={"photo": ("snapshot.jpg", jpeg, "image/jpeg")},
            )
        return ok

    def send_video(self, path, caption: str, width: int = 0, height: int = 0,
                   duration: int = 0) -> bool:
        """Uploads a video file to every chat; plays right in the channel."""
        ok = bool(self.chats)
        for chat in self.chats:
            with open(path, "rb") as f:
                ok &= self._post(
                    "sendVideo",
                    {"chat_id": chat, "caption": caption[:1000], "supports_streaming": "true",
                     "width": width, "height": height, "duration": duration},
                    files={"video": (getattr(path, "name", "clip.mp4"), f, "video/mp4")},
                    timeout=180,
                )
        return ok

    def _post(self, method: str, data: dict, files: dict | None = None,
              timeout: float | None = None) -> bool:
        try:
            resp = self.http.post(
                f"{self.base}/{method}", data=data, files=files,
                timeout=timeout or self.timeout,
            )
        except requests.RequestException as e:
            # The token is in the URL: never log the exception text as is.
            log.warning("Telegram %s: нет связи (%s)", method, type(e).__name__)
            return False
        if resp.status_code != 200:
            log.warning("Telegram %s: ответ %s", method, resp.status_code)
            return False
        return True
