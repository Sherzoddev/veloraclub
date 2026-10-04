import logging
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np

from velora_vision.config import CameraCfg, Config, TableCfg
from velora_vision.detector import Box
from velora_vision.messages import camera_offline, format_event
from velora_vision.sessions import ClubSnapshot, ResourceState
from velora_vision.service import Service, count_people
from velora_vision.tracker import Event, Rules

MIN = 60.0
LEFT = [(0.0, 0.0), (0.5, 0.0), (0.5, 1.0), (0.0, 1.0)]
RIGHT = [(0.5, 0.0), (1.0, 0.0), (1.0, 1.0), (0.5, 1.0)]


def camera(anchor="foot"):
    return CameraCfg("cam1", "clip.mp4", [TableCfg("1 Stol", LEFT), TableCfg("2 Stol", RIGHT)], anchor)


def config(snap_dir, cam=None):
    return Config(
        timezone="Asia/Tashkent", poll_seconds=15,
        rules=Rules(min_people_play=1, unrecorded_after=5 * MIN, idle_after=15 * MIN,
                    gap=20, cooldown=30 * MIN, grace_after_session=10 * MIN),
        interval=1.0, offline_after=60,
        cameras=[cam or camera()], snapshot_dir=snap_dir,
    )


def test_count_people_per_zone_by_foot_point():
    # 100x100 picture; person A's feet are in the left zone, B's in the right.
    boxes = [Box(10, 10, 30, 40, .9), Box(60, 20, 80, 90, .9), Box(70, 30, 90, 95, .9)]
    assert count_people(boxes, camera(), 100, 100) == {"1 Stol": 1, "2 Stol": 2}


def test_count_people_center_anchor_differs_from_foot():
    # Zones stacked top/bottom. A tall box has its centre in the upper zone
    # and its feet in the lower one.
    upper = [(0, 0), (1, 0), (1, 0.5), (0, 0.5)]
    lower = [(0, 0.5), (1, 0.5), (1, 1), (0, 1)]
    tables = [TableCfg("Верх", upper), TableCfg("Низ", lower)]
    box = [Box(10, 0, 30, 80, .9)]  # centre y=40, feet y=80
    assert count_people(box, CameraCfg("c", "f.mp4", tables, "foot"), 100, 100) == {"Верх": 0, "Низ": 1}
    assert count_people(box, CameraCfg("c", "f.mp4", tables, "center"), 100, 100) == {"Верх": 1, "Низ": 0}


class FakeReader:
    def __init__(self, frame=None, age=0.0):
        self.frame, self.age, self.ended = frame, age, False

    def latest(self):
        return self.frame, self.age


class FakeDetector:
    def __init__(self):
        self.boxes = []

    def detect(self, frame):
        return self.boxes


class FakeSessions:
    def __init__(self, status=None):
        self.status = status

    def fetch(self):
        return ClubSnapshot("Клуб", "Asia/Tashkent", 1, [
            ResourceState("1", "1 Stol", "", self.status, None),
            ResourceState("2", "2 Stol", "", None, None)])


class Recorder:
    def __init__(self):
        self.sent = []

    def notify(self, text, jpeg=None):
        self.sent.append((text, jpeg))


def make_service(tmp_path, sessions, detector, reader):
    clock = {"t": 1_000_000.0}
    svc = Service(config(tmp_path), detector, {"cam1": reader}, Recorder(), sessions,
                  clock=lambda: clock["t"])
    return svc, clock


def test_end_to_end_unrecorded_play_sends_a_photo(tmp_path):
    frame = np.zeros((100, 100, 3), np.uint8)
    det = FakeDetector()
    det.boxes = [Box(10, 10, 30, 40, .9)]  # one person at table 1
    svc, clock = make_service(tmp_path, FakeSessions(None), det, FakeReader(frame))
    for _ in range(7 * 60):
        svc.tick()
        clock["t"] += 1
    sent = svc.notifier.sent
    assert len(sent) == 1
    text, jpeg = sent[0]
    assert "1 Stol" in text and "сеанс не запущен" in text
    assert jpeg[:2] == b"\xff\xd8"  # a JPEG
    assert list(tmp_path.glob("*_unrecorded_1_Stol.jpg"))  # kept on disk too


def test_running_session_sends_nothing(tmp_path):
    frame = np.zeros((100, 100, 3), np.uint8)
    det = FakeDetector()
    det.boxes = [Box(10, 10, 30, 40, .9)]
    svc, clock = make_service(tmp_path, FakeSessions("ACTIVE"), det, FakeReader(frame))
    for _ in range(20 * 60):
        svc.tick()
        clock["t"] += 1
    assert svc.notifier.sent == []


def test_unreachable_program_sends_nothing(tmp_path):
    from velora_vision.sessions import SessionsError

    class Down:
        def fetch(self):
            raise SessionsError("нет связи")

    frame = np.zeros((100, 100, 3), np.uint8)
    det = FakeDetector()
    det.boxes = [Box(10, 10, 30, 40, .9)]
    svc, clock = make_service(tmp_path, Down(), det, FakeReader(frame))
    for _ in range(10 * 60):
        svc.tick()
        clock["t"] += 1
    assert svc.notifier.sent == []


def test_unknown_table_name_is_reported_not_alerted(tmp_path, caplog):
    frame = np.zeros((100, 100, 3), np.uint8)
    det = FakeDetector()
    det.boxes = [Box(60, 20, 80, 90, .9)]  # table 2 exists in the program, 3rd doesn't
    cam = CameraCfg("cam1", "clip.mp4", [TableCfg("Нет такого", LEFT)], "foot")
    cfg = config(tmp_path, cam)
    svc = Service(cfg, det, {"cam1": FakeReader(frame)}, Recorder(), FakeSessions(None))
    with caplog.at_level(logging.WARNING):
        for _ in range(7 * 60):
            svc.tick()
            svc.clock = lambda t=svc.clock(): t + 1
    assert svc.notifier.sent == []
    assert "не найден" in caplog.text


def test_dead_camera_is_reported_once_then_recovery(tmp_path):
    reader = FakeReader(None)
    svc, clock = make_service(tmp_path, FakeSessions(None), FakeDetector(), reader)
    for _ in range(3 * 60):
        svc.tick()
        clock["t"] += 1
    assert len(svc.notifier.sent) == 1
    assert "не отвечает" in svc.notifier.sent[0][0]
    reader.frame, reader.age = np.zeros((10, 10, 3), np.uint8), 0.0
    svc.tick()
    assert "снова в сети" in svc.notifier.sent[-1][0]


def test_message_texts():
    at = datetime(2026, 10, 4, 14, 32, tzinfo=ZoneInfo("Asia/Tashkent"))
    assert format_event(Event("unrecorded", "1 Stol", 2, 7 * MIN), at) == (
        "⚠️ 1 Stol: у стола 2 чел. уже 7 мин., а сеанс не запущен (14:32)")
    assert "забыли остановить" in format_event(Event("idle", "2 Stol", 0, 16 * MIN), at)
    assert "Камера cam1" in camera_offline("cam1", 120, at)
