from pathlib import Path

import pytest
import requests

from velora_vision import camera_image as ci

LIVE = "rtsp://admin:Pa%40ss@192.168.1.42:554/cam/realmonitor?channel=2&subtype=0"


class Resp:
    def __init__(self, status, text):
        self.status_code, self.text = status, text


class FakeCamera:
    """A Dahua camera's configManager: getConfig / setConfig of VideoInOptions."""

    def __init__(self, options, takes=None, offline=False):
        self.options = dict(options)
        self.takes = takes  # which values the camera accepts (None: all)
        self.offline = offline
        self.urls = []

    def get(self, url, **kw):
        self.urls.append(url)
        if self.offline:
            raise requests.ConnectionError()
        if "action=getConfig&name=VideoInOptions" in url:
            return Resp(200, "".join(f"table.VideoInOptions[1].{k}={v}\r\n" for k, v in self.options.items()))
        if "action=setConfig" in url:
            for part in url.split("setConfig&")[1].split("&"):
                full, value = part.split("=", 1)
                key = full.split("].")[1]
                if "[1]" not in full:
                    return Resp(200, "Error\r\n")
                if self.takes is not None and value not in self.takes:
                    return Resp(200, "Error\r\n")
                self.options[key] = value
            return Resp(200, "OK\r\n")
        return Resp(404, "")


NUMERIC = {"Backlight": "0", "ExposureSpeed": "0", "GainMax": "50"}
WORDS = {"BacklightMode": "Off", "ExposureSpeed": "0"}


def test_the_channel_comes_from_the_stream_address():
    assert ci.channel_index(LIVE) == 1
    assert ci.channel_index("rtsp://u:p@1.2.3.4/cam/realmonitor") == 0


def test_options_are_read_and_shown_as_they_are():
    cam = FakeCamera(NUMERIC)
    opts = ci.read_options(LIVE, cam)
    assert opts == NUMERIC
    assert "Backlight = 0" in ci.format_options(opts)
    assert ci.mode_key(opts) == "Backlight"
    assert ci.read_options(LIVE, FakeCamera(NUMERIC, offline=True)) is None


def test_hlc_uses_the_cameras_own_spelling():
    assert ci.preset_value(NUMERIC, "hlc") == ("Backlight", "3")
    assert ci.preset_value(WORDS, "hlc") == ("BacklightMode", "Inhibition")
    assert ci.preset_value(WORDS, "wdr") == ("BacklightMode", "WideDynamic")
    assert ci.preset_value({"ExposureSpeed": "0"}, "hlc") is None


@pytest.mark.parametrize("options,key,value", [(NUMERIC, "Backlight", "3"), (WORDS, "BacklightMode", "Inhibition")])
def test_a_preset_is_applied_checked_and_remembered(tmp_path, options, key, value):
    cam = FakeCamera(options)
    ok, text = ci.apply_preset(LIVE, "hlc", tmp_path, cam)
    assert ok and "Готово" in text
    assert cam.options[key] == value
    assert any(f.name == "camera_192.168.1.42_ch1.json" for f in tmp_path.iterdir())


def test_restore_puts_back_the_original_even_after_two_changes(tmp_path):
    cam = FakeCamera(NUMERIC)
    ci.apply_preset(LIVE, "hlc", tmp_path, cam)
    ci.apply_preset(LIVE, "wdr", tmp_path, cam)
    assert cam.options["Backlight"] == "2"
    ok, text = ci.restore(LIVE, tmp_path, cam)
    assert ok and cam.options["Backlight"] == "0" and "возвращены" in text
    assert list(tmp_path.iterdir()) == []              # nothing left to restore
    assert not ci.restore(LIVE, tmp_path, cam)[0]


def test_a_value_the_camera_does_not_take_is_put_back(tmp_path):
    cam = FakeCamera(NUMERIC, takes={"0", "1", "2"})   # no HLC in this camera
    ok, text = ci.apply_preset(LIVE, "hlc", tmp_path, cam)
    assert not ok and "не приняла" in text
    assert cam.options["Backlight"] == "0"


def test_a_camera_without_the_key_or_without_answer_is_told_plainly(tmp_path):
    ok, text = ci.apply_preset(LIVE, "hlc", tmp_path, FakeCamera({"ExposureSpeed": "0"}))
    assert not ok and "нет такого параметра" in text
    ok, text = ci.apply_preset(LIVE, "hlc", tmp_path, FakeCamera(NUMERIC, offline=True))
    assert not ok and "не отдала" in text


def test_the_same_value_is_not_set_again(tmp_path):
    cam = FakeCamera({"Backlight": "3"})
    ok, text = ci.apply_preset(LIVE, "hlc", tmp_path, cam)
    assert ok and "Уже так" in text
    assert not any("setConfig" in u for u in cam.urls)


def test_the_dialog_reads_applies_and_restores(tmp_path, monkeypatch):
    import tkinter as tk
    import time
    from velora_vision.gui.camera_image import CameraImageDialog
    from velora_vision.gui.common import Background
    from velora_vision.settings import CameraSettings

    cam = FakeCamera(NUMERIC)
    monkeypatch.setattr(ci, "camera_get", lambda live, path, http=None, **kw: (
        lambda r: r.text if r.status_code == 200 else None)(cam.get(f"http://x{path}")))
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    bg = Background(root)
    dlg = CameraImageDialog(root, bg, CameraSettings(id="c1", name="Стол 1", url=LIVE), tmp_path)

    def pump(until):
        end = time.time() + 5
        while time.time() < end and not until():
            root.update()
            time.sleep(0.02)
        assert until()

    pump(lambda: "Backlight = 0" in dlg.text.get("1.0", "end"))
    dlg._apply("hlc")
    pump(lambda: "Готово" in dlg.status.cget("text"))
    assert cam.options["Backlight"] == "3"
    dlg._restore()
    pump(lambda: "возвращены" in dlg.status.cget("text"))
    assert cam.options["Backlight"] == "0"
    root.destroy()
