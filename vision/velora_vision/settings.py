"""Everything the person types or draws, kept in one JSON file in the user's
AppData folder. The bot token and the camera addresses (they contain the
camera password) are stored encrypted."""
from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from . import secrets_store
from .config import CameraCfg, Config, TableCfg
from .tracker import Rules

DEFAULT_SUPABASE_URL = "https://aatriitpqpwhdcehjzip.supabase.co"
FILE_NAME = "settings.json"


@dataclass
class CameraSettings:
    id: str
    name: str
    url: str  # rtsp://user:password@ip/...; secret
    anchor: str = "foot"  # "foot": camera at an angle, "center": from above
    rotate: int = 0  # turn the picture, degrees clockwise: 0, 90, 180, 270
    widen: bool = False  # stretch a squeezed (almost square) picture to 16:9


@dataclass
class Settings:
    bot_token: str = ""
    extra_chat_ids: str = ""  # a group or channel besides the owner's chat
    supabase_url: str = DEFAULT_SUPABASE_URL
    cameras: list[CameraSettings] = field(default_factory=list)
    # camera id -> table name -> polygon in fractions of the picture:
    # where the people stand (zones) and the table cloth (felt_zones)
    zones: dict[str, dict[str, list[list[float]]]] = field(default_factory=dict)
    felt_zones: dict[str, dict[str, list[list[float]]]] = field(default_factory=dict)
    min_people_play: int = 1
    unrecorded_minutes: float = 5
    idle_minutes: float = 15
    cooldown_minutes: float = 30
    accuracy: str = "accurate"  # "accurate" | "fast"
    clips_enabled: bool = True  # record striking shots
    clips_chat_id: str = ""  # channel (-100... or @name) for the clips
    clips_mode: str = "learn"  # "learn" | "bright" | "rare"
    clips_to_owner: bool = False  # also send the clips to the owner's chat
    autostart: bool = False  # start with Windows
    run_on_open: bool = True  # begin watching as soon as the program opens

    # -- helpers ----------------------------------------------------------
    def extra_chats(self) -> list[str]:
        raw = self.extra_chat_ids.replace(";", ",").replace("\n", ",")
        return [c.strip() for c in raw.split(",") if c.strip()]

    def new_camera_id(self) -> str:
        return uuid.uuid4().hex[:8]

    def camera(self, camera_id: str) -> CameraSettings | None:
        return next((c for c in self.cameras if c.id == camera_id), None)

    def problems(self) -> list[str]:
        """What stops the watching from starting, in plain words."""
        out = []
        if not self.bot_token.strip():
            out.append("Не введён токен бота (вкладка «Бот»).")
        if not self.cameras:
            out.append("Не добавлено ни одной камеры (вкладка «Камеры»).")
        elif not any(self.zones.get(c.id) or self.felt_zones.get(c.id) for c in self.cameras):
            out.append("Не нарисовано ни одной зоны стола (вкладка «Камеры» → «Зоны столов»).")
        return out

    def rules(self) -> Rules:
        return Rules(
            min_people_play=max(1, int(self.min_people_play)),
            unrecorded_after=float(self.unrecorded_minutes) * 60,
            idle_after=float(self.idle_minutes) * 60,
            cooldown=float(self.cooldown_minutes) * 60,
        )

    def to_config(self, timezone: str, snapshot_dir: Path, poll_seconds: float = 15) -> Config:
        def poly(raw):
            return [(float(x), float(y)) for x, y in raw] if raw and len(raw) >= 3 else None

        cameras = []
        for cam in self.cameras:
            people = self.zones.get(cam.id) or {}
            felt = self.felt_zones.get(cam.id) or {}
            tables = []
            for name in list(people) + [n for n in felt if n not in people]:
                t = TableCfg(name, poly(people.get(name)), poly(felt.get(name)))
                if t.polygon or t.felt:
                    tables.append(t)
            if tables:  # a camera without zones has nothing to watch
                cameras.append(CameraCfg(cam.name, cam.url, tables, cam.anchor, cam.rotate, cam.widen))
        return Config(
            timezone=timezone or "Asia/Tashkent",
            poll_seconds=poll_seconds,
            rules=self.rules(),
            interval=1.0,
            offline_after=60,
            cameras=cameras,
            snapshot_dir=snapshot_dir,
        )

    # -- file -------------------------------------------------------------
    def to_json(self) -> dict:
        return {
            "bot_token": secrets_store.protect(self.bot_token),
            "extra_chat_ids": self.extra_chat_ids,
            "supabase_url": self.supabase_url,
            "cameras": [
                {"id": c.id, "name": c.name, "url": secrets_store.protect(c.url), "anchor": c.anchor,
                 "rotate": c.rotate, "widen": c.widen}
                for c in self.cameras
            ],
            "zones": self.zones,
            "felt_zones": self.felt_zones,
            "clips_enabled": self.clips_enabled,
            "clips_chat_id": self.clips_chat_id,
            "clips_mode": self.clips_mode,
            "clips_to_owner": self.clips_to_owner,
            "min_people_play": self.min_people_play,
            "unrecorded_minutes": self.unrecorded_minutes,
            "idle_minutes": self.idle_minutes,
            "cooldown_minutes": self.cooldown_minutes,
            "accuracy": self.accuracy,
            "autostart": self.autostart,
            "run_on_open": self.run_on_open,
        }

    @classmethod
    def from_json(cls, data: dict) -> "Settings":
        d = cls()
        d.bot_token = secrets_store.unprotect(str(data.get("bot_token", "")))
        d.extra_chat_ids = str(data.get("extra_chat_ids", ""))
        d.supabase_url = str(data.get("supabase_url") or DEFAULT_SUPABASE_URL)
        d.cameras = [
            CameraSettings(
                id=str(c.get("id") or uuid.uuid4().hex[:8]),
                name=str(c.get("name") or "Камера"),
                url=secrets_store.unprotect(str(c.get("url", ""))),
                anchor=c.get("anchor") if c.get("anchor") in ("foot", "center") else "foot",
                rotate=c.get("rotate") if c.get("rotate") in (0, 90, 180, 270) else 0,
                widen=bool(c.get("widen", False)),
            )
            for c in data.get("cameras") or []
        ]
        def load_zones(raw) -> dict:
            return {
                str(cam): {
                    str(t): [[float(x), float(y)] for x, y in poly]
                    for t, poly in (tables or {}).items()
                    if isinstance(poly, list)
                }
                for cam, tables in (raw or {}).items()
            }

        d.zones = load_zones(data.get("zones"))
        d.felt_zones = load_zones(data.get("felt_zones"))
        d.clips_enabled = bool(data.get("clips_enabled", True))
        d.clips_chat_id = str(data.get("clips_chat_id", ""))
        d.clips_mode = data.get("clips_mode") if data.get("clips_mode") in ("learn", "bright", "rare") else "learn"
        d.clips_to_owner = bool(data.get("clips_to_owner", False))
        d.min_people_play = int(data.get("min_people_play", d.min_people_play))
        d.unrecorded_minutes = float(data.get("unrecorded_minutes", d.unrecorded_minutes))
        d.idle_minutes = float(data.get("idle_minutes", d.idle_minutes))
        d.cooldown_minutes = float(data.get("cooldown_minutes", d.cooldown_minutes))
        d.accuracy = data.get("accuracy") if data.get("accuracy") in ("accurate", "fast") else "accurate"
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
