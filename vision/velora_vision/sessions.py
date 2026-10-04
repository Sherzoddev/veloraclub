"""Asks the Supabase function vision-sessions which tables have a session."""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

import requests

_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


class SessionsError(Exception):
    pass


@dataclass(frozen=True)
class ResourceState:
    id: str
    name: str
    zone: str
    session_status: Optional[str]  # None, "ACTIVE", "PAUSED", ...
    session_started_at: Optional[str]


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip()).casefold()


def match_resource(key: str, resources: list[ResourceState]) -> Optional[ResourceState]:
    """A table written in config.yaml as its id or its name (any case, extra
    spaces ignored)."""
    key = key.strip()
    if _UUID.match(key):
        return next((r for r in resources if r.id.lower() == key.lower()), None)
    wanted = _norm(key)
    return next((r for r in resources if _norm(r.name) == wanted), None)


class SessionsClient:
    def __init__(
        self,
        supabase_url: str,
        secret: str,
        club_id: str,
        http=requests,
        timeout: float = 10,
    ):
        self.url = f"{supabase_url.rstrip('/')}/functions/v1/vision-sessions"
        self.secret = secret
        self.club_id = club_id
        self.http = http
        self.timeout = timeout

    def fetch(self) -> list[ResourceState]:
        try:
            resp = self.http.post(
                self.url,
                json={"club_id": self.club_id},
                headers={"x-vision-secret": self.secret},
                timeout=self.timeout,
            )
        except requests.RequestException as e:
            raise SessionsError(f"нет связи с сервером: {e}") from e
        if resp.status_code == 401:
            raise SessionsError("сервер не принял VISION_SECRET (проверьте .env)")
        if resp.status_code == 503:
            raise SessionsError(
                "в Supabase не задан секрет VISION_SECRET (Edge Functions → Secrets)"
            )
        if resp.status_code != 200:
            raise SessionsError(f"сервер ответил {resp.status_code}")
        try:
            data = resp.json()
            return [
                ResourceState(
                    id=str(r["id"]),
                    name=str(r["name"]),
                    zone=str(r.get("zone") or ""),
                    session_status=r.get("session_status"),
                    session_started_at=r.get("session_started_at"),
                )
                for r in data["resources"]
            ]
        except (ValueError, KeyError, TypeError) as e:
            raise SessionsError(f"непонятный ответ сервера: {e}") from e
