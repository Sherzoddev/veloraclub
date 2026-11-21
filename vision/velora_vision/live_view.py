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
* Pictures go as MJPEG (a stream of JPEGs): every phone shows it, nothing to
  install; the page falls back to asking JPEG by JPEG if a stream stalls.
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

    def jpeg(self, width: int) -> tuple[int, Optional[bytes]]:
        """(number of the frame, JPEG of it at that width)."""
        with self.cond:
            seq, frame = self.seq, self.frame
        if frame is None:
            return seq, None
        key = (seq, width)
        if self._cache[0] == key:
            return seq, self._cache[1]
        data = encode_jpeg(to_16x9(frame, width), 70 if width <= 800 else 80)
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
                except ValueError:
                    width, fps = 640, 3.0
                if m.group(1) == "jpeg":
                    return self._one(feed, width)
                return self._stream(feed, width, fps, q.get("k", ""))

            def _one(self, feed: Feed, width: int) -> None:
                feed.touch()
                feed.wait_new(0, 10)
                _, data = feed.jpeg(width)
                if not data:
                    return self._send(503, b"", "text/plain")
                self._send(200, data, "image/jpeg")

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
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Камеры онлайн</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
:root{--bg:#0f1115;--fg:#f2f4f7;--muted:#9aa3af;--card:#1a1d24;--accent:#2ea6ff}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.35 -apple-system,system-ui,Segoe UI,Roboto,sans-serif}
header{padding:12px 16px 4px;display:flex;align-items:center;gap:8px}
h1{font-size:17px;margin:0;flex:1}.dot{width:9px;height:9px;border-radius:50%;background:#e5484d}
.dot.on{background:#30a46c}#msg{padding:8px 16px;color:var(--muted)}
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px;padding:8px 12px 16px}
.cam{background:var(--card);border-radius:12px;overflow:hidden;cursor:pointer}
.cam img,#big img{display:block;width:100%;aspect-ratio:16/9;object-fit:contain;background:#000}
.cam div{padding:8px 10px;font-weight:600}.cam small{color:var(--muted);font-weight:400}
#big{position:fixed;inset:0;background:#000;display:none;flex-direction:column;justify-content:center}
#big img{aspect-ratio:auto;max-height:100%;height:auto}
#bar{position:absolute;left:0;right:0;bottom:0;display:flex;gap:8px;padding:12px;
padding-bottom:calc(12px + env(safe-area-inset-bottom));background:linear-gradient(transparent,#000c)}
#bar span{flex:1;align-self:center;font-weight:600}
button{background:#ffffff22;color:#fff;border:0;border-radius:10px;padding:9px 14px;font:inherit}
button.on{background:var(--accent)}
</style></head><body>
<header><span class="dot" id="dot"></span><h1>Камеры онлайн</h1></header>
<div id="msg">Подключаю…</div><div id="grid"></div>
<div id="big"><img id="bigimg" alt=""><div id="bar"><span id="bigname"></span>
<button id="hd">HD</button><button id="close">✕</button></div></div>
<script>
const tg = window.Telegram && Telegram.WebApp; if (tg) { tg.ready(); tg.expand(); }
let key = "", hd = false, current = null;
const $ = id => document.getElementById(id);
function src(kind, id, w, fps, extra) {
  return `/${kind}/${id}?k=${encodeURIComponent(key)}&w=${w}&fps=${fps}${extra||""}&t=${Date.now()}`;
}
// MJPEG first; if no picture comes, ask JPEG by JPEG instead.
function play(img, id, w, fps, extra) {
  let got = false, timer = null;
  img.onload = () => { got = true; $("dot").classList.add("on"); };
  img.src = src("mjpeg", id, w, fps, extra);
  setTimeout(() => {
    if (got || img.dataset.cam !== id) return;
    const step = () => {
      if (img.dataset.cam !== id || img.dataset.mode !== "poll") return;
      const n = new Image();
      n.onload = () => { img.src = n.src; timer = setTimeout(step, 1000 / fps); };
      n.onerror = () => { timer = setTimeout(step, 2000); };
      n.src = src("jpeg", id, w, fps, extra);
    };
    img.dataset.mode = "poll"; step();
  }, 7000);
}
function stop(img) { img.dataset.cam = ""; img.dataset.mode = ""; img.removeAttribute("src"); }
function openBig(cam) {
  current = cam; $("bigname").textContent = cam.name; $("big").style.display = "flex";
  document.querySelectorAll(".cam img").forEach(stop);
  const img = $("bigimg"); img.dataset.cam = cam.id; img.dataset.mode = "";
  play(img, cam.id, hd ? 1600 : 1024, 8, hd ? "&hd=1" : "");
  if (tg) { tg.BackButton.show(); }
}
function closeBig() {
  stop($("bigimg")); $("big").style.display = "none"; current = null;
  if (tg) tg.BackButton.hide(); startGrid();
}
let cams = [];
function startGrid() {
  document.querySelectorAll(".cam img").forEach((img) => {
    img.dataset.cam = img.dataset.id; img.dataset.mode = "";
    play(img, img.dataset.id, 640, 2);
  });
}
$("close").onclick = closeBig;
$("hd").onclick = () => { hd = !hd; $("hd").classList.toggle("on", hd); if (current) openBig(current); };
if (tg) tg.BackButton.onClick(closeBig);
fetch("/auth", {method: "POST", body: tg ? tg.initData : ""})
  .then(r => r.json().then(d => ({ok: r.ok, d})))
  .then(({ok, d}) => {
    if (!ok) { $("msg").textContent = d.error || "Нет доступа."; return; }
    key = d.key; cams = d.cams;
    if (!cams.length) { $("msg").textContent = "В программе нет камер."; return; }
    $("msg").textContent = "Нажмите на камеру, чтобы открыть на весь экран.";
    for (const c of cams) {
      const el = document.createElement("div"); el.className = "cam";
      const img = document.createElement("img"); img.dataset.id = c.id; img.alt = c.name;
      const t = document.createElement("div"); t.textContent = c.name;
      if (c.table) { const s = document.createElement("small"); s.textContent = " · " + c.table; t.append(s); }
      el.append(img, t); el.onclick = () => openBig(c); $("grid").append(el);
    }
    startGrid();
  })
  .catch(() => { $("msg").textContent = "Нет связи с компьютером клуба. Он включён?"; });
</script></body></html>
"""
