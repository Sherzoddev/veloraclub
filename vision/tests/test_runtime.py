"""The whole thing without a window: the controller watches a video file with
a billiard scene, a person standing at the table and balls that move once."""
import os
import time

import cv2
import numpy as np
import pytest

from velora_vision import telegram as tgmod
from velora_vision.clips import encoder
from velora_vision.detector import Box
from velora_vision.runtime import FAILED, RUNNING, STOPPED, Controller
from velora_vision.sessions import ClubSnapshot, ResourceState, SessionsClient, SessionsError
from velora_vision.settings import CameraSettings, Settings

TOKEN = "123456789:AAH" + "x" * 32
W, H, FPS = 640, 360, 15
FELT = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]
PEOPLE = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]]


def make_video(path):
    """4 s still table, 3 s of three balls moving, 6 s still."""
    out = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), FPS, (W, H))
    pos = [(150.0 + 120 * i, 130.0 + 40 * i) for i in range(3)]

    def frame():
        img = np.zeros((H, W, 3), np.uint8)
        img[:] = (40, 110, 40)
        for x, y in pos:
            cv2.circle(img, (int(x), int(y)), 8, (235, 235, 235), -1)
        return img

    for _ in range(4 * FPS):
        out.write(frame())
    for _ in range(3 * FPS):
        pos[:] = [(x + 5 * (1 if j % 2 == 0 else -1), y + 2) for j, (x, y) in enumerate(pos)]
        out.write(frame())
    for _ in range(6 * FPS):
        out.write(frame())
    out.release()


class FakeDetector:
    """One person standing at the table all the time."""

    def detect(self, frame):
        return [Box(100, 50, 160, 340, 0.9)]


@pytest.fixture
def env(tmp_path, monkeypatch):
    video = tmp_path / "table.mp4"
    make_video(video)
    sent = []

    def fake_post(self, method, data, files=None, timeout=None):
        entry = {"method": method, "chat": data.get("chat_id"), "text": data.get("text") or data.get("caption")}
        if files and "video" in files:
            f = files["video"][1]
            entry["video_exists"] = os.path.exists(f.name)
            entry["video_bytes"] = os.path.getsize(f.name)
        sent.append(entry)
        return True

    monkeypatch.setattr(tgmod.Telegram, "_post", fake_post)
    snap = ClubSnapshot("Тест", "Asia/Tashkent", 555, [ResourceState("a", "1 Stol", "", None, None)])
    monkeypatch.setattr(SessionsClient, "fetch", lambda self: snap)

    s = Settings(bot_token=TOKEN)
    s.cameras = [CameraSettings("c1", "Зал", str(video), "foot")]
    s.zones = {"c1": {"1 Stol": PEOPLE}}
    s.felt_zones = {"c1": {"1 Stol": FELT}}
    s.clips_chat_id = "-100777"
    s.unrecorded_minutes = 0.05  # 3 s
    s.min_people_play = 1
    ctrl = Controller(lambda: s, tmp_path / "snaps", detector_factory=lambda acc: FakeDetector(),
                      tmp_dir=tmp_path / "tmp")
    return ctrl, s, sent, tmp_path


def wait(cond, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.2)
    return False


@pytest.mark.skipif(encoder.ffmpeg_exe() is None, reason="no ffmpeg")
def test_alert_and_clip_both_go_out_and_the_clip_leaves_no_trace(env):
    ctrl, s, sent, tmp_path = env
    ctrl.start()
    assert wait(lambda: ctrl.state == RUNNING, 10), ctrl.message
    assert wait(lambda: any(e["method"] == "sendVideo" for e in sent), 30), sent
    ctrl.stop()

    chats = {e["chat"] for e in sent}
    assert "555" in chats and "-100777" in chats

    alert = [e for e in sent if e["method"] in ("sendMessage", "sendPhoto") and e["chat"] == "555"]
    assert any("сеанс не запущен" in (e["text"] or "") for e in alert)

    clip = [e for e in sent if e["method"] == "sendVideo"][0]
    assert clip["chat"] == "-100777"          # the channel, not the owner
    assert clip["video_exists"] and clip["video_bytes"] > 1000
    assert "1 Stol" in clip["text"] and "удар" in clip["text"]
    assert list((tmp_path / "tmp").glob("*")) == []   # deleted right after sending


def test_without_a_channel_clips_are_off_but_alerts_still_work(env):
    ctrl, s, sent, tmp_path = env
    s.clips_chat_id = ""
    ctrl.start()
    assert wait(lambda: any("сеанс не запущен" in (e["text"] or "") for e in sent), 20), sent
    ctrl.stop()
    assert not any(e["method"] == "sendVideo" for e in sent)


def test_clips_can_be_switched_off(env):
    ctrl, s, sent, tmp_path = env
    s.clips_enabled = False
    ctrl.start()
    assert wait(lambda: ctrl.state == RUNNING, 10)
    time.sleep(1)
    ctrl.stop()
    assert ctrl.recorders == [] and ctrl.sender is None


def test_bad_token_stops_with_a_readable_reason(env, monkeypatch):
    ctrl, s, sent, tmp_path = env

    def boom(self):
        raise SessionsError("Такого бота нет в программе Velora Club. Проверьте токен.")

    monkeypatch.setattr(SessionsClient, "fetch", boom)
    ctrl.start()
    assert wait(lambda: ctrl.state == FAILED, 10)
    assert "Проверьте токен" in ctrl.message
    ctrl.stop()
    assert ctrl.state == STOPPED


def test_not_ready_settings_say_what_is_missing(env):
    ctrl, s, sent, tmp_path = env
    s.cameras = []
    ctrl.start()
    assert wait(lambda: ctrl.state == FAILED, 10)
    assert "камеры" in ctrl.message or "камер" in ctrl.message
    ctrl.stop()


def test_channel_test_message(env):
    ctrl, s, sent, tmp_path = env
    assert "отправлено" in ctrl.send_channel_test(s)
    assert sent[-1]["chat"] == "-100777"
    s.clips_chat_id = ""
    assert "Впишите канал" in ctrl.send_channel_test(s)


@pytest.mark.skipif(encoder.ffmpeg_exe() is None, reason="no ffmpeg")
def test_test_clip_goes_to_the_channel_and_is_deleted(env):
    ctrl, s, sent, tmp_path = env
    result = ctrl.send_test_clip(s, s.cameras[0].url, seconds=3)
    assert "отправлен" in result
    clip = [e for e in sent if e["method"] == "sendVideo"][0]
    assert clip["video_exists"] and clip["chat"] == "-100777"
    assert list((tmp_path / "tmp").glob("*")) == []
