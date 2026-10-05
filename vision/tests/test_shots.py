from velora_vision.clips.shots import Shot, ShotDetector


def feed(det, seq, step=0.1, start=0.0):
    """seq: moving-ball counts, one per look. Returns the shots found."""
    out = []
    for i, n in enumerate(seq):
        shot = det.update(start + i * step, n)
        if shot:
            out.append(shot)
    return out


def test_a_burst_of_movement_is_one_shot():
    det = ShotDetector(min_blobs=2, start_frames=3, settle=1.0)
    shots = feed(det, [0] * 5 + [3, 4, 3, 2, 2, 1, 1] + [0] * 15)
    assert len(shots) == 1
    s = shots[0]
    assert s.peak == 4
    assert 0.45 < s.start < 0.55  # when the movement began, not when it was confirmed
    assert 1.0 < s.end < 1.3


def test_one_or_two_stray_looks_are_not_a_shot():
    det = ShotDetector(min_blobs=2, start_frames=3)
    assert feed(det, [0, 3, 0, 3, 0, 0, 3, 3, 0, 0] + [0] * 20) == []


def test_one_moving_ball_alone_does_not_start_a_shot():
    det = ShotDetector(min_blobs=2)
    assert feed(det, [1] * 50 + [0] * 20) == []


def test_a_long_play_is_cut_at_max_len():
    det = ShotDetector(min_blobs=2, max_len=5.0)
    shots = feed(det, [3] * 100)
    assert len(shots) == 1
    assert shots[0].seconds <= 5.1


def test_two_shots_in_a_row_are_two_shots():
    det = ShotDetector(min_blobs=2, start_frames=2, settle=0.5)
    seq = [3, 3, 3, 2] + [0] * 10 + [4, 4, 4, 2] + [0] * 10
    shots = feed(det, seq)
    assert len(shots) == 2
    assert shots[0].end < shots[1].start


def test_score_favours_many_balls_and_long_play():
    quick = Shot(0, 1, 2)
    break_shot = Shot(0, 6, 8)
    assert break_shot.score > quick.score
