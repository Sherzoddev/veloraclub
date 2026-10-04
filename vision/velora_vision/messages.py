"""The texts that go to Telegram."""
from __future__ import annotations

from datetime import datetime

from .tracker import Event


def _minutes(seconds: float) -> int:
    return max(1, round(seconds / 60))


def format_event(event: Event, at: datetime) -> str:
    when = at.strftime("%H:%M")
    if event.kind == "unrecorded":
        people = f"{event.people} чел." if event.people else "люди"
        return (
            f"⚠️ {event.table}: у стола {people} уже {_minutes(event.seconds)} мин., "
            f"а сеанс не запущен ({when})"
        )
    if event.kind == "idle":
        return (
            f"💤 {event.table}: сеанс идёт, а у стола никого уже "
            f"{_minutes(event.seconds)} мин. Возможно, забыли остановить ({when})"
        )
    return f"{event.table}: {event.kind} ({when})"


def camera_offline(name: str, seconds: float, at: datetime) -> str:
    return (
        f"📷 Камера {name} не отвечает уже {_minutes(seconds)} мин. "
        f"({at.strftime('%H:%M')})"
    )


def camera_online(name: str, at: datetime) -> str:
    return f"📷 Камера {name} снова в сети ({at.strftime('%H:%M')})"
