"""A ball into a pocket vs. a ball that just stops or leaves toward a cushion."""
import threading

import cv2
import numpy as np

from velora_vision.clips.pots import PotTracker, pocket_points
from velora_vision.clips.recorder import ClipRecorder
from velora_vision.config import CameraCfg, TableCfg

SQUARE = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]
LONG = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.5), (0.1, 0.5)]  # a table wider than tall


def run(tracker, frames, dt=0.1):
    """frames: list of lists of blob centres, one per look. Returns pots seen."""
    total = 0
    for i, blobs in enumerate(frames):
        total += tracker.update(i * dt, blobs)
    return total


def test_pockets_are_corners_and_middles_of_long_sides():
    pts = pocket_points(LONG, 1.0)
    assert len(pts) == 6
    assert (0.5, 0.1) in pts and (0.5, 0.5) in pts


def test_fast_ball_vanishing_at_a_corner_is_a_pot():
    path = [[(0.5 + 0.1 * i, 0.5 + 0.1 * i)] for i in range(4)]  # to (0.8, 0.8), heading to the corner
    assert run(PotTracker(SQUARE), path + [[], []]) == 1


def test_ball_that_slows_and_stops_mid_table_is_not_a_pot():
    path = [[(0.5 + 0.001 * i, 0.5)] for i in range(4)]
    assert run(PotTracker(SQUARE), path + [[], []]) == 0


def test_slow_ball_near_a_pocket_is_not_a_pot():
    path = [[(0.80 + 0.001 * i, 0.80 + 0.001 * i)] for i in range(4)]
    assert run(PotTracker(SQUARE), path + [[], []]) == 0


def test_fast_ball_gone_far_from_every_pocket_is_not_a_pot():
    path = [[(0.2 + 0.05 * i, 0.1)] for i in range(4)]  # along the top cushion, to x=0.35
    assert run(PotTracker(LONG), path + [[], []]) == 0


def test_side_pocket_counts():
    path = [[(0.5, 0.5 - 0.08 * i)] for i in range(1, 4)]  # up towards the middle of the top side... then in
    path = [[(0.5, 0.45 - 0.1 * i)] for i in range(4)]
    assert run(PotTracker(LONG), path + [[], []]) >= 0  # does not crash on a side-pocket run
    towards = [[(0.5, 0.5 - 0.1 + 0.0 * i + (0.1 - 0.1) * i)] for i in range(1)]
    ball = [[(0.5, 0.25 - 0.05 * i)] for i in range(4)]  # (0.5,0.25) -> (0.5,0.10): the top side pocket
    assert run(PotTracker(LONG), ball + [[], []]) == 1


def test_two_balls_potted_are_two():
    a = [(0.5 + 0.1 * i, 0.5 + 0.1 * i) for i in range(4)]
    b = [(0.5 - 0.1 * i, 0.5 - 0.1 * i) for i in range(4)]
    frames = [[a[i], b[i]] for i in range(4)] + [[], []]
    assert run(PotTracker(SQUARE), frames) == 2


def test_two_balls_crossing_do_not_make_a_pot():
    a = [(0.3 + 0.02 * i, 0.5) for i in range(8)]
    b = [(0.7 - 0.02 * i, 0.5) for i in range(8)]
    frames = [[a[i], b[i]] for i in range(8)] + [[(0.4, 0.5), (0.6, 0.5)]] * 3
    assert run(PotTracker(SQUARE), frames) == 0


# -- with the recorder, on pictures -----------------------------------------
W, H = 640, 360
FELT = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]


class Sender:
    def __init__(self):
        self.jobs = []

    def submit(self, job):
        self.jobs.append(job)
        return True


def scene(balls):
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (40, 110, 40)
    for x, y in balls:
        cv2.circle(img, (int(x), int(y)), 8, (235, 235, 235), -1)
    return img


def recorder(sender, mode):
    cam = CameraCfg("cam", "x.mp4", [TableCfg("1 Stol", None, FELT)])
    return ClipRecorder(cam, None, sender, threading.Event(), mode=mode)


def play(rec, potted, dt=1 / 15, step=15):
    """Two balls move; the first heads for the bottom right corner and is
    either potted there or slows down and stops in the middle."""
    now = 1000.0
    for _ in range(60):  # a still table
        rec.step(scene([(150, 100), (330, 230)]), now)
        now += dt
    slow = (150.0, 100.0)
    fast = (330.0, 230.0)
    for i in range(60):
        slow = (slow[0] + 4, slow[1] + 1)
        balls = [slow]
        if potted:
            fast = (fast[0] + step, fast[1] + step * 0.4)
            if fast[0] < 565:
                balls.append(fast)
        elif i < 20:
            fast = (fast[0] + max(1.0, 15 - i * 0.8), fast[1] + 3)
            balls.append(fast)
        else:
            balls.append(fast)
        rec.step(scene(balls), now)
        now += dt
    for _ in range(120):
        rec.step(scene([slow, fast] if not potted else [slow]), now)
        now += dt
    return now


def test_pot_mode_sends_a_potted_shot_with_a_target_caption():
    sender = Sender()
    play(recorder(sender, "pot"), potted=True)
    assert len(sender.jobs) == 1
    assert "🎯" in sender.jobs[0].caption and "забито шаров 1" in sender.jobs[0].caption
    assert sender.jobs[0].table == "1 Stol" and sender.jobs[0].score > 4


def test_pot_mode_ignores_a_shot_without_a_potted_ball():
    sender = Sender()
    play(recorder(sender, "pot"), potted=False)
    assert sender.jobs == []


def test_every_shot_mode_still_sends_it():
    sender = Sender()
    play(recorder(sender, "learn"), potted=False)
    assert len(sender.jobs) == 1


def test_clip_plays_at_the_speed_it_was_filmed():
    # The picture arrives 10 times a second, not the 15 the recorder aims for:
    # the clip must be encoded at about 10 frames per second, or it plays
    # one and a half times too fast (and in the real world it was far worse).
    sender = Sender()
    play(recorder(sender, "pot"), potted=True, dt=0.1)
    assert len(sender.jobs) == 1
    assert 9.0 <= sender.jobs[0].fps <= 11.0


def test_repeated_picture_is_not_looked_at_twice():
    class Reader:
        def __init__(self):
            self.frame = scene([(150, 100)])
            self.calls = 0

        def latest(self):
            self.calls += 1
            return self.frame, 0.0

    stop = threading.Event()
    reader = Reader()
    rec = ClipRecorder(CameraCfg("cam", "x.mp4", [TableCfg("1 Stol", None, FELT)]),
                       reader, Sender(), stop, mode="pot", sleep=lambda s: None)
    looks = []
    rec.step = lambda frame, now: looks.append(now)

    def stop_after(s, n=[0]):
        n[0] += 1
        if n[0] > 20:
            stop.set()

    rec._sleep = stop_after
    rec.run()
    assert reader.calls > 5 and len(looks) == 1  # the same picture: looked at once


# -- brightness, the roll after the pot, settings --------------------------
def play_two_pots(rec, dt=1 / 15):
    """Two balls are potted in one shot: one into the bottom right corner, one
    into the top left. A third ball keeps rolling."""
    now = 1000.0
    still = [(300, 180)]
    for _ in range(60):
        rec.step(scene(still + [(330, 230), (270, 130)]), now)
        now += dt
    a, b, c = (330.0, 230.0), (270.0, 130.0), (150.0, 200.0)
    for i in range(60):
        c = (c[0] + 4, c[1])
        a = (a[0] + 15, a[1] + 6)
        b = (b[0] - 15, b[1] - 6)
        balls = still + [c]
        if a[0] < 565:
            balls.append(a)
        if b[0] > 75:
            balls.append(b)
        rec.step(scene(balls), now)
        now += dt
    for _ in range(120):
        rec.step(scene(still + [c]), now)
        now += dt


def test_default_mode_wants_a_striking_shot_not_just_a_pot():
    single, double = Sender(), Sender()
    play(recorder(single, "pot_bright"), potted=True)          # one ball in: an ordinary shot
    play_two_pots(recorder(double, "pot_bright"))               # two balls in at once
    assert single.jobs == []
    assert len(double.jobs) == 1
    assert "забито шаров 2" in double.jobs[0].caption


def test_every_potted_shot_mode_sends_the_ordinary_one_too():
    sender = Sender()
    play(recorder(sender, "pot"), potted=True)
    assert len(sender.jobs) == 1


def test_clip_runs_on_five_seconds_after_the_ball_drops():
    from velora_vision.clips.pots import PotTracker
    from velora_vision.clips.shots import Shot

    rec = recorder(Sender(), "pot")
    watch = rec.watches[0]
    watch.pots = PotTracker([tuple(p) for p in FELT], H / W)
    watch.pots.pots, watch.pots.pot_speeds = [1002.0], [1.0]   # went in 1 s after the shot ended
    rec._shot_finished(watch, Shot(1000.0, 1001.0, 3), 1002.5)
    assert rec._pending and rec._pending[0][2] == 1007.0       # 1002 + 5 s


def test_two_looks_are_not_a_ball():
    path = [[(0.7, 0.7)], [(0.8, 0.8)]]
    assert run(PotTracker(SQUARE), path + [[], []]) == 0


def test_old_settings_move_to_the_bright_pots_mode_once():
    from velora_vision.settings import Settings
    old = Settings().to_json()
    old.pop("version")
    for was in ("learn", "pot"):
        old["clips_mode"] = was
        assert Settings.from_json(old).clips_mode == "pot_bright"
    new = Settings().to_json()
    new["clips_mode"] = "pot"  # a choice made on this version stays
    assert Settings.from_json(new).clips_mode == "pot"
    assert Settings().clips_mode == "pot_bright"
