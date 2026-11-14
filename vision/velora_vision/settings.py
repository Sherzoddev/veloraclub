"""Everything the person types, kept in one JSON file in the user's AppData
folder. The bot token and the camera addresses (they contain the camera
password) are stored encrypted."""
from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from . import secrets_store

DEFAULT_SUPABASE_URL = "https://aatriitpqpwhdcehjzip.supabase.co"
FILE_NAME = "settings.json"
SETTINGS_VERSION = 3


@dataclass
class CameraSettings:
    id: str
    name: str
    url: str  # rtsp://user:password@ip/...; secret
    table: str = ""  # the table (as named in Velora Club) this camera looks at


@dataclass
class Settings:
    bot_token: str = ""
    supabase_url: str = DEFAULT_SUPABASE_URL
    cameras: list[CameraSettings] = field(default_factory=list)
    autostart: bool = False  # start with Windows
    run_on_open: bool = True  # begin working as soon as the program opens

    # -- helpers ----------------------------------------------------------
    def new_camera_id(self) -> str:
        return uuid.uuid4().hex[:8]

    def camera(self, camera_id: str) -> CameraSettings | None:
        return next((c for c in self.cameras if c.id == camera_id), None)

    def problems(self) -> list[str]:
        """What stops the work from starting, in plain words."""
        out = []
        if not self.bot_token.strip():
            out.append("Не введён токен бота (вкладка «1. Бот»).")
        if not self.cameras:
            out.append("Не добавлено ни одной камеры (вкладка «2. Камеры»).")
        elif not any(c.table.strip() for c in self.cameras):
            out.append("Ни у одной камеры не выбран стол (вкладка «2. Камеры» → «Изменить»).")
        return out

    # -- file -------------------------------------------------------------
    def to_json(self) -> dict:
        return {
            "version": SETTINGS_VERSION,
            "bot_token": secrets_store.protect(self.bot_token),
            "supabase_url": self.supabase_url,
            "cameras": [
                {"id": c.id, "name": c.name, "url": secrets_store.protect(c.url), "table": c.table}
                for c in self.cameras
            ],
            "autostart": self.autostart,
            "run_on_open": self.run_on_open,
        }

    @classmethod
    def from_json(cls, data: dict) -> "Settings":
        d = cls()
        d.bot_token = secrets_store.unprotect(str(data.get("bot_token", "")))
        d.supabase_url = str(data.get("supabase_url") or DEFAULT_SUPABASE_URL)
        d.cameras = [
            CameraSettings(
                id=str(c.get("id") or uuid.uuid4().hex[:8]),
                name=str(c.get("name") or "Камера"),
                url=secrets_store.unprotect(str(c.get("url", ""))),
                table=str(c.get("table") or ""),
            )
            for c in data.get("cameras") or []
        ]
        # Settings of the older versions (zones, alerts, clips to a channel)
        # are simply not read: the program no longer does those things.
        d.autostart = bool(data.get("autostart", False))
        d.run_on_open = bool(data.get("run_on_open", True))
        return d


def load(folder: Path) -> Settings:
    path = folder / FILE_NAME
    if not path.exists():
        return Settings()
    try:
        return Settings.from_json(json.loads(path.read_text(encoding="utf-8")))
    except (ValueError, TypeError, AttributeError):
        # A damaged file must not stop the program from opening; keep it
        # aside in case someone wants to look.
        try:
            path.replace(folder / (FILE_NAME + ".bad"))
        except OSError:
            pass
        return Settings()


def save(folder: Path, settings: Settings) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / FILE_NAME
    tmp = folder / (FILE_NAME + ".tmp")
    tmp.write_text(json.dumps(settings.to_json(), ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)  # never leaves a half-written file
