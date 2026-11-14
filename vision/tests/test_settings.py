import json

from velora_vision import settings as st
from velora_vision.settings import CameraSettings, Settings

TOKEN = "123456789:AAH" + "x" * 32


def sample() -> Settings:
    s = Settings(bot_token=TOKEN)
    s.cameras = [CameraSettings("c1", "Зал", "rtsp://admin:p%40ss@10.0.0.2:554/cam/realmonitor?channel=1", "Стол 1"),
                 CameraSettings("c2", "VIP", "rtsp://10.0.0.3/s")]
    return s


def test_roundtrip(tmp_path):
    st.save(tmp_path, sample())
    back = st.load(tmp_path)
    assert back.bot_token == TOKEN
    assert [(c.url, c.table) for c in back.cameras] == [(c.url, c.table) for c in sample().cameras]


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


def test_settings_of_the_old_version_still_open(tmp_path):
    """Zones, alerts and channels of version 1-2 are ignored; the token and the
    cameras are kept (their table has to be chosen once)."""
    old = {
        "version": 2,
        "bot_token": st.secrets_store.protect(TOKEN),
        "extra_chat_ids": "-1001",
        "clips_chat_id": "-1002",
        "zones": {"c1": {"1 Stol": [[0.1, 0.1], [0.9, 0.1], [0.5, 0.9]]}},
        "cameras": [{"id": "c1", "name": "Зал", "url": st.secrets_store.protect("rtsp://10.0.0.2/s"),
                     "anchor": "foot", "rotate": 90, "widen": True}],
        "autostart": True,
    }
    (tmp_path / st.FILE_NAME).write_text(json.dumps(old), encoding="utf-8")
    s = st.load(tmp_path)
    assert s.bot_token == TOKEN and s.autostart is True
    assert [(c.name, c.url, c.table) for c in s.cameras] == [("Зал", "rtsp://10.0.0.2/s", "")]


def test_problems_tell_what_is_missing():
    assert "токен" in Settings().problems()[0].lower()
    assert "камеры" in Settings(bot_token=TOKEN).problems()[0].lower()
    no_table = Settings(bot_token=TOKEN, cameras=[CameraSettings("c", "A", "rtsp://x/y")])
    assert "стол" in no_table.problems()[0].lower()
    assert sample().problems() == []
