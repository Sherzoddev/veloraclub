import json

from velora_vision import settings as st
from velora_vision.settings import CameraSettings, Settings

TOKEN = "123456789:AAH" + "x" * 32


def sample() -> Settings:
    s = Settings(bot_token=TOKEN, extra_chat_ids="-1001, 55;66")
    s.cameras = [CameraSettings("c1", "Зал", "rtsp://admin:p%40ss@10.0.0.2:554/s", "foot"),
                 CameraSettings("c2", "VIP", "rtsp://10.0.0.3/s", "center")]
    s.zones = {"c1": {"1 Stol": [[0.1, 0.1], [0.9, 0.1], [0.5, 0.9]]}}
    s.felt_zones = {"c1": {"1 Stol": [[0.2, 0.2], [0.8, 0.2], [0.5, 0.8]]}}
    s.clips_chat_id = "-1002"
    s.unrecorded_minutes = 7
    return s


def test_roundtrip(tmp_path):
    st.save(tmp_path, sample())
    back = st.load(tmp_path)
    assert back.bot_token == TOKEN
    assert [c.url for c in back.cameras] == [c.url for c in sample().cameras]
    assert back.cameras[1].anchor == "center"
    assert back.zones == sample().zones and back.felt_zones == sample().felt_zones
    assert back.clips_chat_id == "-1002" and back.unrecorded_minutes == 7


def test_secrets_are_not_readable_in_the_file(tmp_path):
    st.save(tmp_path, sample())
    text = (tmp_path / st.FILE_NAME).read_text(encoding="utf-8")
    assert TOKEN not in text
    assert "p%40ss" not in text
    json.loads(text)  # still valid JSON


def test_damaged_file_does_not_stop_the_program(tmp_path):
    (tmp_path / st.FILE_NAME).write_text("{ not json", encoding="utf-8")
    s = st.load(tmp_path)
    assert s.bot_token == "" and s.cameras == []
    assert (tmp_path / (st.FILE_NAME + ".bad")).exists()


def test_save_leaves_no_temp_file(tmp_path):
    st.save(tmp_path, sample())
    assert [p.name for p in tmp_path.iterdir()] == [st.FILE_NAME]


def test_extra_chats_split():
    assert sample().extra_chats() == ["-1001", "55", "66"]


def test_problems_in_plain_words():
    s = Settings()
    assert "токен" in s.problems()[0].lower()
    s.bot_token = TOKEN
    assert "камер" in s.problems()[0]
    s.cameras = [CameraSettings("c1", "Зал", "rtsp://x", "foot")]
    assert "зон" in s.problems()[0]
    s.zones = {"c1": {"1 Stol": [[0, 0], [1, 0], [1, 1]]}}
    assert s.problems() == []


def test_only_a_cloth_zone_is_enough_to_start():
    s = Settings(bot_token=TOKEN)
    s.cameras = [CameraSettings("c1", "Зал", "rtsp://x", "foot")]
    s.felt_zones = {"c1": {"1 Stol": [[0, 0], [1, 0], [1, 1]]}}
    assert s.problems() == []


def test_to_config_merges_people_and_cloth_zones(tmp_path):
    cfg = sample().to_config("Asia/Tashkent", tmp_path)
    assert [c.name for c in cfg.cameras] == ["Зал"]  # VIP has no zones: nothing to watch
    t = cfg.cameras[0].tables[0]
    assert t.resource == "1 Stol" and t.polygon and t.felt
    assert cfg.rules.unrecorded_after == 7 * 60


def test_cloth_only_table_is_kept(tmp_path):
    s = Settings(bot_token=TOKEN)
    s.cameras = [CameraSettings("c1", "Зал", "rtsp://x", "foot")]
    s.felt_zones = {"c1": {"2 Stol": [[0, 0], [1, 0], [1, 1]]}}
    cfg = s.to_config("Asia/Tashkent", tmp_path)
    t = cfg.cameras[0].tables[0]
    assert t.polygon is None and t.felt is not None


import sys

import pytest

from velora_vision import secrets_store


@pytest.mark.skipif(sys.platform != "win32", reason="Windows only")
def test_windows_really_encrypts_with_dpapi():
    # Not just the silent fallback: on Windows the secret must be DPAPI-protected.
    blob = secrets_store.protect(TOKEN)
    assert blob.startswith("dpapi:")
    assert TOKEN not in blob
    assert secrets_store.unprotect(blob) == TOKEN
    assert secrets_store.unprotect("dpapi:garbage") == ""


def test_unreadable_secret_becomes_empty_not_a_crash():
    assert secrets_store.unprotect("plain:%%%not base64") == ""
    assert secrets_store.unprotect("something:else") == ""
    assert secrets_store.unprotect("") == ""
