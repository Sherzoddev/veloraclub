"""Velora Vision: the program's entry point (double-click VeloraVision.exe)."""
from __future__ import annotations

import logging
import logging.handlers
import socket
import sys
import tkinter as tk
from tkinter import messagebox

from velora_vision.paths import data_dir

LOCK_PORT = 47631  # a second copy would send every message twice


def _setup_logging() -> None:
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%d.%m %H:%M:%S")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    handler = logging.handlers.RotatingFileHandler(
        data_dir() / "velora_vision.log", maxBytes=1_000_000, backupCount=2, encoding="utf-8"
    )
    handler.setFormatter(fmt)
    root.addHandler(handler)


def main() -> int:
    if "--selftest" in sys.argv:
        from velora_vision import selftest

        return selftest.main()

    lock = socket.socket()
    try:
        lock.bind(("127.0.0.1", LOCK_PORT))
    except OSError:
        root = tk.Tk()
        root.withdraw()
        messagebox.showinfo("Velora Vision", "Программа уже запущена. Найдите её окно в панели задач.")
        return 0

    _setup_logging()
    from velora_vision.gui.main_window import MainWindow

    root = tk.Tk()
    try:
        MainWindow(root, data_dir(), minimized="--minimized" in sys.argv)
    except Exception:
        logging.getLogger("velora_vision").exception("Не удалось открыть окно")
        raise
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
