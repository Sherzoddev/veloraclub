"""Starting with Windows: a value in the user's Run key (no admin rights)."""
from __future__ import annotations

import sys

KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
NAME = "VeloraVision"


def _command() -> str:
    exe = sys.executable if getattr(sys, "frozen", False) else sys.argv[0]
    return f'"{exe}" --minimized'


def is_supported() -> bool:
    return sys.platform == "win32"


def set_enabled(enabled: bool) -> bool:  # pragma: no cover (Windows registry)
    if not is_supported():
        return False
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, KEY, 0, winreg.KEY_SET_VALUE) as k:
            if enabled:
                winreg.SetValueEx(k, NAME, 0, winreg.REG_SZ, _command())
            else:
                try:
                    winreg.DeleteValue(k, NAME)
                except FileNotFoundError:
                    pass
        return True
    except OSError:
        return False
