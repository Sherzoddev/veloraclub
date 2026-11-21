"""«📺 Онлайн»: live cameras inside Telegram, for the owner only.

    phone (Telegram mini app)  ──https──▶  Cloudflare quick tunnel
        ──▶ cloudflared on this computer ──▶ LiveServer on 127.0.0.1
        ──▶ Feed: reads the camera only while somebody watches

* Nothing is opened in the router: cloudflared connects out to Cloudflare and
  gets a random https://….trycloudflare.com address. The bot gives the owner a
  button with that address.
* The page is useless to anybody else: it asks Telegram for its signed
  `initData`, the server checks the signature with the bot's token and that the
  user is the owner, and only then hands out a key for the pictures.
* A camera is read only while a picture of it is asked for, and stopped
  20 seconds after the last one: nobody watching, nothing is spent.
* Pictures go JPEG by JPEG, and the page asks for the next one only when it
  has the previous one: on a slow internet the picture gets rarer but never
  late (a pushed stream would queue up in the tunnel and lag behind more and
  more). The picture size follows the speed. Zoom: two fingers / double tap;
  zoomed in, the camera's main stream is used.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import parse_qs, parse_qsl, urlsplit

log = logging.getLogger("velora_vision.live")

CLOUDFLARED_VERSION = "2026.10.0"
CLOUDFLARED_URL = ("https://github.com/cloudflare/cloudflared/releases/download/"
                   f"{CLOUDFLARED_VERSION}/cloudflared-windows-amd64.exe")
TUNNEL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
SESSION_HOURS = 12
IDLE_SECONDS = 20


# -- Telegram's signature of the mini app -----------------------------------
def check_init_data(init_data: str, bot_token: str, owner: str, now: Optional[float] = None,
                    max_age: float = 24 * 3600) -> bool:
    """True if Telegram signed this `initData` for this bot, it is fresh and
    it is the owner's (https://core.telegram.org/bots/webapps#validating-data)."""
    if not init_data or not bot_token or not owner:
        return False
    try:
        pairs = parse_qsl(init_data, keep_blank_values=True, strict_parsing=True)
    except ValueError:
        return False
    fields = dict(pairs)
    got = fields.pop("hash", "")
    check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
    secret = hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()
    want = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    if not got or not hmac.compare_digest(want, got):
        return False
    try:
        if (now or time.time()) - int(fields.get("auth_date", "0")) > max_age:
            return False
        user = json.loads(fields.get("user") or "{}")
    except ValueError:
        return False
    return str(user.get("id")) == str(owner).strip()


# -- the picture -------------------------------------------------------------
def to_16x9(frame, max_w: int):
    """A squeezed light stream back to 16:9, at most `max_w` wide."""
    import cv2

    h, w = frame.shape[:2]
    if w / h < 1.6:
        w = int(h * 16 / 9)
    if w > max_w:
        h, w = int(h * max_w / w), max_w
    if (w, h) != (frame.shape[1], frame.shape[0]):
        frame = cv2.resize(frame, (w, h), interpolation=cv2.INTER_AREA)
    return frame


def encode_jpeg(frame, quality: int = 75) -> Optional[bytes]:
    import cv2

    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return buf.tobytes() if ok else None


def _open(url: str):
    from .camera import open_capture

    return open_capture(url, 8000)


class Feed:
    """One camera stream, read in its own thread while it is wanted."""

    def __init__(self, url: str, opener: Callable = _open, idle: float = IDLE_SECONDS):
        self.url = url
        self.opener = opener
        self.idle = idle
        self.cond = threading.Condition()
        self.frame = None
        self.seq = 0
        self.failing = False
        self._wanted = 0.0
        self._thread: Optional[threading.Thread] = None
        self._cache: tuple = (None, None)

    def touch(self) -> None:
        with self.cond:
            self._wanted = time.time()
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="live-feed", daemon=True)
                self._thread.start()

    def _wanted_now(self) -> bool:
        return time.time() - self._wanted < self.idle

    def _run(self) -> None:
        while self._wanted_now():
            cap = None
            try:
                cap = self.opener(self.url)
                if cap is None or not cap.isOpened():
                    raise OSError("camera did not open")
                while self._wanted_now():
                    ok, f = cap.read()
                    if not ok or f is None:
                        raise OSError("camera stopped sending")
                    with self.cond:
                        self.frame, self.failing = f, False
                        self.seq += 1
                        self.cond.notify_all()
            except Exception as e:
                with self.cond:
                    self.failing = True
                    self.cond.notify_all()
                log.info("Онлайн: камера не отдаёт картинку (%s), пробую снова", e)
                time.sleep(3)
            finally:
                if cap is not None:
                    cap.release()

    def wait_new(self, after: int, timeout: float) -> bool:
        with self.cond:
            return self.cond.wait_for(lambda: self.seq > after or self.failing, timeout) and self.seq > after

    def jpeg(self, width: int, quality: Optional[int] = None) -> tuple[int, Optional[bytes]]:
        """(number of the frame, JPEG of it at that width)."""
        with self.cond:
            seq, frame = self.seq, self.frame
        if frame is None:
            return seq, None
        quality = quality or (70 if width <= 800 else 80)
        key = (seq, width, quality)
        if self._cache[0] == key:
            return seq, self._cache[1]
        data = encode_jpeg(to_16x9(frame, width), quality)
        self._cache = (key, data)
        return seq, data


# -- the web server (only on 127.0.0.1; the tunnel brings the phone here) ------
class LiveServer:
    def __init__(self, bot_token: Callable[[], str], owner: Callable[[], str], cameras: Callable[[], list],
                 feed_factory: Callable[[str], Feed] = Feed, port: int = 0):
        self.bot_token = bot_token
        self.owner = owner
        self.cameras = cameras
        self.feed_factory = feed_factory
        self.sessions: dict[str, float] = {}
        self.feeds: dict[str, Feed] = {}
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), self._handler())
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]

    def start(self) -> None:
        threading.Thread(target=self.httpd.serve_forever, name="live-http", daemon=True).start()

    def stop(self) -> None:
        self.stopping.set()
        self.httpd.shutdown()
        self.httpd.server_close()

    # -- helpers ---------------------------------------------------------------
    def new_session(self) -> str:
        key = secrets.token_urlsafe(24)
        now = time.time()
        with self.lock:
            self.sessions = {k: t for k, t in self.sessions.items() if t > now}
            self.sessions[key] = now + SESSION_HOURS * 3600
        return key

    def session_ok(self, key: str) -> bool:
        with self.lock:
            return bool(key) and self.sessions.get(key, 0) > time.time()

    def feed(self, cam_id: str, hd: bool) -> Optional[Feed]:
        from .clips.local_record import record_url

        cam = next((c for c in self.cameras() if c.id == cam_id), None)
        if cam is None:
            return None
        url = record_url(cam.url, "main" if hd else "light")
        with self.lock:
            f = self.feeds.get(url)
            if f is None:
                f = self.feeds[url] = self.feed_factory(url)
            return f

    def _handler(self):
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def log_message(self, *args):  # no console; nothing to log per picture
                pass

            def _send(self, code: int, body: bytes, ctype: str) -> None:
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def _json(self, code: int, data) -> None:
                self._send(code, json.dumps(data, ensure_ascii=False).encode(), "application/json")

            def do_GET(self):
                parts = urlsplit(self.path)
                q = {k: v[0] for k, v in parse_qs(parts.query).items()}
                if parts.path == "/":
                    return self._send(200, PAGE.encode(), "text/html; charset=utf-8")
                m = re.fullmatch(r"/(mjpeg|jpeg)/([A-Za-z0-9_-]+)", parts.path)
                if not m:
                    return self._send(404, b"", "text/plain")
                if not server.session_ok(q.get("k", "")):
                    return self._send(403, b"", "text/plain")
                feed = server.feed(m.group(2), q.get("hd") == "1")
                if feed is None:
                    return self._send(404, b"", "text/plain")
                try:
                    width = min(1920, max(320, int(q.get("w", "640"))))
                    fps = min(15.0, max(0.5, float(q.get("fps", "3"))))
                    quality = min(90, max(35, int(q.get("q", "0")))) if q.get("q") else None
                    after = max(0, int(q.get("after", "0")))
                except ValueError:
                    width, fps, quality, after = 640, 3.0, None, 0
                if m.group(1) == "jpeg":
                    return self._one(feed, width, quality, after)
                return self._stream(feed, width, fps, q.get("k", ""))

            def _one(self, feed: Feed, width: int, quality: Optional[int], after: int) -> None:
                """The newest picture after frame `after`. The page asks for the
                next one only when this one has arrived, so pictures never queue
                up on a slow internet: no growing delay."""
                feed.touch()
                if not feed.wait_new(after, 8):
                    # 503: the camera does not answer; 204: nothing newer yet, ask again
                    silent = getattr(feed, "failing", False) or feed.seq == 0
                    return self._send(503 if silent else 204, b"", "text/plain")
                seq, data = feed.jpeg(width, quality)
                if not data:
                    return self._send(503, b"", "text/plain")
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Seq", str(seq))
                self.end_headers()
                self.wfile.write(data)

            def _stream(self, feed: Feed, width: int, fps: float, key: str) -> None:
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Accel-Buffering", "no")
                self.end_headers()
                last = 0
                try:
                    while not server.stopping.is_set() and server.session_ok(key):
                        started = time.time()
                        feed.touch()
                        if not feed.wait_new(last, 5):
                            time.sleep(1)  # the camera does not answer: no busy loop
                            continue
                        last, data = feed.jpeg(width)
                        if data:
                            self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                             + str(len(data)).encode() + b"\r\n\r\n" + data + b"\r\n")
                            self.wfile.flush()
                        time.sleep(max(0.0, 1 / fps - (time.time() - started)))
                except (BrokenPipeError, ConnectionError, OSError):
                    pass  # the phone closed the picture

            def do_POST(self):
                if self.path != "/auth":
                    return self._send(404, b"", "text/plain")
                try:
                    size = min(int(self.headers.get("Content-Length") or 0), 16384)
                except ValueError:
                    size = 0
                init_data = self.rfile.read(size).decode("utf-8", "replace")
                if not check_init_data(init_data, server.bot_token(), server.owner()):
                    log.warning("Онлайн: открыть камеры пытался не владелец (или ссылка не из бота)")
                    return self._json(403, {"error": "Это личные камеры владельца."})
                cams = [{"id": c.id, "name": c.name, "table": c.table} for c in server.cameras()]
                return self._json(200, {"key": server.new_session(), "cams": cams})

        return Handler


# -- the tunnel ----------------------------------------------------------------
def _program_dir() -> Path:
    return Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent


def find_cloudflared(data_dir: Path) -> Optional[str]:
    name = "cloudflared.exe" if sys.platform == "win32" else "cloudflared"
    for p in (_program_dir() / name, data_dir / name):
        if p.exists() and p.stat().st_size > 1_000_000:
            return str(p)
    return shutil.which("cloudflared")


def download_cloudflared(data_dir: Path, http=None) -> Optional[str]:
    """Cloudflare's own program, from its GitHub releases (Windows only)."""
    if sys.platform != "win32":
        return None
    import requests

    http = http or requests
    data_dir.mkdir(parents=True, exist_ok=True)
    target = data_dir / "cloudflared.exe"
    tmp = target.with_suffix(".part")
    try:
        with http.get(CLOUDFLARED_URL, stream=True, timeout=60) as r:
            r.raise_for_status()
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk)
        if tmp.stat().st_size < 1_000_000:
            raise OSError("too small")
        os.replace(tmp, target)
        log.info("Онлайн: cloudflared %s скачан", CLOUDFLARED_VERSION)
        return str(target)
    except Exception as e:
        log.warning("Онлайн: не удалось скачать cloudflared: %s", e)
        try:
            tmp.unlink()
        except OSError:
            pass
        return None


def _no_window() -> int:
    return getattr(subprocess, "CREATE_NO_WINDOW", 0) if sys.platform == "win32" else 0


class Tunnel(threading.Thread):
    """Keeps a Cloudflare quick tunnel to the local server; `url` is its
    public address (it changes when the tunnel starts again)."""

    def __init__(self, port: int, data_dir: Path, find: Callable = find_cloudflared,
                 download: Callable = download_cloudflared, popen: Callable = subprocess.Popen):
        super().__init__(name="live-tunnel", daemon=True)
        self.port = port
        self.data_dir = data_dir
        self.find, self.download, self.popen = find, download, popen
        self.url: Optional[str] = None
        self.status = "подключаю…"
        self.stop_event = threading.Event()
        self.proc = None

    def stop(self) -> None:
        self.stop_event.set()
        if self.proc is not None:
            try:
                self.proc.terminate()
            except OSError:
                pass

    def run(self) -> None:
        while not self.stop_event.is_set():
            exe = self.find(self.data_dir)
            if not exe:
                self.status = "скачиваю cloudflared (один раз, ~60 МБ)…"
                exe = self.download(self.data_dir)
            if not exe:
                self.status = "нет программы cloudflared: скачайте Velora Vision заново или проверьте интернет."
                self.stop_event.wait(300)
                continue
            self.status = "подключаю…"
            try:
                self.proc = self.popen(
                    [exe, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{self.port}"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                    creationflags=_no_window())
                for raw in self.proc.stderr:
                    line = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
                    m = TUNNEL_RE.search(line)
                    if m and self.url != m.group(0):
                        self.url = m.group(0)
                        self.status = "готов"
                        log.info("Онлайн: туннель готов")
                    if self.stop_event.is_set():
                        break
                self.proc.wait()
            except OSError as e:
                log.warning("Онлайн: cloudflared не запустился: %s", e)
            self.url = None
            if not self.stop_event.is_set():
                self.status = "туннель прервался, подключаю снова…"
                self.stop_event.wait(10)


class LiveService:
    """The server and its tunnel together; started with «Мой бот»."""

    def __init__(self, bot_token: Callable[[], str], owner: Callable[[], str], cameras: Callable[[], list],
                 data_dir: Path, tunnel_factory=Tunnel):
        self.server = LiveServer(bot_token, owner, cameras)
        self.tunnel = tunnel_factory(self.server.port, data_dir)

    def start(self) -> None:
        self.server.start()
        self.tunnel.start()

    def stop(self) -> None:
        self.tunnel.stop()
        self.server.stop()

    def url(self) -> Optional[str]:
        return self.tunnel.url

    def status(self) -> str:
        return self.tunnel.status


PAGE = r"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>Камеры онлайн</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
:root{--bg:#0f1115;--fg:#f2f4f7;--muted:#9aa3af;--card:#1a1d24;--accent:#2ea6ff;
--top:max(env(safe-area-inset-top),var(--tg-content-safe-area-inset-top,0px));
--bottom:max(env(safe-area-inset-bottom),var(--tg-safe-area-inset-bottom,0px))}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.35 -apple-system,system-ui,Segoe UI,Roboto,sans-serif}
header{padding:calc(12px + var(--top)) 16px 4px;display:flex;align-items:center;gap:8px}
h1{font-size:17px;margin:0;flex:1}.dot{width:9px;height:9px;border-radius:50%;background:#e5484d}
.dot.on{background:#30a46c}#msg{padding:8px 16px;color:var(--muted)}
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px;padding:8px 12px calc(16px + var(--bottom))}
.cam{background:var(--card);border-radius:12px;overflow:hidden;cursor:pointer;position:relative}
.cam img{display:block;width:100%;aspect-ratio:16/9;object-fit:contain;background:#000}
.cam div{padding:8px 10px;font-weight:600}.cam small{color:var(--muted);font-weight:400}
.off{position:absolute;left:0;right:0;top:0;aspect-ratio:16/9;display:none;align-items:center;justify-content:center;
color:#fff;background:#000a;font-size:13px;text-align:center;padding:8px}
.off.show{display:flex}
#big{position:fixed;inset:0;background:#000;display:none;z-index:5}
#view{position:absolute;inset:0;overflow:hidden;touch-action:none;display:flex;align-items:center;justify-content:center}
#bigimg{max-width:100%;max-height:100%;transform-origin:center center;will-change:transform;user-select:none;-webkit-user-drag:none}
#bigoff{position:absolute;inset:0}
#top{position:absolute;left:0;right:0;top:0;display:flex;gap:8px;align-items:center;
padding:calc(10px + var(--top)) 12px 18px;background:linear-gradient(#000c,transparent);pointer-events:none}
#top span{flex:1;font-weight:600;text-shadow:0 1px 2px #000}#zl{color:var(--muted);font-size:13px}
#bar{position:absolute;left:0;right:0;bottom:0;display:flex;gap:8px;justify-content:center;flex-wrap:wrap;
padding:18px 12px calc(12px + var(--bottom));background:linear-gradient(transparent,#000c)}
button{background:#ffffff26;color:#fff;border:0;border-radius:10px;min-width:44px;height:42px;padding:0 12px;font:inherit;font-weight:600}
button.on{background:var(--accent)}button[hidden]{display:none}
</style></head><body>
<header><span class="dot" id="dot"></span><h1>Камеры онлайн</h1></header>
<div id="msg">Подключаю…</div><div id="grid"></div>
<div id="big"><div id="view"><img id="bigimg" alt="" draggable="false"></div>
<div class="off" id="bigoff">Камера не отвечает, пробую снова…</div>
<div id="top"><span id="bigname"></span><span id="zl"></span></div>
<div id="bar"><button id="zout" aria-label="Уменьшить">－</button><button id="zin" aria-label="Увеличить">＋</button>
<button id="hd">HD</button><button id="fs" hidden aria-label="Весь экран">⛶</button><button id="close" aria-label="Закрыть">✕</button></div></div>
<script>
const tg = window.Telegram && Telegram.WebApp;
if (tg) { tg.ready(); tg.expand(); try { tg.disableVerticalSwipes(); } catch (e) {} }
const $ = id => document.getElementById(id);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let key = "";

// The phone asks for the next picture only when it has the previous one, so on
// a slow internet the picture gets rarer, never late. The size of the picture
// follows the speed: slow answers make it smaller, fast ones bigger again.
class Player {
  constructor(img, off, camId, o) {
    Object.assign(this, {img, off, camId, o, on: true, shown: 0, req: 0, gen: 0, url: null});
    this.w = o.start;
    for (let i = 0; i < o.inflight; i++) this.loop();
  }
  stop() { this.on = false; if (this.url) URL.revokeObjectURL(this.url); this.url = null; }
  setHD(hd) {
    if (this.o.hd === hd) return;
    this.o.hd = hd; this.gen++; this.shown = 0; this.req = 0;
    this.w = hd ? this.o.hdStart : this.o.start;
  }
  get list() { return this.o.hd ? this.o.hdSizes : this.o.sizes; }
  async loop() {
    while (this.on) {
      const gen = this.gen, after = Math.max(this.shown, this.req);
      this.req = after + 1;
      const t0 = performance.now();
      let r;
      try {
        r = await fetch(`/jpeg/${this.camId}?k=${encodeURIComponent(key)}&w=${this.w}&q=${this.o.hd ? this.o.hdq : this.o.q}` +
                        `&after=${after}${this.o.hd ? "&hd=1" : ""}`, {cache: "no-store"});
      } catch (e) { this.req = 0; await sleep(2000); continue; }
      if (!this.on) return;
      if (r.status === 403) { this.on = false; $("msg").textContent = "Доступ истёк: закройте окно и нажмите «📺 Онлайн» снова."; return; }
      if (r.status === 204) { this.req = 0; continue; }
      if (r.status !== 200) { this.req = 0; this.off.classList.add("show"); await sleep(2000); continue; }
      const seq = +r.headers.get("X-Seq");
      const blob = await r.blob();
      if (!this.on || gen !== this.gen) continue;
      this.adapt(performance.now() - t0);
      if (seq > this.shown) {
        this.shown = seq;
        const u = URL.createObjectURL(blob), old = this.url;
        this.url = u; this.img.src = u;
        if (old) setTimeout(() => URL.revokeObjectURL(old), 2000);
        this.off.classList.remove("show"); $("dot").classList.add("on");
      }
      const rest = this.o.gap - (performance.now() - t0);
      if (rest > 0) await sleep(rest);
    }
  }
  adapt(ms) {
    const s = this.list; let i = s.indexOf(this.w); if (i < 0) i = 0;
    if (ms > 900 && i > 0) this.w = s[i - 1];
    else if (ms < 300 && i < s.length - 1) this.w = s[i + 1];
  }
}
const GRID = {inflight: 1, gap: 350, q: 60, sizes: [320, 480, 640], start: 480};
const BIG = {inflight: 2, gap: 0, q: 72, sizes: [640, 960, 1280], start: 960,
             hdq: 80, hdSizes: [960, 1280, 1600, 1920], hdStart: 1280, hd: false};

// -- zoom: two fingers, double tap, mouse wheel, ＋/－ --------------------------
const view = $("view"), bigimg = $("bigimg");
let z = {s: 1, x: 0, y: 0}, hdByHand = false, big = null, current = null;
function bounds() {
  const W = view.clientWidth, H = view.clientHeight;
  const w = bigimg.clientWidth || W, h = bigimg.clientHeight || H;
  return {mx: Math.max(0, (w * z.s - W) / 2), my: Math.max(0, (h * z.s - H) / 2)};
}
function apply() {
  z.s = Math.min(8, Math.max(1, z.s));
  const b = bounds();
  z.x = Math.min(b.mx, Math.max(-b.mx, z.x)); z.y = Math.min(b.my, Math.max(-b.my, z.y));
  bigimg.style.transform = `translate(${z.x}px,${z.y}px) scale(${z.s})`;
  $("zl").textContent = z.s > 1.05 ? z.s.toFixed(1) + "×" : "";
  // Zoomed in: the camera's main stream, else the small one shows blocks.
  if (big && !hdByHand) big.setHD(z.s >= 2);
}
// zoom by factor k keeping the point (px, py) of the screen in place
function zoomAt(k, px, py) {
  const r = view.getBoundingClientRect();
  const cx = px - r.left - r.width / 2, cy = py - r.top - r.height / 2;
  const s2 = Math.min(8, Math.max(1, z.s * k)), f = s2 / z.s;
  z.x = cx - (cx - z.x) * f; z.y = cy - (cy - z.y) * f; z.s = s2; apply();
}
function center() { const r = view.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }
const pts = new Map(); let pinch = null, lastTap = 0;
view.addEventListener("pointerdown", e => {
  view.setPointerCapture(e.pointerId); pts.set(e.pointerId, {x: e.clientX, y: e.clientY});
  if (pts.size === 2) { const [a, b] = [...pts.values()]; pinch = {d: Math.hypot(a.x - b.x, a.y - b.y)}; }
  if (pts.size === 1) {
    const now = Date.now();
    if (now - lastTap < 300) { if (z.s > 1.05) { z = {s: 1, x: 0, y: 0}; apply(); } else zoomAt(3, e.clientX, e.clientY); lastTap = 0; }
    else lastTap = now;
  }
});
view.addEventListener("pointermove", e => {
  const p = pts.get(e.pointerId); if (!p) return;
  const nx = e.clientX, ny = e.clientY;
  if (pts.size === 1 && z.s > 1) { z.x += nx - p.x; z.y += ny - p.y; apply(); }
  p.x = nx; p.y = ny;
  if (pts.size === 2 && pinch) {
    const [a, b] = [...pts.values()], d = Math.hypot(a.x - b.x, a.y - b.y);
    if (d > 10) { zoomAt(d / pinch.d, (a.x + b.x) / 2, (a.y + b.y) / 2); pinch.d = d; }
  }
});
const up = e => { pts.delete(e.pointerId); if (pts.size < 2) pinch = null; };
view.addEventListener("pointerup", up); view.addEventListener("pointercancel", up);
view.addEventListener("wheel", e => { e.preventDefault(); zoomAt(e.deltaY < 0 ? 1.25 : 0.8, e.clientX, e.clientY); }, {passive: false});
$("zin").onclick = () => zoomAt(1.6, ...center());
$("zout").onclick = () => zoomAt(1 / 1.6, ...center());
window.addEventListener("resize", apply);

// -- screens -----------------------------------------------------------------
let cams = [], grid = [];
function startGrid() {
  stopGrid();
  document.querySelectorAll(".cam").forEach(el =>
    grid.push(new Player(el.querySelector("img"), el.querySelector(".off"), el.dataset.id, {...GRID})));
}
function stopGrid() { grid.forEach(p => p.stop()); grid = []; }
function openBig(cam) {
  current = cam; stopGrid();
  $("bigname").textContent = cam.name; $("big").style.display = "block";
  z = {s: 1, x: 0, y: 0}; hdByHand = false; $("hd").classList.remove("on");
  bigimg.removeAttribute("src");
  big = new Player(bigimg, $("bigoff"), cam.id, {...BIG}); apply();
  if (tg) tg.BackButton.show();
}
function closeBig() {
  if (big) big.stop(); big = null; current = null;
  $("big").style.display = "none"; $("bigoff").classList.remove("show");
  if (tg) { tg.BackButton.hide(); if (tg.isFullscreen) try { tg.exitFullscreen(); } catch (e) {} }
  startGrid();
}
$("close").onclick = closeBig;
$("hd").onclick = () => {
  hdByHand = !$("hd").classList.contains("on");
  $("hd").classList.toggle("on", hdByHand);
  if (big) big.setHD(hdByHand || z.s >= 2);
};
if (tg && tg.isVersionAtLeast && tg.isVersionAtLeast("8.0")) {
  $("fs").hidden = false;
  $("fs").onclick = () => { try { tg.isFullscreen ? tg.exitFullscreen() : tg.requestFullscreen(); } catch (e) {} };
}
if (tg) tg.BackButton.onClick(closeBig);
document.addEventListener("visibilitychange", () => {
  // the app hidden: stop asking the computer for pictures
  if (document.hidden) { stopGrid(); if (big) big.stop(); }
  else if (current) openBig(current); else if (key) startGrid();
});

fetch("/auth", {method: "POST", body: tg ? tg.initData : ""})
  .then(r => r.json().then(d => ({ok: r.ok, d})))
  .then(({ok, d}) => {
    if (!ok) { $("msg").textContent = d.error || "Нет доступа."; return; }
    key = d.key; cams = d.cams;
    if (!cams.length) { $("msg").textContent = "В программе нет камер."; return; }
    $("msg").textContent = "Нажмите на камеру: на весь экран. Увеличить — двумя пальцами или двойным касанием.";
    for (const c of cams) {
      const el = document.createElement("div"); el.className = "cam"; el.dataset.id = c.id;
      const img = document.createElement("img"); img.alt = c.name;
      const off = document.createElement("div"); off.className = "off"; off.textContent = "Камера не отвечает…";
      const t = document.createElement("div"); t.textContent = c.name;
      if (c.table) { const s = document.createElement("small"); s.textContent = " · " + c.table; t.append(s); }
      el.append(img, off, t); el.onclick = () => openBig(c); $("grid").append(el);
    }
    startGrid();
  })
  .catch(() => { $("msg").textContent = "Нет связи с компьютером клуба. Он включён, программа открыта?"; });
</script></body></html>
"""
