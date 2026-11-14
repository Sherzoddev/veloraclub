import re
import subprocess
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from velora_vision.clips.archive import check_live, ffmpeg_exe
from velora_vision.clips.client_clips import ClipRequest, ClipRequestWorker
from velora_vision.clips.local_record import (CameraRecorder, LocalRecording, clean_old, concat_list,
                                              cut_local, folder_size, list_segments, local_naive,
                                              record_url, safe_name, segment_command, segments_for)

TASHKENT = ZoneInfo("Asia/Tashkent")
LIVE = "rtsp://admin:p%3D@192.168.1.42:554/cam/realmonitor?channel=1&subtype=0"


def test_record_url_takes_the_light_stream_by_default_and_keeps_the_rest():
    light = record_url(LIVE)
    assert "subtype=1" in light and "subtype=0" not in light and "channel=1" in light
    assert light.startswith("rtsp://admin:p%3D@192.168.1.42:554/cam/realmonitor?")
    assert "subtype=0" in record_url(LIVE.replace("subtype=0", "subtype=1"), "main")
    assert record_url("rtsp://u:p@1.2.3.4/Streaming/Channels/101") == "rtsp://u:p@1.2.3.4/Streaming/Channels/101"
    assert record_url("C:/videos/m.mp4") == "C:/videos/m.mp4"


def test_segment_command_copies_without_reencoding_into_named_pieces(tmp_path):
    cmd = segment_command("ffmpeg", record_url(LIVE), tmp_path)
    assert cmd[cmd.index("-c") + 1] == "copy" and "-an" in cmd
    assert cmd[cmd.index("-rtsp_transport") + 1] == "tcp"
    assert cmd[cmd.index("-segment_time") + 1] == "60"
    assert cmd[cmd.index("-strftime") + 1] == "1"
    assert cmd[-1].endswith("%Y%m%d_%H%M%S.ts")
    assert "-rtsp_transport" not in segment_command("ffmpeg", "file.mp4", tmp_path)


def make_pieces(folder: Path, names, seconds=60):
    """Tiny real MPEG-TS pieces (each `seconds` long) with the given start names."""
    exe = ffmpeg_exe()
    folder.mkdir(parents=True, exist_ok=True)
    first = folder / f"{names[0]}.ts"
    subprocess.run([exe, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "testsrc=size=160x90:rate=5", "-t", str(seconds), "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-g", "5", "-f", "mpegts", str(first)], check=True)
    for n in names[1:]:
        (folder / f"{n}.ts").write_bytes(first.read_bytes())


def test_pieces_are_listed_by_their_start_and_chosen_by_the_time_asked(tmp_path):
    for n in ("20261114_213900", "20261114_214000", "20261114_214100", "20261114_214200"):
        (tmp_path / f"{n}.ts").write_bytes(b"x")
    (tmp_path / "notes.txt").write_text("not a piece")
    assert [s.strftime("%H%M%S") for s, _ in list_segments(tmp_path)] == ["213900", "214000", "214100", "214200"]
    pick = segments_for(tmp_path, datetime(2026, 11, 14, 21, 40, 40), datetime(2026, 11, 14, 21, 41, 10))
    assert [s.strftime("%H%M%S") for s, _ in pick] == ["214000", "214100"]
    assert segments_for(tmp_path, datetime(2026, 11, 14, 22, 0, 0), datetime(2026, 11, 14, 22, 1, 0)) == []


def test_old_pieces_are_deleted_and_new_ones_stay(tmp_path):
    now = datetime(2026, 11, 14, 22, 0, 0)
    for n in ("20261113_090000", "20261114_090000", "20261114_215900"):
        (tmp_path / f"{n}.ts").write_bytes(b"x" * 10)
    assert clean_old(tmp_path, 24, now) == 1  # only the one of yesterday morning
    assert sorted(f.name for f in tmp_path.glob("*.ts")) == ["20261114_090000.ts", "20261114_215900.ts"]
    assert folder_size(tmp_path) == 20


def test_a_moment_is_turned_into_the_computers_own_clock():
    moment = datetime(2026, 11, 14, 16, 47, 5, tzinfo=timezone.utc)
    assert local_naive(moment, TASHKENT) == datetime(2026, 11, 14, 21, 47, 5)


def test_the_concat_list_quotes_odd_names():
    assert concat_list([Path("/a/b.ts")]) == "file '/a/b.ts'\n"
    assert "'\\''" in concat_list([Path("/a/it's.ts")])


@pytest.mark.skipif(not ffmpeg_exe(), reason="ffmpeg is not available")
def test_a_clip_is_cut_out_of_one_piece(tmp_path):
    make_pieces(tmp_path / "t", ["20261114_214000", "20261114_214100", "20261114_214200"])
    moment = datetime(2026, 11, 14, 21, 41, 30, tzinfo=TASHKENT).astimezone(timezone.utc)
    out = tmp_path / "clip.mp4"
    assert cut_local(tmp_path / "t", moment, 12, 18, out, tz=TASHKENT) is None
    assert out.stat().st_size > 1000
    assert duration(out) == pytest.approx(30, abs=1.5)


@pytest.mark.skipif(not ffmpeg_exe(), reason="ffmpeg is not available")
def test_a_clip_across_the_border_of_two_pieces(tmp_path):
    make_pieces(tmp_path / "t", ["20261114_214000", "20261114_214100", "20261114_214200"])
    moment = datetime(2026, 11, 14, 21, 41, 5, tzinfo=TASHKENT).astimezone(timezone.utc)
    out = tmp_path / "clip.mp4"
    assert cut_local(tmp_path / "t", moment, 12, 18, out, tz=TASHKENT) is None  # 21:40:53 - 21:41:23
    assert duration(out) == pytest.approx(30, abs=1.5)


@pytest.mark.skipif(not ffmpeg_exe(), reason="ffmpeg is not available")
def test_nothing_recorded_for_that_time_is_said_so(tmp_path):
    make_pieces(tmp_path / "t", ["20261114_214000"])
    moment = datetime(2026, 11, 13, 21, 41, 30, tzinfo=TASHKENT).astimezone(timezone.utc)
    assert cut_local(tmp_path / "t", moment, 12, 18, tmp_path / "c.mp4", tz=TASHKENT) == "NO_LOCAL"
    assert cut_local(tmp_path / "nothing", moment, 12, 18, tmp_path / "c.mp4", tz=TASHKENT) == "NO_LOCAL"


def duration(path):
    text = subprocess.run([ffmpeg_exe(), "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    m = re.search(r"Duration: (\d+):(\d+):(\d+\.\d+)", text)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


# -- the recorder process --------------------------------------------------
class FakeProc:
    def __init__(self, polls_until_exit=1, stderr=b""):
        self._left = polls_until_exit
        self.stdin = type("S", (), {"write": lambda self, b: None, "flush": lambda self: None})()
        self.stderr = type("E", (), {"read": lambda self: stderr})()
        self.terminated = False

    def poll(self):
        self._left -= 1
        return 1 if self._left < 0 else None

    def wait(self, timeout=None):
        return 0

    def terminate(self):
        self.terminated = True


def test_the_recorder_starts_ffmpeg_and_starts_it_again_when_it_stops(tmp_path):
    stop = threading.Event()
    started = []

    def popen(cmd, **kw):
        started.append(cmd)
        if len(started) >= 3:
            stop.set()
        return FakeProc(polls_until_exit=0)

    rec = CameraRecorder("Стол 1", "rtsp://a/b", tmp_path / "f", stop, popen=popen, exe="ffmpeg", restart_after=0.01)
    rec.start()
    rec.join(5)
    assert len(started) >= 3 and (tmp_path / "f").is_dir()
    assert started[0][0] == "ffmpeg" and started[0][started[0].index("-i") + 1] == "rtsp://a/b"


def test_the_recorder_never_logs_a_password(tmp_path, caplog):
    stop = threading.Event()
    secret = "p%3Dword"

    def popen(cmd, **kw):
        return FakeProc(polls_until_exit=0, stderr=f"Error opening rtsp://admin:{secret}@192.168.1.42/x Forbidden".encode())

    calls = []

    def popen_once(cmd, **kw):
        calls.append(1)
        if len(calls) == 2:
            stop.set()
        return popen(cmd, **kw)

    rec = CameraRecorder("Стол 1", f"rtsp://admin:{secret}@192.168.1.42/x", tmp_path, stop,
                         popen=popen_once, exe="ffmpeg", restart_after=0.01)
    rec.start()
    rec.join(5)
    assert "p%3D" not in caplog.text and "word" not in caplog.text


def test_local_recording_gives_every_table_its_own_folder_and_cuts_from_it(tmp_path):
    made = []

    class Rec:
        def __init__(self, table, url, folder, stop):
            made.append((table, url, folder))

        def start(self):
            pass

    stop = threading.Event()
    lr = LocalRecording({"Стол 1": LIVE, "Стол №2": LIVE.replace("42", "43")}, tmp_path, stop,
                        keep_hours=12, quality="light", recorder_factory=Rec, clean_every=0.01)
    assert [m[0] for m in made] == ["Стол 1", "Стол №2"]
    assert all("subtype=1" in m[1] for m in made)
    assert made[1][2] == tmp_path / safe_name("Стол №2")
    assert lr.cut("Стол 9", datetime.now(timezone.utc), 12, 18, tmp_path / "x.mp4") == "NO_LOCAL"
    stop.set()


# -- the worker prefers the own recording, falls back to the camera's archive
class FakeClient:
    def __init__(self):
        self.failed, self.uploads = [], 0

    def done(self, request_id, path):
        assert Path(path).exists()
        self.uploads += 1
        return True

    def fail(self, request_id, reason):
        self.failed.append((request_id, reason))


class FakeLocal:
    def __init__(self, result):
        self.result, self.asked = result, []

    def cut(self, table, moment, before, after, out):
        self.asked.append((table, before, after))
        if self.result is None:
            out.write_bytes(b"x" * 5000)
        return self.result


REQ = ClipRequest("11111111-2222-4333-8444-555555555555", "Стол 1",
                  datetime(2026, 11, 14, 16, 47, 5, tzinfo=timezone.utc))


def worker(tmp_path, local, cut):
    return ClipRequestWorker(FakeClient(), {"Стол 1": LIVE}, tmp_path, threading.Event(), cut=cut,
                             shift_of=lambda *a: timedelta(0), local=local)


def test_the_own_recording_is_used_first_and_the_camera_is_not_asked(tmp_path):
    asked = []
    w = worker(tmp_path, FakeLocal(None), lambda *a: asked.append(a) or "FORBIDDEN")
    assert w.handle(REQ, "Asia/Tashkent") and asked == [] and w.client.uploads == 1


def test_when_nothing_was_recorded_the_camera_archive_is_tried(tmp_path):
    def cut(url, seconds, out):
        out.write_bytes(b"x" * 5000)
        return None

    w = worker(tmp_path, FakeLocal("NO_LOCAL"), cut)
    assert w.handle(REQ, "Asia/Tashkent") and w.client.uploads == 1


def test_nothing_anywhere_says_there_is_no_recording(tmp_path):
    w = worker(tmp_path, FakeLocal("NO_LOCAL"), lambda *a: "FORBIDDEN")
    assert not w.handle(REQ, "Asia/Tashkent")
    assert w.client.failed == [(REQ.id, "NO_LOCAL")]


@pytest.mark.skipif(not ffmpeg_exe(), reason="ffmpeg is not available")
def test_check_live_reads_a_stream_and_says_when_it_cannot(tmp_path):
    exe = ffmpeg_exe()
    src = tmp_path / "live.mp4"
    subprocess.run([exe, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "testsrc=size=320x180:rate=10", "-t", "5", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    str(src)], check=True)
    assert check_live(str(src)) == (True, "живой поток читается")
    ok, text = check_live(str(tmp_path / "missing.mp4"))
    assert not ok
