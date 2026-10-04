"""Asks the Supabase function vision-sessions about the club's tables.

The only credential is the owner bot's token: it identifies the club.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

import requests

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)

# What the server's error codes mean to the person.
_MESSAGES = {
    "BAD_TOKEN_FORMAT": "Токен выглядит неправильно. Он состоит из цифр, двоеточия и букв, "
                        "например 123456789:AAH...",
    "UNKNOWN_TOKEN": "Такого бота нет в программе Velora Club. Проверьте токен.",
    "NOT_OWNER_BOT": "Это токен кассового бота. Нужен токен бота владельца: "
                     "того, где вы смотрите отчёты.",
}


class SessionsError(Exception):
    pass


@dataclass(frozen=True)
class ResourceState:
    id: str
    name: str
    zone: str
    session_status: Optional[str]  # None, "ACTIVE", "PAUSED", ...
    session_started_at: Optional[str]


@dataclass(frozen=True)
class ClubSnapshot:
    club_name: str
    timezone: str
    owner_chat_id: Optional[int]
    resources: list[ResourceState]


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip()).casefold()


def match_resource(key: str, resources: list[ResourceState]) -> Optional[ResourceState]:
    """A table by its id or its name (any case, extra spaces ignored)."""
    key = key.strip()
    if _UUID.match(key):
        return next((r for r in resources if r.id.lower() == key.lower()), None)
    wanted = _norm(key)
    return next((r for r in resources if _norm(r.name) == wanted), None)


class SessionsClient:
    def __init__(self, supabase_url: str, bot_token: str, http=requests, timeout: float = 10):
        self.url = f"{supabase_url.rstrip('/')}/functions/v1/vision-sessions"
        self.token = bot_token.strip()
        self.http = http
        self.timeout = timeout

    def fetch(self) -> ClubSnapshot:
        try:
            resp = self.http.post(self.url, json={"bot_token": self.token}, timeout=self.timeout)
        except requests.RequestException as e:
            raise SessionsError(f"Нет связи с сервером Velora Club ({type(e).__name__}). "
                                "Проверьте интернет.") from e
        try:
            data = resp.json()
        except ValueError:
            data = None
        if resp.status_code != 200:
            code = data.get("error") if isinstance(data, dict) else None
            raise SessionsError(_MESSAGES.get(code, f"Сервер ответил {resp.status_code}."))
        try:
            chat = data.get("owner_chat_id")
            return ClubSnapshot(
                club_name=str(data.get("club_name") or ""),
                timezone=str(data.get("timezone") or "Asia/Tashkent"),
                owner_chat_id=int(chat) if chat is not None else None,
                resources=[
                    ResourceState(
                        id=str(r["id"]),
                        name=str(r["name"]),
                        zone=str(r.get("zone") or ""),
                        session_status=r.get("session_status"),
                        session_started_at=r.get("session_started_at"),
                    )
                    for r in data["resources"]
                ],
            )
        except (KeyError, TypeError, ValueError, AttributeError) as e:
            raise SessionsError(f"Непонятный ответ сервера: {e}") from e
