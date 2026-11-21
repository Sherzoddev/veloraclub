"""Reads and changes the picture settings of a Dahua camera over its web
interface, for the glare on the table (a lamp over the table lights the cloth
up and the picture burns out): highlight compensation (HLC) or wide dynamic
range (WDR).

Firmwares differ in how they name things, so nothing is assumed:

* the settings are read first and shown as they are (the person can send them);
* a change takes the current value of the key it touches, remembers it in a
  file, sets the new one and READS IT BACK; if the camera did not take it the
  old value is put back at once;
* "put back" returns the remembered value at any later time.
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, quote, urlsplit

from .clips.archive import camera_get

log = logging.getLogger("velora_vision.camera")

# What the camera calls the backlight mode, by firmware.
MODE_KEYS = ("Backlight", "BacklightMode", "BackLightMode")
NUMBERS = {"off": "0", "blc": "1", "wdr": "2", "hlc": "3"}
NAMES = {"off": "Off", "blc": "BackLight", "wdr": "WideDynamic", "hlc": "Inhibition"}
PRESETS = {
    "hlc": "Подавление бликов (HLC)",
    "wdr": "Широкий динамический диапазон (WDR)",
    "off": "Выключить компенсацию",
}


def channel_index(live_url: str) -> int:
    """The camera's own channel, 0-based, from `channel=N` of the stream address."""
    try:
        ch = (parse_qs(urlsplit(live_url).query).get("channel") or ["1"])[0]
        return max(int(ch) - 1, 0)
    except (ValueError, TypeError):
        return 0


def read_options(live_url: str, http=None) -> Optional[dict[str, str]]:
    """The picture settings of the camera (`VideoInOptions`) as key -> value,
    or None if it does not answer (or does not know them)."""
    text = camera_get(live_url, "/cgi-bin/configManager.cgi?action=getConfig&name=VideoInOptions", http)
    if not text:
        return None
    prefix = f"table.VideoInOptions[{channel_index(live_url)}]."
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(prefix) and "=" in line:
            key, value = line[len(prefix):].split("=", 1)
            out[key] = value
    return out or None


def format_options(options: dict[str, str]) -> str:
    return "\n".join(f"{k} = {v}" for k, v in sorted(options.items()))


def mode_key(options: dict[str, str]) -> Optional[str]:
    return next((k for k in MODE_KEYS if k in options), None)


def preset_value(options: dict[str, str], preset: str) -> Optional[tuple[str, str]]:
    """(key, new value) for a preset in the camera's own spelling (numbers or
    words, as the current value is), or None if the camera shows no such key."""
    key = mode_key(options)
    if key is None or preset not in NUMBERS:
        return None
    return key, (NUMBERS if options[key].strip().isdigit() else NAMES)[preset]


def _set(live_url: str, key: str, value: str, http=None) -> bool:
    path = (f"/cgi-bin/configManager.cgi?action=setConfig&"
            f"VideoInOptions[{channel_index(live_url)}].{quote(key)}={quote(value)}")
    text = camera_get(live_url, path, http)
    return bool(text) and "ok" in text.lower()


def _backup_file(backup_dir: Path, live_url: str) -> Path:
    host = re.sub(r"[^0-9A-Za-z.]", "_", urlsplit(live_url).hostname or "camera")
    return backup_dir / f"camera_{host}_ch{channel_index(live_url)}.json"


def apply_preset(live_url: str, preset: str, backup_dir: Path, http=None) -> tuple[bool, str]:
    """Sets a preset. Returns (done, sentence for the person)."""
    options = read_options(live_url, http)
    if options is None:
        return False, "Камера не отдала настройки изображения (адрес, логин, пароль, сеть)."
    wanted = preset_value(options, preset)
    if wanted is None:
        return False, ("У этой камеры нет такого параметра (режима подсветки). Нажмите «Показать "
                       "настройки» и пришлите текст разработчику.")
    key, value = wanted
    old = options[key]
    if old == value:
        return True, f"Уже так: {PRESETS[preset]}."
    # Remember the value the camera had, once: the first one is the original.
    backup_dir.mkdir(parents=True, exist_ok=True)
    file = _backup_file(backup_dir, live_url)
    saved = {}
    try:
        saved = json.loads(file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    if key not in saved:
        saved[key] = old
        file.write_text(json.dumps(saved, ensure_ascii=False), encoding="utf-8")
    if _set(live_url, key, value, http):
        after = read_options(live_url, http) or {}
        if after.get(key) == value:
            log.info("Камера %s: %s (%s: %s → %s)", urlsplit(live_url).hostname, PRESETS[preset], key, old, value)
            return True, (f"Готово: {PRESETS[preset]}. Подождите несколько секунд и посмотрите картинку. "
                          "Если стало хуже, нажмите «Вернуть прежние».")
    # The camera did not take it: the old value goes back.
    _set(live_url, key, old, http)
    return False, "Камера не приняла это значение, прежнее оставлено. Ничего не изменилось."


def restore(live_url: str, backup_dir: Path, http=None) -> tuple[bool, str]:
    """Puts back the values the camera had before the first change."""
    try:
        saved = json.loads(_backup_file(backup_dir, live_url).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False, "Нечего возвращать: программа ещё ничего не меняла в этой камере."
    done = all(_set(live_url, k, v, http) for k, v in saved.items())
    if not done:
        return False, "Камера не приняла прежние значения. Верните их в веб-интерфейсе камеры."
    try:
        _backup_file(backup_dir, live_url).unlink()
    except OSError:
        pass
    return True, "Прежние настройки возвращены."
