"""The rules: when is a table "in use" and when does that need a message.

Pure logic with no cameras and no network, so every rule can be tested. The
service feeds it, once per look at the camera, how many people stand in the
table's zone and what the program says about the table's session.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

# The program could not be asked (no internet, function down): say nothing
# rather than accuse the cashier of a missing session.
UNKNOWN = "?"


@dataclass(frozen=True)
class Rules:
    # People in the zone that count as "playing". 1 also catches a single
    # player, at the price of more false alarms from someone just standing.
    min_people_play: int = 1
    # Playing this long with no session -> message.
    unrecorded_after: float = 5 * 60
    # Nobody at the table this long while the clock runs -> message.
    idle_after: float = 15 * 60
    # People missed by the detector for a few frames must not reset the timer.
    gap: float = 20
    # The same message for the same table at most this often.
    cooldown: float = 30 * 60
    # After a session ends people stand around, pay, talk: no alarms for a
    # while.
    grace_after_session: float = 10 * 60


@dataclass(frozen=True)
class Event:
    kind: str  # "unrecorded" | "idle"
    table: str
    people: int
    seconds: float  # how long it has been going on


class TableTracker:
    def __init__(self, table: str, rules: Rules):
        self.table = table
        self.rules = rules
        self.play_since: Optional[float] = None
        self._last_play: float = 0.0
        self.empty_since: Optional[float] = None
        self._last_unrecorded: Optional[float] = None
        self._last_idle: Optional[float] = None
        self._prev_session: Optional[str] = None
        self._grace_until: float = 0.0

    @property
    def occupied(self) -> bool:
        return self.play_since is not None

    def update(self, now: float, people: int, session: Optional[str]) -> list[Event]:
        """`session` is None (no session), a status like "ACTIVE", or UNKNOWN."""
        r = self.rules
        known = session != UNKNOWN

        # A session just ended: let people leave before judging again.
        if known and self._prev_session not in (None, UNKNOWN) and session is None:
            self.play_since = None
            self._grace_until = now + r.grace_after_session
        if known:
            self._prev_session = session
            if session is not None:
                # A running session answers the question; start fresh after it.
                self._last_unrecorded = None

        # Presence with a tolerance for flickering detections.
        playing = people >= r.min_people_play and now >= self._grace_until
        if playing:
            self._last_play = now
            if self.play_since is None:
                self.play_since = now
        elif self.play_since is not None and now - self._last_play > r.gap:
            self.play_since = None

        # Emptiness is only about nobody at all.
        if people == 0:
            if self.empty_since is None:
                self.empty_since = now
        else:
            self.empty_since = None
            self._last_idle = None

        events: list[Event] = []
        if not known:
            return events

        if (
            session is None
            and self.play_since is not None
            and now - self.play_since >= r.unrecorded_after
            and self._cooled(now, self._last_unrecorded)
        ):
            self._last_unrecorded = now
            events.append(Event("unrecorded", self.table, people, now - self.play_since))

        if (
            session == "ACTIVE"
            and self.empty_since is not None
            and now - self.empty_since >= r.idle_after
            and self._cooled(now, self._last_idle)
        ):
            self._last_idle = now
            events.append(Event("idle", self.table, people, now - self.empty_since))

        return events

    def _cooled(self, now: float, last: Optional[float]) -> bool:
        return last is None or now - last >= self.rules.cooldown
