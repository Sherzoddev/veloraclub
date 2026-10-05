from velora_vision.tracker import UNKNOWN, Rules, TableTracker

MIN = 60.0
RULES = Rules(
    min_people_play=1,
    unrecorded_after=5 * MIN,
    idle_after=15 * MIN,
    gap=20,
    cooldown=30 * MIN,
    grace_after_session=10 * MIN,
)


def run(tracker, start, seconds, people, session, step=5):
    """Feeds the tracker every `step` seconds, returns all events."""
    events = []
    t = start
    while t <= start + seconds:
        events += tracker.update(t, people, session)
        t += step
    return events


def test_playing_without_session_alerts_after_five_minutes():
    tr = TableTracker("Стол 1", RULES)
    assert run(tr, 0, 4 * MIN, 2, None) == []
    events = run(tr, 4 * MIN + 5, 2 * MIN, 2, None)
    assert [e.kind for e in events] == ["unrecorded"]
    assert events[0].table == "Стол 1"
    assert events[0].people == 2


def test_running_session_never_alerts_unrecorded():
    tr = TableTracker("Стол 1", RULES)
    assert run(tr, 0, 60 * MIN, 3, "ACTIVE") == []


def test_paused_session_counts_as_a_session():
    tr = TableTracker("Стол 1", RULES)
    assert run(tr, 0, 30 * MIN, 2, "PAUSED") == []


def test_nobody_at_the_table_means_no_alert():
    tr = TableTracker("Стол 1", RULES)
    assert run(tr, 0, 60 * MIN, 0, None) == []


def test_a_flickering_detection_does_not_reset_the_timer():
    tr = TableTracker("Стол 1", RULES)
    events = []
    t = 0
    while t < 7 * MIN:
        # Missed for 10 seconds out of every 60: shorter than the 20 s gap.
        people = 0 if (t % 60) in (30, 35) else 2
        events += tr.update(t, people, None)
        t += 5
    assert [e.kind for e in events] == ["unrecorded"]


def test_leaving_for_a_while_resets_the_timer():
    tr = TableTracker("Стол 1", RULES)
    run(tr, 0, 3 * MIN, 2, None)
    run(tr, 3 * MIN + 5, 2 * MIN, 0, None)  # gone for 2 minutes
    # Back: the 5 minutes start over, so nothing at 4 minutes after return.
    assert run(tr, 5 * MIN + 10, 4 * MIN, 2, None) == []


def test_alert_repeats_only_after_the_cooldown():
    tr = TableTracker("Стол 1", RULES)
    events = run(tr, 0, 80 * MIN, 2, None)
    times_in_minutes = len(events)
    # First at ~5 min, then every 30 min: 5, 35, 65.
    assert times_in_minutes == 3


def test_starting_a_session_stops_the_alerts():
    tr = TableTracker("Стол 1", RULES)
    assert [e.kind for e in run(tr, 0, 6 * MIN, 2, None)] == ["unrecorded"]
    assert run(tr, 6 * MIN + 5, 60 * MIN, 2, "ACTIVE") == []


def test_grace_after_a_session_ends():
    tr = TableTracker("Стол 1", RULES)
    run(tr, 0, 30 * MIN, 2, "ACTIVE")
    # The session is closed, people stay around for 9 minutes: quiet.
    assert run(tr, 30 * MIN + 5, 9 * MIN, 2, None) == []
    # Still there long after the grace period: now it is a new game.
    events = run(tr, 40 * MIN, 8 * MIN, 2, None)
    assert [e.kind for e in events] == ["unrecorded"]


def test_idle_session_alerts_after_fifteen_minutes_of_nobody():
    tr = TableTracker("Стол 1", RULES)
    assert run(tr, 0, 14 * MIN, 0, "ACTIVE") == []
    events = run(tr, 14 * MIN + 5, 2 * MIN, 0, "ACTIVE")
    assert [e.kind for e in events] == ["idle"]


def test_paused_empty_table_is_not_idle():
    tr = TableTracker("Стол 1", RULES)
    assert run(tr, 0, 60 * MIN, 0, "PAUSED") == []


def test_someone_returning_resets_idle():
    tr = TableTracker("Стол 1", RULES)
    run(tr, 0, 10 * MIN, 0, "ACTIVE")
    run(tr, 10 * MIN + 5, 10, 1, "ACTIVE")
    assert run(tr, 10 * MIN + 20, 14 * MIN, 0, "ACTIVE") == []


def test_unknown_session_state_stays_silent_and_catches_up():
    tr = TableTracker("Стол 1", RULES)
    # The program can't be reached for 10 minutes: no accusations.
    assert run(tr, 0, 10 * MIN, 2, UNKNOWN) == []
    # Back online, still nobody started a session: alert right away.
    events = tr.update(10 * MIN + 5, 2, None)
    assert [e.kind for e in events] == ["unrecorded"]


def test_min_people_two_ignores_a_lone_person():
    rules = Rules(
        min_people_play=2, unrecorded_after=5 * MIN, idle_after=15 * MIN,
        gap=20, cooldown=30 * MIN, grace_after_session=10 * MIN,
    )
    tr = TableTracker("Стол 1", rules)
    assert run(tr, 0, 20 * MIN, 1, None) == []
    assert [e.kind for e in run(tr, 20 * MIN + 5, 6 * MIN, 2, None)] == ["unrecorded"]
