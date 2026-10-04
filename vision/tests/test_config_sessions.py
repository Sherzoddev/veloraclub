from pathlib import Path

import pytest
import requests

from velora_vision.config import ConfigError, load_config, load_env
from velora_vision.sessions import (
    ResourceState,
    SessionsClient,
    SessionsError,
    match_resource,
)

CONFIG = """
club_id: "bb34ee5d-1f9d-4ae5-8cd7-db9ecd6eacdc"
cameras:
  - name: cam1
    source_env: CAM1_URL
    tables:
      - resource: "1 Stol"
      - resource: "2 Stol"
rules:
  unrecorded_after_minutes: 3
"""
ENV = {
    "SUPABASE_URL": "https://x.supabase.co/",
    "VISION_SECRET": "s3cret",
    "TELEGRAM_BOT_TOKEN": "123:abc",
    "TELEGRAM_ALERT_CHAT_ID": "-100123, 456",
    "CAM1_URL": "rtsp://u:p@10.0.0.2/1",
}


def write(tmp_path: Path, config=CONFIG, zones=None) -> tuple[Path, Path]:
    c = tmp_path / "config.yaml"
    c.write_text(config, encoding="utf-8")
    z = tmp_path / "zones.yaml"
    if zones is not None:
        z.write_text(zones, encoding="utf-8")
    return c, z


def test_loads_cameras_zones_and_rules(tmp_path):
    zones = "cam1:\n  1 Stol: [[0.1, 0.1], [0.9, 0.1], [0.5, 0.9]]\n"
    c, z = write(tmp_path, zones=zones)
    cfg = load_config(c, z, ENV)
    assert cfg.supabase_url == "https://x.supabase.co"
    assert cfg.alert_chats == ["-100123", "456"]
    assert cfg.rules.unrecorded_after == 180
    cam = cfg.cameras[0]
    assert cam.source == "rtsp://u:p@10.0.0.2/1" and not cam.is_file
    assert cam.tables[0].polygon == [(0.1, 0.1), (0.9, 0.1), (0.5, 0.9)]
    assert cam.tables[1].polygon is None  # not drawn yet


def test_missing_env_names_the_variable(tmp_path):
    c, z = write(tmp_path)
    env = {k: v for k, v in ENV.items() if k != "VISION_SECRET"}
    with pytest.raises(ConfigError, match="VISION_SECRET"):
        load_config(c, z, env)


def test_missing_camera_address_names_the_variable(tmp_path):
    c, z = write(tmp_path)
    env = {k: v for k, v in ENV.items() if k != "CAM1_URL"}
    with pytest.raises(ConfigError, match="CAM1_URL"):
        load_config(c, z, env)


def test_dry_run_needs_no_telegram_and_no_server(tmp_path):
    c, z = write(tmp_path)
    cfg = load_config(c, z, {"CAM1_URL": "clip.mp4"},
                      need_supabase=False, need_telegram=False)
    assert cfg.cameras[0].is_file


def test_zone_with_two_points_is_rejected(tmp_path):
    c, z = write(tmp_path, zones="cam1:\n  1 Stol: [[0.1, 0.1], [0.9, 0.1]]\n")
    with pytest.raises(ConfigError, match="3"):
        load_config(c, z, ENV)


def test_load_env_does_not_override_existing(tmp_path):
    f = tmp_path / ".env"
    f.write_text('# c\nA=1\nB="two words"\nC = 3\n', encoding="utf-8")
    env = {"A": "keep"}
    load_env(f, env)
    assert env == {"A": "keep", "B": "two words", "C": "3"}


R = [
    ResourceState("11111111-1111-1111-1111-111111111111", "1 Stol", "", None, None),
    ResourceState("22222222-2222-2222-2222-222222222222", "VIP  2", "", "ACTIVE", "t"),
]


def test_match_by_name_ignores_case_and_spaces():
    assert match_resource("vip 2", R).session_status == "ACTIVE"
    assert match_resource(" 1 stol ", R).name == "1 Stol"
    assert match_resource("5 Stol", R) is None


def test_match_by_id():
    assert match_resource("22222222-2222-2222-2222-222222222222", R).name == "VIP  2"


class FakeResponse:
    def __init__(self, status=200, payload=None):
        self.status_code = status
        self._payload = payload

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


class FakeHttp:
    def __init__(self, response=None, error=None):
        self.response, self.error, self.calls = response, error, []

    def post(self, url, **kw):
        self.calls.append((url, kw))
        if self.error:
            raise self.error
        return self.response


def test_fetch_sends_secret_and_parses():
    payload = {"resources": [{"id": "a", "name": "1 Stol", "zone": None,
                              "session_status": "ACTIVE", "session_started_at": "t"}]}
    http = FakeHttp(FakeResponse(200, payload))
    client = SessionsClient("https://x.supabase.co/", "s3cret", "club", http=http)
    res = client.fetch()
    url, kw = http.calls[0]
    assert url == "https://x.supabase.co/functions/v1/vision-sessions"
    assert kw["headers"] == {"x-vision-secret": "s3cret"}
    assert kw["json"] == {"club_id": "club"}
    assert res[0].session_status == "ACTIVE"


@pytest.mark.parametrize("status,text", [(401, "VISION_SECRET"), (503, "VISION_SECRET"), (500, "500")])
def test_fetch_errors_are_readable(status, text):
    client = SessionsClient("https://x", "s", "c", http=FakeHttp(FakeResponse(status)))
    with pytest.raises(SessionsError, match=text):
        client.fetch()


def test_fetch_network_error():
    client = SessionsClient("https://x", "s", "c",
                            http=FakeHttp(error=requests.ConnectionError("down")))
    with pytest.raises(SessionsError, match="нет связи"):
        client.fetch()
