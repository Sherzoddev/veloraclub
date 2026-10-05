import subprocess
import threading
from pathlib import Path

import cv2
import numpy as np
import pytest

from velora_vision.clips import encoder
from velora_vision.clips.recorder import ClipRecorder
from velora_vision.clips.sender import MAX_ATTEMPTS, ClipJob, ClipSender
from velora_vision.config import CameraCfg, TableCfg

W, H = 640, 360
FELT = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]


def jpeg(color=(40, 110, 40), n=1):
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = color
    ok, buf = cv2.imencode(".jpg", img)
    return [buf.tobytes()] * n


def scene(positions):
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (40, 110, 40)
    for x, y in positions:
        cv2.circle(img, (int(x), int(y)), 8, (235, 235, 235), -1)
    return img


# ---- encoder ---------------------------------------------------------------
@pytest.mark.skipif(encoder.ffmpeg_exe() is None, reason="no ffmpeg")
def test_encoder_makes_a_playable_h264_mp4(tmp_path):
    out = tmp_path / "c.mp4"
    assert encoder.encode_mp4(jpeg(n=30), 15, out)
    # It must be readable again, with the frames and the size we put in.
    cap = cv2.VideoCapture(str(out))
    try:
        assert cap.isOpened()
        assert (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))) == (W, H)
        frames = 0
        while cap.read()[0]:
            frames += 1
    finally:
        cap.release()
    assert 28 <= frames <= 32
    # And it is H.264, which is what Telegram plays inline.
    info = subprocess.run([encoder.ffmpeg_exe(), "-hide_banner", "-i", str(out)],
                          capture_output=True, text=True, errors="replace").stderr
    assert "h264" in info.lower() and "yuv420p" in info and "yuvj" not in info, info


@pytest.mark.skipif(encoder.ffmpeg_exe() is None, reason="no ffmpeg")
def test_encoder_keeps_the_colours(tmp_path):
    # A full-range/limited-range mix-up washes the colours out.
    colour = (40, 150, 60)
    out = tmp_path / "c.mp4"
    assert encoder.encode_mp4(jpeg(color=colour, n=15), 15, out)
    cap = cv2.VideoCapture(str(out))
    try:
        ok, frame = cap.read()
    finally:
        cap.release()
    assert ok
    mean = frame.reshape(-1, 3).mean(axis=0)
    assert all(abs(mean[i] - colour[i]) < 10 for i in range(3)), mean


def test_encoder_refuses_nothing_to_encode(tmp_path):
    assert not encoder.encode_mp4([], 15, tmp_path / "x.mp4")


# ---- sender: the file must never stay on the disk --------------------------
class FakeTelegram:
    def __init__(self, results=(True,)):
        self.results = list(results)
        self.calls = []
        self.existed_during_send = None

    def send_video(self, path, caption, width, height, duration):
        self.calls.append((Path(path).name, caption, width, height, duration))
        self.existed_during_send = Path(path).exists()
        return self.results.pop(0) if len(self.results) > 1 else self.results[0]


def fake_encode(frames, fps, out):
    out.write_bytes(b"mp4" * 100)
    return True


def test_clip_is_sent_and_deleted(tmp_path):
    tg = FakeTelegram()
    sender = ClipSender(tg, tmp_path / "tmp", threading.Event(), encode=fake_encode)
    assert sender.process(ClipJob(jpeg(n=30), 15, "🎱 1 Stol"))
    assert tg.existed_during_send is True
    assert tg.calls[0][2:] == (W, H, 2)
    assert list((tmp_path / "tmp").glob("*")) == []  # nothing left
    assert sender.sent == 1


def test_file_is_deleted_even_when_sending_fails(tmp_path):
    tg = FakeTelegram(results=[False])
    sender = ClipSender(tg, tmp_path / "tmp", threading.Event(), encode=fake_encode)
    assert not sender.process(ClipJob(jpeg(n=30), 15, "x"))
    assert list((tmp_path / "tmp").glob("*")) == []


def test_file_is_deleted_when_the_upload_crashes(tmp_path):
    class Boom(FakeTelegram):
        def send_video(self, *a, **k):
            raise RuntimeError("network died")

    sender = ClipSender(Boom(), tmp_path / "tmp", threading.Event(), encode=fake_encode)
    with pytest.raises(RuntimeError):
        sender.process(ClipJob(jpeg(n=30), 15, "x"))
    assert list((tmp_path / "tmp").glob("*")) == []


def test_failed_clip_is_retried_then_dropped(tmp_path):
    t = {"now": 1000.0}
    tg = FakeTelegram(results=[False])
    sender = ClipSender(tg, tmp_path / "tmp", threading.Event(), encode=fake_encode,
                        clock=lambda: t["now"])
    job = ClipJob(jpeg(n=30), 15, "x")
    for _ in range(MAX_ATTEMPTS):
        sender.process(job)
    assert sender.dropped == 1
    assert sender.pending() == MAX_ATTEMPTS - 1  # the retries queued before the last one


def test_leftover_files_of_a_crash_are_removed_at_start(tmp_path):
    tmp = tmp_path / "tmp"
    tmp.mkdir()
    (tmp / "clip_1_1.mp4").write_bytes(b"x")
    (tmp / "other.txt").write_bytes(b"keep")
    ClipSender(FakeTelegram(), tmp, threading.Event(), encode=fake_encode)
    assert not (tmp / "clip_1_1.mp4").exists()
    assert (tmp / "other.txt").exists()


def test_a_full_queue_drops_new_clips(tmp_path):
    sender = ClipSender(FakeTelegram(), tmp_path / "tmp", threading.Event(), encode=fake_encode)
    accepted = [sender.submit(ClipJob(jpeg(), 15, "x")) for _ in range(10)]
    assert accepted.count(True) == 6 and sender.dropped == 4


# ---- recorder: balls move on a synthetic table -> one clip ------------------
class FakeSender:
    def __init__(self):
        self.jobs = []

    def submit(self, job):
        self.jobs.append(job)
        return True


def camera(felt=FELT):
    return CameraCfg("cam", "x.mp4", [TableCfg("1 Stol", None, felt)])


def play(rec, seconds_of_play, fps=15, seconds_after=6, balls=3, seconds_before=5):
    """A still table, then balls move for a while, then everything is still."""
    now = 1000.0
    pos = [(150.0 + 120 * i, 130.0 + 40 * i) for i in range(balls)]
    for i in range(int(seconds_before * fps)):
        rec.step(scene(pos), now)
        now += 1.0 / fps
    for i in range(int(seconds_of_play * fps)):
        pos = [(x + 5 * (1 if j % 2 == 0 else -1), y + 2) for j, (x, y) in enumerate(pos)]
        rec.step(scene(pos), now)
        now += 1.0 / fps
    for i in range(int(seconds_after * fps)):
        rec.step(scene(pos), now)
        now += 1.0 / fps
    return now


def make_recorder(sender, **kw):
    return ClipRecorder(camera(), reader=None, sender=sender, stop=threading.Event(),
                        mode=kw.pop("mode", "learn"), **kw)


def test_one_shot_makes_one_clip_with_a_lead_in():
    sender = FakeSender()
    rec = make_recorder(sender)
    play(rec, 3.0)
    assert len(sender.jobs) == 1
    job = sender.jobs[0]
    assert "1 Stol" in job.caption and "шаров в движении" in job.caption
    # 4 s before + the shot itself (3 s) + 3 s after
    assert 15 * 9 < len(job.frames) < 15 * 12
    assert rec.shots_seen == 1


def test_nobody_at_the_table_means_no_clip():
    sender = FakeSender()
    rec = make_recorder(sender, table_busy=lambda name: False)
    play(rec, 3.0)
    assert sender.jobs == []


def test_bright_mode_skips_a_dull_shot():
    sender = FakeSender()
    rec = make_recorder(sender, mode="rare")  # needs a score of 8
    play(rec, 1.0, balls=2)
    assert sender.jobs == []


def test_cooldown_between_clips_of_one_table():
    sender = FakeSender()
    rec = make_recorder(sender)
    end = play(rec, 2.0)
    pos = [(150.0, 130.0), (270.0, 170.0), (390.0, 210.0)]
    now = end
    for i in range(30):  # a second shot only 10 s later
        pos = [(x + 5, y + 2) for x, y in pos]
        rec.step(scene(pos), now)
        now += 1 / 15
    for i in range(90):
        rec.step(scene(pos), now)
        now += 1 / 15
    assert len(sender.jobs) == 1  # cooldown is 90 s in "learn" mode


def test_table_without_cloth_zone_is_not_watched():
    sender = FakeSender()
    rec = ClipRecorder(camera(felt=None), None, sender, threading.Event())
    assert rec.watches == []
