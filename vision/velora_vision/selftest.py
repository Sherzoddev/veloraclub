"""`VeloraVision.exe --selftest`: checks that everything the program needs
really came with it (video encoder, window library). The build runs it
on the packaged program, so a broken package is caught before anyone
downloads it."""
from __future__ import annotations

import sys
import tempfile
import traceback
from pathlib import Path

from .paths import data_dir


def run() -> list[tuple[bool, str]]:
    results: list[tuple[bool, str]] = []

    def check(name: str, fn) -> None:
        try:
            results.append((True, f"{name}: {fn()}"))
        except Exception:
            results.append((False, f"{name}: ПРОВАЛ\n{traceback.format_exc()}"))

    def video():
        import subprocess

        from .clips.archive import cut_clip, ffmpeg_exe

        exe = ffmpeg_exe()
        if not exe:
            raise RuntimeError("ffmpeg не найден")
        folder = Path(tempfile.mkdtemp())
        source, out = folder / "src.mp4", folder / "clip.mp4"
        subprocess.run(
            [exe, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
             "testsrc=size=640x360:rate=15", "-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p",
             str(source)], check=True, timeout=60, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        why = cut_clip(str(source), 2, out, exe=exe)
        if why is not None or out.stat().st_size < 500:
            raise RuntimeError(f"ролик не вырезался: {why}")
        return "ролик вырезается (H.264)"

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
