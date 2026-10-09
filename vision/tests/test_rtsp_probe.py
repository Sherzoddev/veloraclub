"""The camera is asked over RTSP, and the answer is turned into a reason.
A tiny RTSP server on localhost plays the camera."""
import socket
import threading

import pytest

from velora_vision import rtsp_probe
from velora_vision.rtsp_probe import _md5


class FakeCamera:
    """Digest login, one good stream path; everything else is 404."""

    def __init__(self, user="admin", password="pw", good_path="/ok", realm="cam", answer_all_401=False,
                 h265_only=False):
        self.user, self.password, self.good_path, self.realm = user, password, good_path, realm
        self.answer_all_401 = answer_all_401
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(8)
        self.port = self.server.getsockname()[1]
        self.stop = False
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        self.server.settimeout(0.2)
        while not self.stop:
            try:
                conn, _ = self.server.accept()
            except (socket.timeout, OSError):
                continue
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        with conn:
            conn.settimeout(2)
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            text = data.decode()
            first = text.split("\r\n")[0]
            method, url, _ = first.split(" ")
            path = "/" + url.split("/", 3)[3] if url.count("/") >= 3 else "/"
            auth = next((l for l in text.split("\r\n") if l.lower().startswith("authorization:")), "")
            if not auth or self.answer_all_401:
                conn.sendall(
                    b'RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm="cam", nonce="abc123"\r\n\r\n')
                return
            ha1 = _md5(f"{self.user}:{self.realm}:{self.password}")
            ha2 = _md5(f"{method}:{url}")
            expected = _md5(f"{ha1}:abc123:{ha2}")
            if f'response="{expected}"' not in auth:
                conn.sendall(
                    b'RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Digest realm="cam", nonce="abc123"\r\n\r\n')
                return
            if path == self.good_path:
                conn.sendall(b"RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n")
            else:
                conn.sendall(b"RTSP/1.0 404 Not Found\r\nCSeq: 2\r\n\r\n")

    def close(self):
        self.stop = True
        self.server.close()


@pytest.fixture
def cam():
    c = FakeCamera()
    yield c
    c.close()


def host(c):
    return f"127.0.0.1:{c.port}"


def test_describe_statuses(cam):
    assert rtsp_probe.describe("127.0.0.1", cam.port, "/ok", "admin", "pw") == 200
    assert rtsp_probe.describe("127.0.0.1", cam.port, "/nope", "admin", "pw") == 404
    assert rtsp_probe.describe("127.0.0.1", cam.port, "/ok", "admin", "wrong") == 401


def test_explain_wrong_password(cam):
    text = rtsp_probe.explain(host(cam), "admin", "wrong")
    assert "не принимает логин или пароль" in text


def test_explain_good_login_unknown_path(cam):
    text = rtsp_probe.explain(host(cam), "admin", "pw")
    assert "адрес потока" in text and "готовый адрес" in text


def test_explain_stream_there_but_unreadable():
    c = FakeCamera(good_path="/Streaming/Channels/102")
    try:
        text = rtsp_probe.explain(host(c), "admin", "pw")
        assert "картинку не удалось прочитать" in text
    finally:
        c.close()


def test_explain_nobody_listens():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()  # nothing listens here any more
    text = rtsp_probe.explain(f"127.0.0.1:{port}", "admin", "pw", timeout=1)
    assert "не отвечает на порту" in text


def test_explain_not_an_rtsp_device():
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    def serve():
        conn, _ = srv.accept()
        conn.recv(4096)
        conn.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        conn.close()

    threading.Thread(target=serve, daemon=True).start()
    text = rtsp_probe.explain(f"127.0.0.1:{port}", "admin", "pw", timeout=1)
    srv.close()
    assert "отвечает не камера" in text
