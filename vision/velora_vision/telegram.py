"""Sends messages and pictures to Telegram."""
from __future__ import annotations

import logging

import requests

log = logging.getLogger("velora_vision.telegram")


class Telegram:
    def __init__(self, token: str, chats: list[str], http=requests, timeout: float = 30):
        self.base = f"https://api.telegram.org/bot{token}"
        self.chats = chats
        self.http = http
        self.timeout = timeout

    def send_message(self, text: str) -> bool:
        ok = True
        for chat in self.chats:
            ok &= self._post("sendMessage", {"chat_id": chat, "text": text})
        return ok

    def send_photo(self, jpeg: bytes, caption: str) -> bool:
        ok = True
        for chat in self.chats:
            ok &= self._post(
                "sendPhoto",
                {"chat_id": chat, "caption": caption[:1000]},
                files={"photo": ("snapshot.jpg", jpeg, "image/jpeg")},
            )
        return ok

    def _post(self, method: str, data: dict, files: dict | None = None) -> bool:
        try:
            resp = self.http.post(
                f"{self.base}/{method}", data=data, files=files, timeout=self.timeout
            )
        except requests.RequestException as e:
            # The token is in the URL: never log the exception text as is.
            log.warning("Telegram %s: нет связи (%s)", method, type(e).__name__)
            return False
        if resp.status_code != 200:
            log.warning("Telegram %s: ответ %s", method, resp.status_code)
            return False
        return True
