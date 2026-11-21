import hashlib
import hmac
import json
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlencode

import numpy as np
import pytest

from velora_vision import live_view as lv
from velora_vision.settings import CameraSettings

TOKEN = "123:ABC"
OWNER = "555"
CAMS = [CameraSettings("a1", "Камера 1", "rtsp://u:p@10.0.0.5/cam/realmonitor?channel=1&subtype=0", "Стол 1")]


def signed(user_id=OWNER, token=TOKEN, age=0, tamper=False):
    fields = {"auth_date": str(int(time.time() - age)), "query_id": "AAH",
              "user": json.dumps({"id": int(user_id), "first_name": "Ш"}, ensure_ascii=False)}
    check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
    secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
    fields["hash"] = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    if tamper:
        fields["user"] = fields["user"].replace(str(user_id), "777")
    return urlencode(fields)


def test_only_telegrams_fresh_signature_of_the_owner_passes():
    assert lv.check_init_data(signed(), TOKEN, OWNER)
    assert not lv.check_init_data(signed(user_id="777"), TOKEN, OWNER)      # somebody else
    assert not lv.check_init_data(signed(token="999:X"), TOKEN, OWNER)      # another bot
    assert not lv.check_init_data(signed(tamper=True), TOKEN, OWNER)        # changed after signing
    assert not lv.check_init_data(signed(age=2 * 86400), TOKEN, OWNER)      # old
    assert not lv.check_init_data("", TOKEN, OWNER)
    assert not lv.check_init_data(signed(), TOKEN, "")                      # not paired yet
    assert not lv.check_init_data("garbage&&==", TOKEN, OWNER)


class FakeFeed:
    def __init__(self, url):
        self.url = url
        self.seq = 0
        self.touched = 0

    def touch(self):
        self.touched += 1

    def wait_new(self, after, timeout):
        time.sleep(0.01)
        self.seq = after + 1
        return True

    def jpeg(self, width):
        return self.seq, b"\xff\xd8" + str(width).encode() + b"\xff\xd9"


@pytest.fixture
def server():
    feeds = []

    def factory(url):
        f = FakeFeed(url)
        feeds.append(f)
        return f

    s = lv.LiveServer(lambda: TOKEN, lambda: OWNER, lambda: CAMS, feed_factory=factory)
    s.start()
    s.feeds_made = feeds
    yield s
    s.stop()


def get(server, path, data=None):
    req = urllib.request.Request(f"http://127.0.0.1:{server.port}{path}", data=data)
    return urllib.request.urlopen(req, timeout=5)


def test_the_page_is_served_but_pictures_need_a_key(server):
    page = get(server, "/").read().decode()
    assert "telegram-web-app.js" in page and "/auth" in page
    with pytest.raises(urllib.error.HTTPError) as e:
        get(server, "/jpeg/a1?k=wrong")
    assert e.value.code == 403


def test_a_stranger_gets_no_key(server):
    with pytest.raises(urllib.error.HTTPError) as e:
        get(server, "/auth", signed(user_id="777").encode())
    assert e.value.code == 403
    assert not server.sessions


def test_the_owner_gets_a_key_and_pictures(server):
    answer = json.loads(get(server, "/auth", signed().encode()).read())
    assert answer["cams"] == [{"id": "a1", "name": "Камера 1", "table": "Стол 1"}]
    key = answer["key"]
    one = get(server, f"/jpeg/a1?k={key}&w=800")
    assert one.headers["Content-Type"] == "image/jpeg" and one.read() == b"\xff\xd8800\xff\xd9"
    # the light stream by default, the main one for HD
    get(server, f"/jpeg/a1?k={key}&hd=1").read()
    assert sorted(f.url[-9:] for f in server.feeds_made) == ["subtype=0", "subtype=1"]
    with pytest.raises(urllib.error.HTTPError) as e:
        get(server, f"/jpeg/zz?k={key}")
    assert e.value.code == 404


def test_the_stream_sends_frames_one_after_another(server):
    key = json.loads(get(server, "/auth", signed().encode()).read())["key"]
    r = get(server, f"/mjpeg/a1?k={key}&w=640&fps=15")
    assert r.headers["Content-Type"].startswith("multipart/x-mixed-replace")
    data = b""
    while data.count(b"--frame") < 3:
        data += r.read1(4096)
    assert data.count(b"Content-Type: image/jpeg") >= 2
    r.close()


def test_an_expired_session_stops_working(server):
    key = server.new_session()
    server.sessions[key] = time.time() - 1
    with pytest.raises(urllib.error.HTTPError):
        get(server, f"/jpeg/a1?k={key}")


def test_a_feed_reads_only_while_wanted_and_stretches_to_16x9():
    opened = []

    class Cap:
        def __init__(self):
            self.n = 0

        def isOpened(self):
            return True

        def read(self):
            self.n += 1
            time.sleep(0.005)
            return True, np.full((576, 704, 3), self.n % 255, np.uint8)

        def release(self):
            opened.append("released")

    feed = lv.Feed("rtsp://x", opener=lambda url: Cap(), idle=0.3)
    feed.touch()
    assert feed.wait_new(0, 3)
    seq, data = feed.jpeg(640)
    import cv2
    img = cv2.imdecode(np.frombuffer(data, np.uint8), 1)
    assert img.shape[:2] == (360, 640)
    assert feed.jpeg(640)[1] is data or feed.seq != seq       # same frame: not encoded twice
    time.sleep(1.0)
    assert opened == ["released"]                             # nobody watching: camera closed


def test_a_feed_that_cannot_open_does_not_hang():
    feed = lv.Feed("rtsp://x", opener=lambda url: None, idle=0.2)
    feed.touch()
    assert not feed.wait_new(0, 1)
    assert feed.jpeg(640) == (0, None)


class FakeProc:
    def __init__(self, lines):
        self.stderr = iter(lines)
        self.terminated = False

    def wait(self):
        return 0

    def terminate(self):
        self.terminated = True


def test_the_tunnel_finds_its_address():
    lines = [b"INF Thank you for trying Cloudflare Tunnel\n",
             b"INF |  https://quiet-river-abc-12.trycloudflare.com  |\n"]
    started = []
    seen = []

    def popen(cmd, **kw):
        started.append(cmd)
        return FakeProc(lines)

    t = lv.Tunnel(8123, None, find=lambda d: "cloudflared", download=lambda d: None, popen=popen)


    def wait(timeout=None):  # after the first run: remember the address, stop
        seen.append(t.url)
        t.stop_event.set()
        return True
    t.stop_event.wait = wait
    t.run()
    assert started[0][-2:] == ["--url", "http://127.0.0.1:8123"]
    assert "--no-autoupdate" in started[0]
    assert t.url is None                    # the process ended: no address any more


def test_the_tunnel_address_is_kept_while_it_runs():
    t = lv.Tunnel(1, None, find=lambda d: "c", download=lambda d: None, popen=None)
    proc_lines = threading.Event()

    class Proc:
        def __init__(self):
            def gen():
                yield b"INF |  https://a-b.trycloudflare.com  |\n"
                proc_lines.wait(3)
            self.stderr = gen()

        def wait(self):
            return 0

        def terminate(self):
            proc_lines.set()

    t.popen = lambda cmd, **kw: Proc()
    t.start()
    end = time.time() + 3
    while time.time() < end and t.url is None:
        time.sleep(0.01)
    assert t.url == "https://a-b.trycloudflare.com" and t.status == "готов"
    t.stop()
    t.join(3)
    assert not t.is_alive()


def test_without_cloudflared_the_reason_is_shown():
    t = lv.Tunnel(1, None, find=lambda d: None, download=lambda d: None, popen=None)
    t.stop_event.wait = lambda timeout=None: t.stop_event.set() or True
    t.run()
    assert "нет программы cloudflared" in t.status


def test_the_build_bundles_the_same_cloudflared_version():
    from pathlib import Path
    wf = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "vision-build.yml"
    if not wf.exists():
        pytest.skip("not in the repository")
    assert f"/download/{lv.CLOUDFLARED_VERSION}/cloudflared-windows-amd64.exe" in wf.read_text(encoding="utf-8")
