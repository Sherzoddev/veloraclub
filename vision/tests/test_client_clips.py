import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path

import pytest
import requests

from velora_vision.clips.archive import (check_archive, clip_window, cut_clip, cut_command,
                                         ffmpeg_exe, playback_url, supports_playback)
from velora_vision.clips.client_clips import (ClipRequest, ClipRequestWorker, ClipsClient,
                                              ClipsError, table_sources)
from velora_vision.settings import CameraSettings

LIVE = "rtsp://admin:Pa%40ss@192.168.1.64:554/cam/realmonitor?channel=1&subtype=1"
T = datetime(2026, 11, 14, 16, 47, 5, tzinfo=timezone.utc)  # 21:47:05 in Tashkent


def test_playback_url_uses_the_clubs_local_time():
    url = playback_url(LIVE, *clip_window(T, 12, 18), tz="Asia/Tashkent")
    assert url == (
        "rtsp://admin:Pa%40ss@192.168.1.64:554/cam/playback"
        "?channel=1&subtype=0&starttime=2026_11_14_21_46_53&endtime=2026_11_14_21_47_23"
    )


def test_playback_url_keeps_the_recorder_channel():
    live = "rtsp://u:p@10.0.0.5:554/cam/realmonitor?channel=3&subtype=0"
    assert "channel=3&subtype=0&starttime=" in playback_url(live, T, T, "Asia/Tashkent")


def test_playback_url_crosses_midnight_in_local_time():
    late = datetime(2026, 11, 14, 19, 30, 0, tzinfo=timezone.utc)  # 00:30 next day
    url = playback_url(LIVE, late, late, "Asia/Tashkent")
    assert "starttime=2026_11_15_00_30_00" in url


@pytest.mark.parametrize("live", [
    "rtsp://u:p@1.2.3.4/Streaming/Channels/101",  # Hikvision
    "C:/videos/match.mp4",
    "http://1.2.3.4/cam/realmonitor",
])
def test_only_dahua_addresses_can_be_cut(live):
    assert not supports_playback(live)
    assert playback_url(live, T, T, "Asia/Tashkent") is None


def test_table_sources_skips_files_other_brands_and_cameras_without_a_table():
    cams = [
        CameraSettings("a", "A", LIVE, "Стол 1"),
        CameraSettings("b", "B", "rtsp://u:p@1.2.3.4/Streaming/Channels/101", "Стол 2"),
        CameraSettings("c", "C", "video.mp4", "Стол 3"),
        CameraSettings("d", "D", LIVE.replace("64", "65"), "Стол 1"),
        CameraSettings("e", "E", LIVE.replace("64", "66"), "  "),
    ]
    assert table_sources(cams) == {"Стол 1": LIVE}


def test_cut_command_asks_for_tcp_and_small_h264(tmp_path):
    cmd = cut_command("ffmpeg", LIVE, 30, tmp_path / "x.mp4")
    assert cmd[cmd.index("-rtsp_transport") + 1] == "tcp"
    assert cmd[cmd.index("-t") + 1] == "30"
    assert "libx264" in cmd and "-an" in cmd
    assert "-rtsp_transport" not in cut_command("ffmpeg", "file.mp4", 30, tmp_path / "x.mp4")


def test_a_failed_ffmpeg_never_logs_the_password(tmp_path, caplog):
    class Proc:
        returncode = 1
        stderr = b"Server returned 401 for rtsp://admin:Pa%40ss@192.168.1.64"

    why = cut_clip(LIVE, 30, tmp_path / "x.mp4", run=lambda *a, **k: Proc(), exe="ffmpeg")
    assert why == "NO_RECORDING"
    assert "Pa%40ss" not in caplog.text and "admin" not in caplog.text.replace("Server", "")


def test_cut_clip_timeout_and_missing_ffmpeg(tmp_path):
    def boom(*a, **k):
        raise subprocess.TimeoutExpired("ffmpeg", 1)

    assert cut_clip(LIVE, 30, tmp_path / "x.mp4", run=boom, exe="ffmpeg") == "TIMEOUT"
    assert cut_clip(LIVE, 30, tmp_path / "x.mp4", run=boom, exe=None) in ("TIMEOUT", "NO_FFMPEG")


@pytest.mark.skipif(not ffmpeg_exe(), reason="ffmpeg is not available")
def test_cut_a_real_video_into_a_small_playable_clip(tmp_path):
    exe = ffmpeg_exe()
    source = tmp_path / "match.mp4"
    subprocess.run(
        [exe, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "testsrc=size=1280x720:rate=15", "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p",
         str(source)], check=True)
    out = tmp_path / "clip.mp4"
    assert cut_clip(str(source), 4, out, exe=exe) is None
    assert 1000 < out.stat().st_size < 5_000_000
    probe = subprocess.run([exe, "-hide_banner", "-i", str(out)], capture_output=True, text=True)
    assert "Video: h264" in probe.stderr and "Duration: 00:00:04" in probe.stderr


class Resp:
    def __init__(self, status=200, payload=None):
        self.status_code, self._p = status, payload

    def json(self):
        if self._p is None:
            raise ValueError("no json")
        return self._p


class Http:
    def __init__(self, resp=None, error=None):
        self.resp, self.error, self.calls = resp, error, []

    def post(self, url, **kw):
        self.calls.append((url, kw))
        if self.error:
            raise self.error
        return self.resp


TOKEN = "123456789:AAH" + "x" * 32


def test_poll_parses_requests_and_zone():
    http = Http(Resp(200, {"timezone": "Asia/Tashkent", "requests": [
        {"id": "r1", "table": "Стол 1", "moment": "2026-11-14T16:47:05.123+00:00"},
        {"id": "r2", "table": "Стол 2"},  # no moment: dropped
    ]}))
    reqs, tz = ClipsClient("https://x.supabase.co", TOKEN, http).poll(["Стол 1"])
    assert tz == "Asia/Tashkent"
    assert [(r.id, r.table) for r in reqs] == [("r1", "Стол 1")]
    assert reqs[0].moment.tzinfo is not None
    url, kw = http.calls[0]
    assert url == "https://x.supabase.co/functions/v1/vision-clips"
    assert kw["json"]["action"] == "clips_poll"


def test_poll_errors_become_clips_error():
    with pytest.raises(ClipsError):
        ClipsClient("https://x", TOKEN, Http(error=requests.ConnectionError())).poll([])
    with pytest.raises(ClipsError):
        ClipsClient("https://x", TOKEN, Http(Resp(500, {"error": "DB_ERROR"}))).poll([])


class FakeClient:
    def __init__(self, upload_ok=True, upload_error=None):
        self.failed, self.done_paths, self.upload_ok, self.upload_error = [], [], upload_ok, upload_error

    def poll(self, tables):
        return [], "Asia/Tashkent"

    def done(self, request_id, path):
        assert Path(path).exists()  # the file is still there while uploading
        self.done_paths.append(Path(path))
        if self.upload_error:
            raise self.upload_error
        return self.upload_ok

    def fail(self, request_id, reason):
        self.failed.append((request_id, reason))


def make_worker(tmp_path, client, cut):
    return ClipRequestWorker(client, {"Стол 1": LIVE}, tmp_path, threading.Event(), cut=cut)


def ok_cut(url, seconds, out):
    out.write_bytes(b"x" * 5000)
    return None


REQ = ClipRequest("11111111-2222-4333-8444-555555555555", "Стол 1", T)


def test_worker_cuts_around_the_moment_uploads_and_deletes_the_file(tmp_path):
    seen = {}

    def cut(url, seconds, out):
        seen.update(url=url, seconds=seconds)
        return ok_cut(url, seconds, out)

    client = FakeClient()
    assert make_worker(tmp_path, client, cut).handle(REQ, "Asia/Tashkent")
    assert seen["seconds"] == 30
    assert "starttime=2026_11_14_21_46_53&endtime=2026_11_14_21_47_23" in seen["url"]
    assert client.failed == []
    assert not client.done_paths[0].exists()


def test_worker_reports_a_failed_cut_and_leaves_no_file(tmp_path):
    client = FakeClient()
    w = make_worker(tmp_path, client, lambda url, s, out: "NO_RECORDING")
    assert not w.handle(REQ, "Asia/Tashkent")
    assert client.failed == [(REQ.id, "NO_RECORDING")]
    assert list(tmp_path.glob("clip_ask_*")) == []


@pytest.mark.parametrize("client", [
    FakeClient(upload_ok=False),
    FakeClient(upload_error=ClipsError("нет связи")),
])
def test_worker_reports_a_failed_upload_and_deletes_the_file(tmp_path, client):
    assert not make_worker(tmp_path, client, ok_cut).handle(REQ, "Asia/Tashkent")
    assert client.failed == [(REQ.id, "UPLOAD")]
    assert list(tmp_path.glob("clip_ask_*")) == []


def test_worker_fails_a_request_for_a_table_it_cannot_cut(tmp_path):
    client = FakeClient()
    w = make_worker(tmp_path, client, ok_cut)
    other = ClipRequest(REQ.id, "Стол 9", T)
    assert not w.handle(other, "Asia/Tashkent")
    assert client.failed == [(REQ.id, "NO_CAMERA")]


def test_a_lost_connection_does_not_stop_the_loop(tmp_path):
    class Down(FakeClient):
        def poll(self, tables):
            raise ClipsError("нет связи")

    w = make_worker(tmp_path, Down(), ok_cut)
    assert w.step() == 0 and w.step() == 0


def test_check_archive_reports_a_clip_that_works(tmp_path):
    def cut(url, seconds, out):
        assert "starttime=2026_11_14_21_37_00" in url  # ten minutes before 21:47
        out.write_bytes(b"x" * 20000)
        return None

    ok, text = check_archive(LIVE, "Asia/Tashkent", now=T.replace(minute=47, second=0), cut=cut)
    assert ok and "читается" in text


def test_check_archive_explains_a_camera_that_gives_nothing():
    ok, text = check_archive(LIVE, "Asia/Tashkent", cut=lambda *a: "NO_RECORDING")
    assert not ok and "карта памяти" in text


def test_check_archive_says_when_the_camera_is_not_dahua():
    ok, text = check_archive("rtsp://u:p@1.2.3.4/Streaming/Channels/101", "Asia/Tashkent")
    assert not ok and "Dahua" in text
