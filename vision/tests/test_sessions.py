import pytest
import requests

from velora_vision.sessions import (ResourceState, SessionsClient, SessionsError,
                                    match_resource)

R = [
    ResourceState("11111111-1111-1111-1111-111111111111", "1 Stol", "", None, None),
    ResourceState("22222222-2222-2222-2222-222222222222", "VIP  2", "", "ACTIVE", "t"),
]
TOKEN = "123456789:AAH" + "x" * 32


class Resp:
    def __init__(self, status=200, payload=None):
        self.status_code, self._p = status, payload

    def json(self):
        if self._p is None:
            raise ValueError("no json")
        return self._p


class Http:
    def __init__(self, resp=None, error=None):
        self.resp, self.error, self.calls = resp, error, []

    def post(self, url, **kw):
        self.calls.append((url, kw))
        if self.error:
            raise self.error
        return self.resp


def test_match_by_name_ignores_case_and_spaces():
    assert match_resource("vip 2", R).session_status == "ACTIVE"
    assert match_resource(" 1 stol ", R).name == "1 Stol"
    assert match_resource("5 Stol", R) is None


def test_match_by_id():
    assert match_resource("22222222-2222-2222-2222-222222222222", R).name == "VIP  2"


def test_fetch_sends_only_the_token_and_parses():
    payload = {"club_name": "Клуб", "timezone": "Asia/Tashkent", "owner_chat_id": 599,
               "resources": [{"id": "a", "name": "1 Stol", "zone": None,
                              "session_status": "ACTIVE", "session_started_at": "t"}]}
    http = Http(Resp(200, payload))
    snap = SessionsClient("https://x.supabase.co/", f" {TOKEN} ", http=http).fetch()
    url, kw = http.calls[0]
    assert url == "https://x.supabase.co/functions/v1/vision-sessions"
    assert kw["json"] == {"bot_token": TOKEN}
    assert snap.club_name == "Клуб" and snap.owner_chat_id == 599
    assert snap.resources[0].session_status == "ACTIVE"


def test_owner_chat_may_be_missing():
    payload = {"club_name": "К", "timezone": "UTC", "owner_chat_id": None, "resources": []}
    snap = SessionsClient("https://x", TOKEN, http=Http(Resp(200, payload))).fetch()
    assert snap.owner_chat_id is None


@pytest.mark.parametrize("status,code,text", [
    (409, "NOT_OWNER_BOT", "кассового"),
    (401, "UNKNOWN_TOKEN", "Такого бота"),
    (400, "BAD_TOKEN_FORMAT", "неправильно"),
])
def test_server_errors_are_in_plain_words(status, code, text):
    client = SessionsClient("https://x", TOKEN, http=Http(Resp(status, {"error": code})))
    with pytest.raises(SessionsError, match=text):
        client.fetch()


def test_unknown_error_shows_the_status():
    with pytest.raises(SessionsError, match="500"):
        SessionsClient("https://x", TOKEN, http=Http(Resp(500))).fetch()


def test_no_internet():
    client = SessionsClient("https://x", TOKEN, http=Http(error=requests.ConnectionError("down")))
    with pytest.raises(SessionsError, match="интернет"):
        client.fetch()
