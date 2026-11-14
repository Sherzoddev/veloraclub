"""Where the program keeps its files."""
from __future__ import annotations

import os
import sys
from pathlib import Path

APP_NAME = "VeloraVision"

def data_dir() -> Path:
    """Settings and the log. VELORA_VISION_HOME overrides it
    (tests, or a portable copy)."""
    override = os.environ.get("VELORA_VISION_HOME")
    if override:
        base = Path(override)
    elif sys.platform == "win32":
        base = Path(os.environ.get("APPDATA") or Path.home()) / APP_NAME
    else:
        base = Path.home() / ".local" / "share" / APP_NAME
    base.mkdir(parents=True, exist_ok=True)
    return base
