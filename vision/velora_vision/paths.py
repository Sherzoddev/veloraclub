"""Where the program keeps its files and finds its model."""
from __future__ import annotations

import os
import sys
from pathlib import Path

APP_NAME = "VeloraVision"

# Accuracy setting -> (model file, size the network is fed).
MODELS = {
    "accurate": ("yolox_s.onnx", 640),
    "fast": ("yolox_tiny.onnx", 416),
}


def data_dir() -> Path:
    """Settings, log and saved pictures. VELORA_VISION_HOME overrides it
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


def resource_dir() -> Path:
    """The folder with the files shipped inside the program."""
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen)
    return Path(__file__).resolve().parent.parent


def model_file(accuracy: str) -> tuple[Path, int]:
    name, size = MODELS.get(accuracy, MODELS["accurate"])
    return resource_dir() / "models" / name, size
