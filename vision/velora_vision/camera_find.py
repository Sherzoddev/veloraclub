"""Helps to connect a camera without knowing its stream address: finds
cameras on the network and tries the addresses that makers use."""
from __future__ import annotations

import socket
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable, Optional
from urllib.parse import quote

from .camera import grab_frame

# (what it is, path). The lighter "sub stream" goes first: enough for
# counting people and easy on the computer.
PATHS: list[tuple[str, str]] = [
    ("Hikvision / HiLook, доп. поток", "/Streaming/Channels/102"),
    ("Dahua / Imou / Amcrest, доп. поток", "/cam/realmonitor?channel=1&subtype=1"),
    ("TP-Link Tapo, доп. поток", "/stream2"),
    ("Reolink, доп. поток", "/h264Preview_01_sub"),
    ("Uniview, доп. поток", "/media/video2"),
    ("Hikvision / HiLook, основной поток", "/Streaming/Channels/101"),
    ("Dahua / Imou / Amcrest, основной поток", "/cam/realmonitor?channel=1&subtype=0"),
    ("TP-Link Tapo, основной поток", "/stream1"),
    ("Reolink, основной поток", "/h264Preview_01_main"),
    ("Uniview, основной поток", "/media/video1"),
    ("Ezviz / старые Hikvision", "/h264/ch1/sub/av_stream"),
    ("Общий адрес", "/live/ch00_1"),
    ("Общий адрес", "/11"),
    ("Общий адрес", "/1"),
    ("Общий адрес", "/h264"),
    ("Общий адрес", "/live"),
    ("Без пути", "/"),
]


# The same camera's light ("sub") and main stream differ by one piece of the
# address. The light one is often squeezed into an almost square picture
# (704x576), the main one is wide.
_STREAM_PAIRS = [
    ("subtype=1", "subtype=0"),
    ("/Streaming/Channels/102", "/Streaming/Channels/101"),
    ("/stream2", "/stream1"),
    ("/h264Preview_01_sub", "/h264Preview_01_main"),
    ("/media/video2", "/media/video1"),
    ("/h264/ch1/sub/", "/h264/ch1/main/"),
]


def _has(url: str, part: str) -> bool:
    # "subtype=1" must not match "subtype=10": the part ends the address or
    # is followed by "&"; paths ending in "/" can sit in the middle.
    if part.endswith("/"):
        return part in url
    return url.endswith(part) or (part + "&") in url


def stream_kind(url: str) -> Optional[str]:
    """"sub", "main", or None when the address is not a known one."""
    for sub_part, main_part in _STREAM_PAIRS:
        if _has(url, sub_part):
            return "sub"
        if _has(url, main_part):
            return "main"
    return None


def other_stream(url: str, want: str) -> Optional[str]:
    """The address of the same camera's "main" or "sub" stream (the address
    itself if it already is), or None for an address we don't know."""
    for sub_part, main_part in _STREAM_PAIRS:
        have, target = (sub_part, main_part) if want == "main" else (main_part, sub_part)
        if _has(url, target):
            return url
        if _has(url, have):
            return url.replace(have, target, 1)
    return None


@dataclass(frozen=True)
class Found:
    url: str
    label: str
    width: int
    height: int


def build_url(ip: str, user: str, password: str, path: str, port: int = 554) -> str:
    auth = ""
    if user:
        auth = quote(user, safe="") + (":" + quote(password, safe="") if password else "") + "@"
    host = ip if ":" in ip else f"{ip}:{port}"  # a port may already be in "ip"
    return f"rtsp://{auth}{host}{path}"


def candidate_urls(ip: str, user: str, password: str, port: int = 554) -> list[tuple[str, str]]:
    return [(label, build_url(ip, user, password, path, port)) for label, path in PATHS]


def autodetect(
    ip: str,
    user: str,
    password: str,
    progress: Optional[Callable[[int, int, str], None]] = None,
    cancelled: Callable[[], bool] = lambda: False,
    grab: Callable = grab_frame,
    port: int = 554,
) -> Optional[Found]:
    """Tries the usual addresses one by one until a picture comes."""
    cands = candidate_urls(ip, user, password, port)
    for i, (label, url) in enumerate(cands, 1):
        if cancelled():
            return None
        if progress:
            progress(i, len(cands), label)
        frame = grab(url, 4000, 3)
        if frame is not None:
            h, w = frame.shape[:2]
            if w / h < 1.5:
                # A squeezed light stream: the same camera's main stream is
                # wide, take it if it answers.
                main_url = other_stream(url, "main")
                if main_url and main_url != url:
                    big = grab(main_url, 4000, 3)
                    if big is not None:
                        bh, bw = big.shape[:2]
                        if bw / bh >= 1.5:
                            return Found(main_url, label.replace("доп. поток", "основной поток"), bw, bh)
            return Found(url, label, w, h)
    return None


def local_prefix() -> Optional[str]:
    """"192.168.1." for the network this computer is in."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # nothing is sent
            ip = s.getsockname()[0]
    except OSError:
        return None
    parts = ip.split(".")
    return ".".join(parts[:3]) + "." if len(parts) == 4 and ip != "127.0.0.1" else None


def scan_rtsp(
    prefix: Optional[str] = None,
    port: int = 554,
    timeout: float = 0.5,
    workers: int = 64,
    cancelled: Callable[[], bool] = lambda: False,
    hosts: Optional[list[str]] = None,
) -> list[str]:
    """IP addresses in the local network that listen on the RTSP port."""
    if hosts is None:
        prefix = prefix or local_prefix()
        if not prefix:
            return []
        hosts = [f"{prefix}{n}" for n in range(1, 255)]

    def probe(host: str) -> Optional[str]:
        if cancelled():
            return None
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return host
        except OSError:
            return None

    with ThreadPoolExecutor(max_workers=workers) as pool:
        found = [h for h in pool.map(probe, hosts) if h]
    return sorted(found, key=lambda h: [int(p) for p in h.split(".")] if h.replace(".", "").isdigit() else [0])
