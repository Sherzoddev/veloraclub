"""Asks a camera over RTSP what is wrong when no picture comes, so the
person is told "wrong password" or "no such stream address" instead of a
list of guesses. Only talks to the camera; never decodes video."""
from __future__ import annotations

import hashlib
import re
import socket
import uuid
from typing import Optional

from .camera_find import PATHS


def _md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def _ask(host: str, port: int, request: str, timeout: float):
    """(status code, headers) of the camera's answer; (None, {}) if it does
    not speak RTSP. Raises OSError if the camera cannot be reached."""
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(request.encode("utf-8"))
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    lines = data.decode("latin-1", "replace").split("\r\n\r\n")[0].split("\r\n")
    m = re.match(r"RTSP/\d\.\d\s+(\d{3})", lines[0]) if lines else None
    if not m:
        return None, {}
    headers: dict[str, list[str]] = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers.setdefault(key.strip().lower(), []).append(value.strip())
    return int(m.group(1)), headers


def _digest(challenge: str, method: str, url: str, user: str, password: str) -> str:
    fields = dict(re.findall(r'(\w+)="?([^",]*)"?', challenge))
    realm, nonce = fields.get("realm", ""), fields.get("nonce", "")
    ha1 = _md5(f"{user}:{realm}:{password}")
    ha2 = _md5(f"{method}:{url}")
    extra = ""
    if "auth" in fields.get("qop", "").replace(" ", "").split(","):
        nc, cnonce = "00000001", uuid.uuid4().hex[:16]
        response = _md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
        extra = f', qop=auth, nc={nc}, cnonce="{cnonce}"'
    else:
        response = _md5(f"{ha1}:{nonce}:{ha2}")
    return (f'Digest username="{user}", realm="{realm}", nonce="{nonce}", '
            f'uri="{url}", response="{response}"{extra}')


def describe(host: str, port: int, path: str, user: str, password: str,
             timeout: float = 3.0) -> Optional[int]:
    """The status a DESCRIBE of this stream gets: 200 (there), 401 (login or
    password refused), 404 (no such stream address), ..."""
    url = f"rtsp://{host}:{port}{path}"

    def request(auth: Optional[str] = None) -> str:
        head = (f"DESCRIBE {url} RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\n"
                "User-Agent: VeloraVision\r\n")
        return head + (f"Authorization: {auth}\r\n" if auth else "") + "\r\n"

    status, headers = _ask(host, port, request(), timeout)
    if status != 401:
        return status
    challenges = headers.get("www-authenticate", [])
    digest = next((c for c in challenges if c.lower().startswith("digest")), None)
    if digest:
        auth = _digest(digest, "DESCRIBE", url, user, password)
    elif any(c.lower().startswith("basic") for c in challenges):
        import base64
        auth = "Basic " + base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    else:
        return 401
    return _ask(host, port, request(auth), timeout)[0]


def explain(ip: str, user: str, password: str, timeout: float = 3.0, paths=PATHS) -> str:
    """One plain sentence about what is wrong with this camera."""
    host, _, port_text = ip.partition(":")
    port = int(port_text) if port_text.isdigit() else 554
    statuses: list[int] = []
    unauthorized_in_a_row = 0
    try:
        for _label, path in paths:
            status = describe(host, port, path, user, password, timeout)
            if status is None:
                return (f"По адресу {host}:{port} отвечает не камера (или не по RTSP). "
                        "Проверьте IP: возможно, это другое устройство.")
            if status == 200:
                return ("Камера отвечает и логин с паролем подходят, но картинку не удалось "
                        "прочитать (часто это формат видео H.265 или камера занята другой "
                        "программой). Попробуйте в настройках камеры включить H.264 для "
                        "дополнительного потока.")
            statuses.append(status)
            unauthorized_in_a_row = unauthorized_in_a_row + 1 if status == 401 else 0
            if unauthorized_in_a_row >= 3:
                break
    except OSError:
        return (f"Камера {host} не отвечает на порту {port}. Проверьте IP, что камера включена "
                "и в той же сети, и что в её настройках включён RTSP.")
    if statuses and all(s == 401 for s in statuses):
        return ("Камера отвечает, но не принимает логин или пароль. Проверьте их (как для входа "
                "в приложение камеры). У части камер пароль для видео задаётся отдельно: "
                "в настройках камеры ищите «RTSP» или «ONVIF».")
    if any(s == 403 for s in statuses):
        return "Камера отвечает, но запрещает доступ этому пользователю (нужен другой логин)."
    return ("Камера отвечает, логин и пароль подходят, но адрес потока из обычных не подошёл. "
            "Выберите «У меня есть готовый адрес (rtsp://…)» и впишите адрес из приложения "
            "камеры или её инструкции.")
