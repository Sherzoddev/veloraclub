"""Did a ball go into a pocket: balls on the cloth before and after a shot.

The logic was found on a real recording from a club camera: three balls lay
on the table, one shot, one ball left (two potted)."""
import threading

import cv2
import numpy as np

from velora_vision.clips.balls import BallCounter
from velora_vision.clips.pots import judge
from velora_vision.clips.recorder import ClipRecorder
from velora_vision.clips.shots import Shot
from velora_vision.config import CameraCfg, TableCfg

W, H = 640, 360
FELT = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]


def history(counts_by_second, until=30.0, step=0.1):
    """[(time, n)] from {start_second: n} pieces, each lasting until the next."""
    out = []
    keys = sorted(counts_by_second)
    for k, start in enumerate(keys):
        end = keys[k + 1] if k + 1 < len(keys) else until
        t = start
        while t < end:
            out.append((t, counts_by_second[start]))
            t += step
    return out


# -- the verdict -------------------------------------------------------------
def test_three_balls_then_one_is_two_potted():
    h = history({0: 3, 11: 1})                    # the shot is at 10–11 s
    v = judge(h, 10.0, 11.0)
    assert (v.before, v.after, v.pots) == (3, 1, 2)


def test_same_count_is_no_pot():
    assert judge(history({0: 3}), 10.0, 11.0).pots == 0


def test_more_balls_afterwards_is_no_pot():
    assert judge(history({0: 2, 11: 3}), 10.0, 11.0).pots == 0


def test_a_person_standing_in_front_for_a_while_does_not_make_a_pot():
    # balls hidden for most of the time after the shot, but visible for a moment
    h = history({0: 3, 11: 1, 13: 3, 13.8: 1})
    assert judge(h, 10.0, 11.0).pots == 0


def test_a_hand_hiding_a_ball_for_a_moment_before_the_shot_does_not_hide_the_balls():
    h = history({0: 3, 9.2: 2, 9.5: 3, 11: 3})
    assert judge(h, 10.0, 11.0).pots == 0


def test_no_verdict_without_enough_history():
    assert judge(history({0: 3}, until=10.5), 10.0, 11.0) is None   # nothing after
    assert judge([(12.0, 1)] * 10, 10.0, 11.0) is None          # nothing before


# -- counting balls on a picture ----------------------------------------------
def table(balls=(), extra=None):
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (120, 150, 20)          # a teal cloth, BGR
    for x, y, color in balls:
        cv2.circle(img, (x, y), 7, color, -1)
    if extra:
        extra(img)
    return img


WHITE, YELLOW, RED = (235, 235, 235), (30, 220, 235), (40, 40, 220)


def count(img):
    return len(BallCounter([tuple(p) for p in FELT]).balls(img))


def test_balls_of_different_colours_are_counted():
    assert count(table([(200, 150, WHITE), (300, 200, YELLOW), (400, 120, RED)])) == 3


def test_an_empty_cloth_has_no_balls():
    assert count(table()) == 0


def test_a_person_sized_spot_is_not_a_ball():
    def person(img):
        cv2.rectangle(img, (250, 80), (330, 260), (200, 210, 220), -1)
    assert count(table([(450, 150, WHITE)], person)) == 1


def test_a_cue_is_not_a_ball():
    def cue(img):
        cv2.line(img, (100, 300), (400, 200), (220, 230, 235), 3)
    assert count(table([(450, 150, WHITE)], cue)) == 1


def test_a_ball_on_the_cushion_outside_the_cloth_is_not_counted():
    assert count(table([(20, 20, WHITE), (300, 200, WHITE)])) == 1


# -- the recorder on pictures -------------------------------------------------
class Sender:
    def __init__(self):
        self.jobs = []

    def submit(self, job):
        self.jobs.append(job)
        return True


def recorder(sender, mode):
    cam = CameraCfg("cam", "x.mp4", [TableCfg("1 Stol", None, FELT)])
    return ClipRecorder(cam, None, sender, threading.Event(), mode=mode)


def play(rec, potted, dt=1 / 15, step=15):
    """Four balls lie still; then a shot: ball A rolls on and stays on the
    table, ball B is potted (or slows down and stops in the middle), and for
    "double" ball D goes in as well."""
    now = 1000.0
    still = [(450, 200, WHITE), (200, 280, RED)]       # C and E never move
    a, b, d = (150.0, 100.0), (330.0, 230.0), (330.0, 130.0)
    for _ in range(60):
        rec.step(table(still + [(int(a[0]), int(a[1]), WHITE), (int(b[0]), int(b[1]), YELLOW),
                                (int(d[0]), int(d[1]), WHITE)]), now)
        now += dt
    for i in range(60):
        a = (a[0] + 4, a[1] + 1)
        balls = list(still) + [(int(a[0]), int(a[1]), WHITE)]
        if potted:
            b = (b[0] + step, b[1] + step * 0.4)
            if b[0] < 565:
                balls.append((int(b[0]), int(b[1]), YELLOW))
        else:
            b = (b[0] + max(1.0, 15 - i * 0.8), b[1] + 3 if i < 20 else b[1])
            balls.append((int(b[0]), int(b[1]), YELLOW))
        if potted == "double":
            d = (d[0] + step, d[1] - step * 0.4)
            if d[0] < 565 and d[1] > 40:
                balls.append((int(d[0]), int(d[1]), WHITE))
        else:
            balls.append((int(d[0]), int(d[1]), WHITE))
        rec.step(table(balls), now)
        now += dt
    final = list(still) + [(int(a[0]), int(a[1]), WHITE)]
    if not potted:
        final.append((int(b[0]), int(b[1]), YELLOW))
    if potted != "double":
        final.append((int(d[0]), int(d[1]), WHITE))
    for _ in range(150):
        rec.step(table(final), now)
        now += dt
    return now


def test_a_potted_ball_is_found_and_sent():
    sender = Sender()
    play(recorder(sender, "pot"), potted=True)
    assert len(sender.jobs) == 1
    assert "🎯" in sender.jobs[0].caption and "забито шаров 1" in sender.jobs[0].caption
    assert sender.jobs[0].table == "1 Stol"


def test_a_ball_that_just_stops_is_not_a_pot():
    sender = Sender()
    play(recorder(sender, "pot"), potted=False)
    assert sender.jobs == []


def test_every_shot_mode_sends_it_anyway():
    sender = Sender()
    play(recorder(sender, "learn"), potted=False)
    assert len(sender.jobs) == 1


def test_default_mode_wants_a_striking_shot_not_just_a_pot():
    single, double = Sender(), Sender()
    play(recorder(single, "pot_bright"), potted=True)           # one ball in: an ordinary shot
    play(recorder(double, "pot_bright"), potted="double")       # two balls in at once
    assert single.jobs == []
    assert len(double.jobs) == 1
    assert "забито шаров 2" in double.jobs[0].caption


def test_clip_plays_at_the_speed_it_was_filmed():
    # The picture arrives 10 times a second, not the 15 the recorder aims for:
    # the clip must be encoded at about 10 frames per second.
    sender = Sender()
    play(recorder(sender, "pot"), potted=True, dt=0.1)
    assert len(sender.jobs) == 1
    assert 9.0 <= sender.jobs[0].fps <= 11.0


def test_clip_runs_on_five_seconds_after_the_shot():
    sender = Sender()
    play(recorder(sender, "pot"), potted=True)
    job = sender.jobs[0]
    seconds = len(job.frames) / job.fps
    assert seconds >= 5 + 3 + 4.5          # lead-in, the shot, the roll after


def test_repeated_picture_is_not_looked_at_twice():
    class Reader:
        def __init__(self):
            self.frame = table()
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
    assert reader.calls > 5 and len(looks) == 1


def test_old_settings_move_to_the_bright_pots_mode_once():
    from velora_vision.settings import Settings
    old = Settings().to_json()
    old.pop("version")
    for was in ("learn", "pot"):
        old["clips_mode"] = was
        assert Settings.from_json(old).clips_mode == "pot_bright"
    new = Settings().to_json()
    new["clips_mode"] = "pot"
    assert Settings.from_json(new).clips_mode == "pot"
    assert Settings().clips_mode == "pot_bright"
