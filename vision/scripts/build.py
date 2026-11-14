"""Packs the program into dist/VeloraVision (a folder with VeloraVision.exe).

    python scripts/build.py
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    import PyInstaller.__main__ as pyi

    pyi.run([
        str(ROOT / "app.py"),
        "--name", "VeloraVision",
        "--noconfirm", "--clean", "--windowed",
        "--paths", str(ROOT),
        "--distpath", str(ROOT / "dist"),
        "--workpath", str(ROOT / "build"),
        "--specpath", str(ROOT / "build"),
        "--collect-all", "imageio_ffmpeg",
        "--collect-data", "tzdata",
        "--exclude-module", "matplotlib",
        "--exclude-module", "scipy",
        "--exclude-module", "pandas",
    ])
    return 0


if __name__ == "__main__":
    sys.exit(main())
