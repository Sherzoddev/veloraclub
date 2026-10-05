import cv2
import numpy as np

from velora_vision.clips.motion import BallMotion

W, H = 640, 360
FELT = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]


def cloth():
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (40, 110, 40)  # green
    return img


def with_balls(positions, radius=8):
    img = cloth()
    for x, y in positions:
        cv2.circle(img, (int(x), int(y)), radius, (235, 235, 235), -1)
    return img


def test_still_table_has_no_motion():
    bm = BallMotion(FELT)
    for _ in range(5):
        assert bm.count(with_balls([(200, 150), (300, 200)])) == 0


def test_each_moving_ball_is_counted():
    bm = BallMotion(FELT)
    pos = [(150.0, 120.0), (300.0, 200.0), (450.0, 260.0)]
    bm.count(with_balls(pos))
    counts = []
    for _ in range(6):
        pos = [(x + 7, y + 3) for x, y in pos]
        counts.append(bm.count(with_balls(pos)))
    assert counts[-1] == 3
    assert min(counts) == 3


def test_a_person_sized_change_is_not_a_ball():
    bm = BallMotion(FELT)
    bm.count(cloth())
    img = cloth()
    cv2.rectangle(img, (200, 100), (420, 300), (30, 30, 30), -1)  # a person leaning over
    assert bm.count(img) == 0


def test_a_thin_long_change_is_not_a_ball():
    bm = BallMotion(FELT)
    bm.count(cloth())
    img = cloth()
    cv2.line(img, (150, 120), (480, 130), (230, 230, 230), 4)  # a cue
    assert bm.count(img) == 0


def test_light_change_is_ignored():
    bm = BallMotion(FELT)
    bm.count(cloth())
    brighter = np.clip(cloth().astype(int) + 70, 0, 255).astype(np.uint8)
    assert bm.count(brighter) == 0


def test_movement_outside_the_cloth_is_ignored():
    bm = BallMotion(FELT)
    pos = [(20.0, 20.0), (40.0, 340.0)]  # outside the felt polygon
    bm.count(with_balls(pos))
    for _ in range(4):
        pos = [(x + 5, y) for x, y in pos]
        assert bm.count(with_balls(pos)) == 0
