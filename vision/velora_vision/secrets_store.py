"""Keeps the bot token and camera passwords unreadable in the settings file.

On Windows they are encrypted with the user's own login (DPAPI): a copy of
the file on another computer or another account can't read them. Elsewhere
(only for development) they are just base64.
"""
from __future__ import annotations

import base64
import sys

PLAIN = "plain:"
DPAPI = "dpapi:"


def _dpapi(data: bytes, encrypt: bool) -> bytes:  # pragma: no cover (Windows)
    import ctypes
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    fn = crypt32.CryptProtectData if encrypt else crypt32.CryptUnprotectData
    fn.argtypes = [
        ctypes.POINTER(Blob), wintypes.LPCWSTR if encrypt else ctypes.c_void_p,
        ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(Blob),
    ]
    fn.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]

    buf = ctypes.create_string_buffer(data, len(data))
    src = Blob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    out = Blob()
    ok = fn(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(out))
    if not ok:
        raise OSError("DPAPI failed")
    try:
        return ctypes.string_at(ctypes.cast(out.pbData, ctypes.c_void_p).value, out.cbData)
    finally:
        kernel32.LocalFree(ctypes.cast(out.pbData, ctypes.c_void_p).value)


def protect(text: str) -> str:
    if not text:
        return ""
    raw = text.encode("utf-8")
    if sys.platform == "win32":  # pragma: no cover
        try:
            return DPAPI + base64.b64encode(_dpapi(raw, True)).decode("ascii")
        except Exception:
            pass  # never lose the settings over this
    return PLAIN + base64.b64encode(raw).decode("ascii")


def unprotect(blob: str) -> str:
    """"" if it can't be read (another computer or account): the person is
    then simply asked to type it again."""
    if not blob:
        return ""
    try:
        if blob.startswith(PLAIN):
            return base64.b64decode(blob[len(PLAIN):]).decode("utf-8")
        if blob.startswith(DPAPI) and sys.platform == "win32":  # pragma: no cover
            return _dpapi(base64.b64decode(blob[len(DPAPI):]), False).decode("utf-8")
    except Exception:
        return ""
    return ""
