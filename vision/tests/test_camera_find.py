import socket
import threading

import numpy as np

from velora_vision import camera_find as cf
from velora_vision.camera import mask_url


def test_build_url_quotes_special_characters_in_the_password():
    url = cf.build_url("10.0.0.5", "admin", "p@ss:w/rd", "/s")
    assert url == "rtsp://admin:p%40ss%3Aw%2Frd@10.0.0.5:554/s"


def test_build_url_without_login():
    assert cf.build_url("10.0.0.5", "", "", "/live") == "rtsp://10.0.0.5:554/live"


def test_build_url_keeps_a_port_given_with_the_ip():
    assert cf.build_url("10.0.0.5:8554", "a", "b", "/s") == "rtsp://a:b@10.0.0.5:8554/s"


def test_the_light_sub_streams_are_tried_first():
    cands = cf.candidate_urls("10.0.0.5", "admin", "1")
    assert "Channels/102" in cands[0][1]
    assert any("subtype=1" in u for _, u in cands[:3])


def test_autodetect_stops_at_the_first_address_that_gives_a_picture():
    tried = []

    def grab(url, timeout, attempts):
        tried.append(url)
        return np.zeros((720, 1280, 3), np.uint8) if "/stream2" in url else None

    seen = []
    found = cf.autodetect("10.0.0.5", "u", "p", progress=lambda i, n, l: seen.append(i), grab=grab)
    assert found.url.endswith("/stream2") and (found.width, found.height) == (1280, 720)
    assert len(tried) == 3 and seen == [1, 2, 3]


def test_autodetect_gives_up_with_none():
    assert cf.autodetect("10.0.0.5", "u", "p", grab=lambda *a: None) is None


def test_autodetect_can_be_cancelled():
    calls = []
    found = cf.autodetect("10.0.0.5", "u", "p", cancelled=lambda: True,
                          grab=lambda *a: calls.append(1))
    assert found is None and calls == []


def test_scan_finds_hosts_with_the_port_open():
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(5)
    port = server.getsockname()[1]
    threading.Thread(target=lambda: [server.accept() for _ in range(3)], daemon=True).start()
    try:
        found = cf.scan_rtsp(port=port, timeout=0.3, hosts=["127.0.0.1", "127.0.0.9"])
        assert "127.0.0.1" in found
    finally:
        server.close()


def test_passwords_are_hidden_in_lists_and_logs():
    assert mask_url("rtsp://admin:secret@10.0.0.5:554/s") == "rtsp://admin:***@10.0.0.5:554/s"
    assert mask_url("/videos/clip.mp4") == "/videos/clip.mp4"
