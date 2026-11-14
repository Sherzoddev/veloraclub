import threading
import time

import pytest

from velora_vision.runtime import FAILED, RUNNING, STOPPED, Controller
from velora_vision.sessions import ClubSnapshot, ResourceState, SessionsError
from velora_vision.settings import CameraSettings, Settings

TOKEN = "123456789:AAH" + "x" * 32
LIVE = "rtsp://admin:p@10.0.0.2:554/cam/realmonitor?channel=1&subtype=1"


class FakeWorker(threading.Thread):
    def __init__(self, client, sources, tmp_dir, stop):
        super().__init__(daemon=True)
        self.sources, self.stop_event = sources, stop
        self.sent = self.failed = 0

    def run(self):
        self.stop_event.wait(5)


def snapshot(*names):
    return ClubSnapshot("Клуб", "Asia/Tashkent", 1, [ResourceState(f"id{i}", n, "", None, None)
                                                     for i, n in enumerate(names)])


def make(settings, snap=None, error=None, monkeypatch=None):
    c = Controller(lambda: settings, None, worker_factory=FakeWorker)

    def fetch(_settings):
        if error:
            raise error
        c.club = snap
        return snap

    c.check_connection = fetch
    return c


def wait_for(c, states, seconds=3):
    end = time.time() + seconds
    while time.time() < end and c.state not in states:
        time.sleep(0.02)
    return c.state


def good():
    return Settings(bot_token=TOKEN, cameras=[CameraSettings("c1", "A", LIVE, "Стол 1")])


def test_starts_and_hands_the_tables_to_the_worker():
    c = make(good(), snapshot("Стол 1", "Стол 2"))
    c.start()
    assert wait_for(c, {RUNNING, FAILED}) == RUNNING
    assert c.worker.sources == {"Стол 1": LIVE}
    assert "Работает" in c.message
    c.stop()
    assert c.state == STOPPED and c.worker is None


def test_will_not_start_without_a_token():
    c = make(Settings(), snapshot("Стол 1"))
    c.start()
    assert wait_for(c, {RUNNING, FAILED}) == FAILED
    assert "токен" in c.message.lower()


def test_a_server_error_is_shown_not_swallowed():
    c = make(good(), error=SessionsError("Такого бота нет в программе Velora Club."))
    c.start()
    assert wait_for(c, {RUNNING, FAILED}) == FAILED
    assert "Такого бота" in c.message


def test_cameras_that_cannot_be_cut_are_reported():
    s = Settings(bot_token=TOKEN, cameras=[CameraSettings("c1", "A", "rtsp://u:p@1.2.3.4/Streaming/Channels/101", "Стол 1")])
    c = make(s, snapshot("Стол 1"))
    c.start()
    assert wait_for(c, {RUNNING, FAILED}) == FAILED
    assert "Dahua" in c.message


def test_check_camera_uses_the_clubs_time_zone(monkeypatch):
    c = make(good(), snapshot("Стол 1"))
    c.club = snapshot("Стол 1")
    seen = {}
    monkeypatch.setattr("velora_vision.runtime.check_archive",
                        lambda url, tz: seen.update(url=url, tz=tz) or (True, "ok"))
    assert c.check_camera(LIVE) == (True, "ok")
    assert seen["tz"] == "Asia/Tashkent"


def test_a_table_that_is_not_in_velora_club_stops_the_start_and_names_the_real_ones():
    s = Settings(bot_token=TOKEN, cameras=[CameraSettings("c1", "A", LIVE, "1")])
    c = make(s, snapshot("Стол №1", "Стол №2"))
    c.start()
    assert wait_for(c, {RUNNING, FAILED}) == FAILED
    assert "Стол №1, Стол №2" in c.message


def test_only_known_tables_go_to_the_worker():
    s = Settings(bot_token=TOKEN, cameras=[CameraSettings("c1", "A", LIVE, "Стол 1"),
                                           CameraSettings("c2", "B", LIVE.replace("2:554", "3:554"), "Стол 9")])
    c = make(s, snapshot("Стол 1"))
    c.start()
    assert wait_for(c, {RUNNING, FAILED}) == RUNNING
    assert list(c.worker.sources) == ["Стол 1"]
    c.stop()
