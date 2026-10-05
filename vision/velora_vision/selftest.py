"""`VeloraVision.exe --selftest`: checks that everything the program needs
really came with it (models, video encoder, window library). The build runs it
on the packaged program, so a broken package is caught before anyone
downloads it."""
from __future__ import annotations

import sys
import tempfile
import traceback
from pathlib import Path

from .paths import MODELS, data_dir, model_file


def run() -> list[tuple[bool, str]]:
    results: list[tuple[bool, str]] = []

    def check(name: str, fn) -> None:
        try:
            results.append((True, f"{name}: {fn()}"))
        except Exception:
            results.append((False, f"{name}: ПРОВАЛ\n{traceback.format_exc()}"))

    import numpy as np

    def detect(accuracy: str):
        from .detector import PersonDetector

        path, size = model_file(accuracy)
        if not path.exists():
            raise FileNotFoundError(path)
        det = PersonDetector(str(path), 0.4, size)
        det.detect(np.full((360, 640, 3), 90, np.uint8))
        return f"модель {path.name} загружена, кадр обработан"

    for accuracy in MODELS:
        check(f"распознавание ({accuracy})", lambda a=accuracy: detect(a))

    def video():
        import cv2

        from .clips.encoder import encode_mp4, ffmpeg_exe

        exe = ffmpeg_exe()
        if not exe:
            raise RuntimeError("ffmpeg не найден")
        ok, buf = cv2.imencode(".jpg", np.full((180, 320, 3), 120, np.uint8))
        out = Path(tempfile.mkdtemp()) / "t.mp4"
        if not encode_mp4([buf.tobytes()] * 20, 15, out) or out.stat().st_size < 500:
            raise RuntimeError("ролик не собрался")
        out.unlink()
        return "ролик собирается (H.264)"

    check("видео", video)

    def window():
        import tkinter

        tkinter.Tcl().eval("info patchlevel")
        return "библиотека окон на месте"

    check("окно", window)

    def zones():
        from zoneinfo import ZoneInfo

        ZoneInfo("Asia/Tashkent")
        return "часовые пояса на месте"

    check("время", zones)
    return results


def main() -> int:
    results = run()
    text = "\n".join(line for _, line in results)
    ok = all(good for good, _ in results)
    text += "\n\n" + ("ВСЁ В ПОРЯДКЕ" if ok else "ЕСТЬ ОШИБКИ")
    try:
        (data_dir() / "selftest.txt").write_text(text, encoding="utf-8")
    except OSError:
        pass
    try:
        print(text)
    except Exception:  # a windowed program has no console
        pass
    return 0 if ok else 1
