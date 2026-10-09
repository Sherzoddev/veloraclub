"""The picture the program works with: turned and widened as chosen, and
the main stream preferred when the light one is squeezed square."""
import numpy as np

from velora_vision import camera_find
from velora_vision.camera import reshape
from velora_vision.geometry import turn_point
from velora_vision.settings import CameraSettings, Settings


def frame(w, h):
    return np.zeros((h, w, 3), np.uint8)


def test_reshape_keeps_as_is_by_default():
    assert reshape(frame(704, 576)).shape[:2] == (576, 704)


def test_rotate_90_swaps_sides():
    assert reshape(frame(640, 360), 90).shape[:2] == (640, 360)
    assert reshape(frame(640, 360), 180).shape[:2] == (360, 640)
    assert reshape(frame(640, 360), 270).shape[:2] == (640, 360)


def test_rotation_moves_pixels_clockwise():
    f = frame(4, 2)
    f[0, 0] = 255  # top-left
    assert reshape(f, 90)[0, 1].tolist() == [255, 255, 255]  # top-right of the 2x4 result


def test_widen_squeezed_picture_to_16_9():
    out = reshape(frame(704, 576), widen=True)
    assert out.shape[:2] == (576, 1024)


def test_widen_leaves_wide_picture_alone():
    assert reshape(frame(1920, 1080), widen=True).shape[:2] == (1080, 1920)


def test_turn_point_matches_the_picture_turn():
    # the top-left corner of the picture lands top-right after 90° clockwise
    assert turn_point(0.0, 0.0, 90) == (1.0, 0.0)
    assert turn_point(0.25, 0.5, 180) == (0.75, 0.5)
    assert turn_point(0.0, 0.0, 270) == (0.0, 1.0)
    assert turn_point(0.3, 0.6, 0) == (0.3, 0.6)
    # four quarter turns bring any point back
    x, y = 0.2, 0.7
    for _ in range(4):
        x, y = turn_point(x, y, 90)
    assert (round(x, 9), round(y, 9)) == (0.2, 0.7)


def test_stream_swap_dahua():
    sub = "rtsp://admin:p@192.168.1.45:554/cam/realmonitor?channel=1&subtype=1"
    main = "rtsp://admin:p@192.168.1.45:554/cam/realmonitor?channel=1&subtype=0"
    assert camera_find.stream_kind(sub) == "sub"
    assert camera_find.stream_kind(main) == "main"
    assert camera_find.other_stream(sub, "main") == main
    assert camera_find.other_stream(main, "sub") == sub
    assert camera_find.other_stream(main, "main") == main


def test_stream_swap_other_makers_and_unknown():
    assert camera_find.other_stream("rtsp://h/Streaming/Channels/102", "main") == "rtsp://h/Streaming/Channels/101"
    assert camera_find.other_stream("rtsp://h/stream2", "main") == "rtsp://h/stream1"
    assert camera_find.other_stream("rtsp://h/some/custom", "main") is None
    assert camera_find.stream_kind("rtsp://h/some/custom") is None


def test_autodetect_prefers_wide_main_stream_over_square_light_one():
    seen = []

    def grab(url, timeout, attempts):
        seen.append(url)
        if url.endswith("subtype=1"):
            return frame(704, 576)
        if url.endswith("subtype=0"):
            return frame(1920, 1080)
        return None

    found = camera_find.autodetect("10.0.0.5", "admin", "pw", grab=grab)
    assert found and found.url.endswith("subtype=0") and (found.width, found.height) == (1920, 1080)


def test_autodetect_keeps_light_stream_when_main_does_not_answer():
    def grab(url, timeout, attempts):
        return frame(704, 576) if url.endswith("subtype=1") else None

    found = camera_find.autodetect("10.0.0.5", "admin", "pw", grab=grab)
    assert found and found.url.endswith("subtype=1")


def test_settings_keep_rotation_and_widen():
    s = Settings()
    s.cameras = [CameraSettings("c1", "Зал", "rtsp://x", "foot", 90, True)]
    back = Settings.from_json(s.to_json())
    assert (back.cameras[0].rotate, back.cameras[0].widen) == (90, True)
    # an old settings file has neither field
    old = s.to_json()
    for c in old["cameras"]:
        c.pop("rotate"), c.pop("widen")
    old_back = Settings.from_json(old)
    assert (old_back.cameras[0].rotate, old_back.cameras[0].widen) == (0, False)
