"""Settings: config.yaml (what to watch), zones.yaml (where the tables are in
the picture) and .env (passwords and tokens; never leaves the laptop)."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

import yaml

from .geometry import Point
from .tracker import Rules


class ConfigError(Exception):
    """A setting is missing or wrong; the message says what to fix."""


@dataclass
class TableCfg:
    resource: str  # table name (or id) as in the program
    polygon: list[Point] | None  # normalized 0..1; None until drawn


@dataclass
class CameraCfg:
    name: str
    source: str  # rtsp://... or a video file
    tables: list[TableCfg]
    anchor: str = "foot"  # "foot" or "center"

    @property
    def is_file(self) -> bool:
        return "://" not in self.source


@dataclass
class Config:
    club_id: str
    timezone: str
    poll_seconds: float
    rules: Rules
    model: str
    confidence: float
    image_size: int
    interval: float
    offline_after: float
    cameras: list[CameraCfg]
    supabase_url: str = ""
    vision_secret: str = ""
    telegram_token: str = ""
    alert_chats: list[str] = field(default_factory=list)
    snapshot_dir: Path = Path("snapshots")


def load_env(path: Path, env: dict[str, str] | None = None) -> None:
    """Reads KEY=VALUE lines of a .env file into the environment, without
    overriding what is already set."""
    target = os.environ if env is None else env
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        target.setdefault(key.strip(), value)


def _minutes(data: Mapping, key: str, default: float) -> float:
    return float(data.get(key, default)) * 60


def load_config(
    config_path: Path,
    zones_path: Path,
    env: Mapping[str, str] | None = None,
    *,
    need_supabase: bool = True,
    need_telegram: bool = True,
) -> Config:
    env = os.environ if env is None else env
    if not config_path.exists():
        raise ConfigError(
            f"Нет файла {config_path}. Скопируйте config.example.yaml в config.yaml."
        )
    raw = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
    zones = {}
    if zones_path.exists():
        zones = yaml.safe_load(zones_path.read_text(encoding="utf-8")) or {}

    club_id = str(raw.get("club_id") or "").strip()
    if need_supabase and not club_id:
        raise ConfigError("В config.yaml не указан club_id.")

    rules_raw = raw.get("rules") or {}
    rules = Rules(
        min_people_play=int(rules_raw.get("min_people_play", Rules.min_people_play)),
        unrecorded_after=_minutes(rules_raw, "unrecorded_after_minutes", 5),
        idle_after=_minutes(rules_raw, "idle_after_minutes", 15),
        gap=float(rules_raw.get("gap_seconds", Rules.gap)),
        cooldown=_minutes(rules_raw, "alert_cooldown_minutes", 30),
        grace_after_session=_minutes(rules_raw, "grace_after_session_minutes", 10),
    )
    det = raw.get("detector") or {}

    cameras: list[CameraCfg] = []
    for cam in raw.get("cameras") or []:
        name = str(cam.get("name") or "").strip()
        if not name:
            raise ConfigError("У камеры в config.yaml нет name.")
        if cam.get("source_env"):
            var = str(cam["source_env"])
            source = (env.get(var) or "").strip()
            if not source:
                raise ConfigError(
                    f"Камера {name}: в .env не задано {var} (адрес потока камеры)."
                )
        else:
            source = str(cam.get("source") or "").strip()
            if not source:
                raise ConfigError(
                    f"Камера {name}: укажите source_env (переменная из .env) "
                    "или source (видеофайл)."
                )
        tables = []
        for t in cam.get("tables") or []:
            resource = str(t.get("resource") or "").strip()
            if not resource:
                raise ConfigError(f"Камера {name}: у стола нет resource.")
            poly = (zones.get(name) or {}).get(resource)
            polygon = [(float(x), float(y)) for x, y in poly] if poly else None
            if polygon is not None and len(polygon) < 3:
                raise ConfigError(f"Камера {name}, {resource}: в зоне меньше 3 точек.")
            tables.append(TableCfg(resource, polygon))
        if not tables:
            raise ConfigError(f"Камера {name}: не указано ни одного стола.")
        anchor = str(cam.get("anchor") or "foot")
        if anchor not in ("foot", "center"):
            raise ConfigError(f"Камера {name}: anchor должен быть foot или center.")
        cameras.append(CameraCfg(name, source, tables, anchor))
    if not cameras:
        raise ConfigError("В config.yaml не указано ни одной камеры.")

    supabase_url = (env.get("SUPABASE_URL") or "").rstrip("/")
    secret = env.get("VISION_SECRET") or ""
    token = env.get("TELEGRAM_BOT_TOKEN") or ""
    chats = [c.strip() for c in (env.get("TELEGRAM_ALERT_CHAT_ID") or "").split(",") if c.strip()]
    required = []
    if need_supabase:
        required += [("SUPABASE_URL", supabase_url), ("VISION_SECRET", secret)]
    if need_telegram:
        required += [
            ("TELEGRAM_BOT_TOKEN", token),
            ("TELEGRAM_ALERT_CHAT_ID", ",".join(chats)),
        ]
    for key, value in required:
        if not value:
            raise ConfigError(f"В .env не задано {key}.")

    return Config(
        club_id=club_id,
        timezone=str(raw.get("timezone") or "Asia/Tashkent"),
        poll_seconds=float((raw.get("sessions") or {}).get("poll_seconds", 15)),
        rules=rules,
        model=str(det.get("model", "yolov8n.pt")),
        confidence=float(det.get("confidence", 0.4)),
        image_size=int(det.get("image_size", 640)),
        interval=float(det.get("interval_seconds", 1.0)),
        offline_after=float(raw.get("camera_offline_after_seconds", 60)),
        cameras=cameras,
        supabase_url=supabase_url,
        vision_secret=secret,
        telegram_token=token,
        alert_chats=chats,
        snapshot_dir=Path(raw.get("snapshot_dir") or "snapshots"),
    )
