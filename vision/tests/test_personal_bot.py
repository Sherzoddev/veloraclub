import json
import time
from pathlib import Path

import pytest

from velora_vision import personal_bot as pb
from velora_vision.settings import CameraSettings, Settings

OWNER = "555"
STRANGER = "777"


class Resp:
    def __init__(self, body):
        self.body = body

    def json(self):
        return self.body


class FakeTelegram:
    """api.telegram.org: answers getMe/getUpdates, records everything sent."""

    def __init__(self, updates=None, error=None):
        self.updates = list(updates or [])
        self.sent = []
        self.error = error

    def post(self, url, data=None, files=None, timeout=None):
        method = url.rsplit("/", 1)[1]
        if self.error:
            return Resp({"ok": False, "error_code": self.error[0], "description": self.error[1]})
        if method == "getMe":
            return Resp({"ok": True, "result": {"username": "my_club_cams_bot"}})
        if method == "getUpdates":
            if data.get("offset") == -1:
                return Resp({"ok": True, "result": self.updates[-1:]})
            off = int(data.get("offset") or 0)
            out = [u for u in self.updates if u["update_id"] >= off]
            return Resp({"ok": True, "result": out})
        entry = {"method": method, **{k: v for k, v in (data or {}).items()}}
        if files:
            name, f = next(iter(files.items()))
            content = f[1] if isinstance(f[1], bytes) else f[1].read()
            entry["file"] = (name, len(content))
        self.sent.append(entry)
        return Resp({"ok": True, "result": {}})

    def texts(self, chat=None):
        return [e.get("text") for e in self.sent if e["method"] == "sendMessage"
                and (chat is None or str(e["chat_id"]) == chat)]

    def of(self, method):
        return [e for e in self.sent if e["method"] == method]


def msg(uid, chat, text):
    return {"update_id": uid, "message": {"chat": {"id": int(chat), "type": "private"},
                                          "from": {"id": int(chat)}, "text": text}}


def press(uid, chat, data):
    return {"update_id": uid, "callback_query": {"id": f"q{uid}", "from": {"id": int(chat)},
                                                 "message": {"chat": {"id": int(chat)}}, "data": data}}


CAMS = [CameraSettings("a1", "Камера 1", "rtsp://u:p@10.0.0.5/cam/realmonitor?channel=1&subtype=0", "Стол 1"),
        CameraSettings("b2", "Касса", "rtsp://u:p@10.0.0.6/cam/realmonitor?channel=1&subtype=0", "")]


def make(tg, tmp_path, owner=OWNER, local=None, snap=lambda url: b"\xff\xd8jpeg", clip=None):
    def fake_clip(url, out: Path):
        out.write_bytes(b"\0" * 5000)
        return None
    return pb.PersonalBot("123:ABC", owner, lambda: CAMS, tmp_path, local=lambda: local, http=tg,
                          snap=snap, clip=clip or fake_clip, poll_timeout=0)


def test_a_stranger_gets_nothing_but_one_sentence(tmp_path):
    tg = FakeTelegram([msg(1, STRANGER, pb.BTN_ALL), press(2, STRANGER, "s:a1")])
    bot = make(tg, tmp_path)
    bot.step()
    assert tg.texts(STRANGER) == ["Это личный бот, он отвечает только владельцу."]
    assert not tg.of("sendPhoto") and not tg.of("sendVideo")
    assert tg.of("answerCallbackQuery")[0]["text"] == "Это личный бот."


def test_pairing_takes_the_code_once_and_only_in_time(tmp_path):
    tg = FakeTelegram()
    bot = make(tg, tmp_path, owner="")
    tg.updates = [msg(1, STRANGER, "123456")]      # no code asked yet: guessing does nothing
    bot.step()
    assert bot.owner == "" and "не привязан" in tg.texts(STRANGER)[0]
    code = bot.new_pair_code()
    assert len(code) == 6 and code.isdigit()
    tg.updates = [msg(2, STRANGER, "000000"), msg(3, OWNER, code), msg(4, STRANGER, code)]
    bot.step()
    assert bot.owner == OWNER and bot.paired == OWNER and bot.pair_code == ""
    assert "привязан к вам" in tg.texts(OWNER)[-1]
    assert tg.texts(STRANGER)[-1] == "Это личный бот, он отвечает только владельцу."


def test_an_old_code_does_not_pair(tmp_path):
    tg = FakeTelegram()
    bot = make(tg, tmp_path, owner="")
    code = bot.new_pair_code()
    bot.pair_until = time.time() - 1
    tg.updates = [msg(1, OWNER, code)]
    bot.step()
    assert bot.owner == ""


def test_photos_of_all_cameras_with_buttons(tmp_path):
    tg = FakeTelegram([msg(1, OWNER, pb.BTN_ALL)])
    bot = make(tg, tmp_path, local=type("L", (), {"folders": {"Стол 1": tmp_path}})())
    bot.step()
    photos = tg.of("sendPhoto")
    assert [p["caption"].split(" · ")[0] for p in photos] == ["📷 Камера 1", "📷 Касса"]
    first = json.loads(photos[0]["reply_markup"])["inline_keyboard"][0]
    assert [b["callback_data"] for b in first] == ["s:a1", "v:a1", "p:a1"]
    second = json.loads(photos[1]["reply_markup"])["inline_keyboard"][0]
    assert [b["callback_data"] for b in second] == ["s:b2", "v:b2"]   # no table, no recording


def test_a_camera_that_gives_no_picture_is_said_plainly(tmp_path):
    tg = FakeTelegram([press(1, OWNER, "s:b2")])
    make(tg, tmp_path, snap=lambda url: None).step()
    assert "не отдала картинку" in tg.texts(OWNER)[-1]


def test_live_video_is_sent_and_the_file_removed(tmp_path):
    tg = FakeTelegram([press(1, OWNER, "v:a1")])
    make(tg, tmp_path).step()
    video = tg.of("sendVideo")
    assert len(video) == 1 and video[0]["file"] == ("video", 5000)
    assert list(tmp_path.glob("mybot_*")) == []


def test_a_failed_video_tells_why(tmp_path):
    tg = FakeTelegram([press(1, OWNER, "v:a1")])
    make(tg, tmp_path, clip=lambda url, out: "UNAUTHORIZED").step()
    assert "Логин или пароль" in tg.texts(OWNER)[-1]
    assert not tg.of("sendVideo")


def test_the_last_minute_comes_from_the_recording(tmp_path):
    asked = []

    class Local:
        folders = {"Стол 1": tmp_path}

        def cut(self, table, moment, before, after, out):
            asked.append((table, before, after))
            out.write_bytes(b"\0" * 3000)
            return None

    tg = FakeTelegram([press(1, OWNER, "p:a1")])
    make(tg, tmp_path, local=Local()).step()
    assert asked == [("Стол 1", 0, 60)]
    assert tg.of("sendVideo")[0]["file"] == ("video", 3000)


def test_without_recording_the_last_minute_is_explained(tmp_path):
    tg = FakeTelegram([press(1, OWNER, "p:a1")])
    make(tg, tmp_path, local=None).step()
    assert "Запись на компьютере сейчас не идёт" in tg.texts(OWNER)[-1]


def test_choosing_a_camera_lists_them(tmp_path):
    tg = FakeTelegram([msg(1, OWNER, pb.BTN_VIDEO)])
    make(tg, tmp_path).step()
    rows = json.loads(tg.of("sendMessage")[-1]["reply_markup"])["inline_keyboard"]
    assert [r[0]["callback_data"] for r in rows] == ["v:a1", "v:b2"]
    assert rows[0][0]["text"] == "Камера 1 · Стол 1"


def test_what_was_pressed_while_off_is_not_done(tmp_path):
    tg = FakeTelegram([msg(1, OWNER, pb.BTN_ALL), msg(2, OWNER, pb.BTN_ALL)])
    bot = make(tg, tmp_path)
    bot.start_up()
    assert bot.offset == 3 and bot.username == "my_club_cams_bot"
    bot.step()
    assert not tg.of("sendPhoto")


@pytest.mark.parametrize("code,word", [(401, "Токен не подходит"), (409, "уже где-то работает")])
def test_a_wrong_or_busy_token_is_explained(tmp_path, code, word):
    tg = FakeTelegram(error=(code, "x"))
    bot = make(tg, tmp_path)
    bot.start()
    end = time.time() + 3
    while time.time() < end and word not in bot.status:
        time.sleep(0.02)
    bot.stop()
    assert word in bot.status and not bot.ok


def test_the_token_and_owner_are_kept_secretly_in_settings():
    s = Settings(my_bot_token="123:SECRET", my_bot_owner=OWNER)
    data = s.to_json()
    assert "SECRET" not in json.dumps(data)
    back = Settings.from_json(data)
    assert back.my_bot_token == "123:SECRET" and back.my_bot_owner == OWNER
    assert Settings.from_json({}).my_bot_token == ""


# -- the tab in the window -----------------------------------------------------
class FakeBot:
    made = []

    def __init__(self, token, owner, cameras, tmp_dir, local=None, live=None, live_status=None):
        self.token, self.owner, self.cameras, self.live = token, owner, cameras, live
        self.username, self.status, self.ok = "my_club_cams_bot", "Работает", True
        self.paired, self.pair_code, self.alive = None, "", False
        FakeBot.made.append(self)

    def start(self):
        self.alive = True

    def stop(self):
        self.alive = False

    def is_alive(self):
        return self.alive

    def new_pair_code(self):
        self.pair_code = "424242"
        return self.pair_code


class FakeLive:
    made = []

    def __init__(self, token, owner, cameras, data_dir):
        self.token, self.owner, self.running = token, owner, False
        FakeLive.made.append(self)

    def start(self):
        self.running = True

    def stop(self):
        self.running = False

    def url(self):
        return "https://abc-def.trycloudflare.com"

    def status(self):
        return "готов"


def test_the_tab_starts_pairs_and_refuses_the_club_token(tmp_path):
    tk = pytest.importorskip("tkinter")
    from velora_vision.gui.my_bot_tab import MyBotTab
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    FakeBot.made.clear()
    s = Settings(bot_token="999:CLUB")
    saves = []
    frame = tk.Frame(root)
    tab = MyBotTab(frame, lambda: s, lambda: saves.append(1), tmp_path, lambda: None, bot_factory=FakeBot,
                   live_factory=FakeLive)
    tab.sync()
    assert tab.bot is None and not tab.running()

    tab.token.set("999:CLUB")                       # the club's own bot: never polled from here
    tab.collect(s)
    tab.sync()
    tab.tick()
    assert tab.bot is None and "токен бота клуба" in tab.status.cget("text")

    tab.token.set("123:MINE")
    tab.collect(s)
    tab.sync()
    assert tab.running() and FakeBot.made[-1].token == "123:MINE"
    live = FakeLive.made[-1]
    assert live.running and live.token() == "123:MINE"
    assert FakeBot.made[-1].live() == "https://abc-def.trycloudflare.com"
    tab._pair()
    assert "424242" in tab.code_label.cget("text") and "@my_club_cams_bot" in tab.code_label.cget("text")
    tab.bot.paired = "555"
    tab.tick()
    assert s.my_bot_owner == "555" and "Привязано" in tab.code_label.cget("text")

    tab._unpair()
    assert s.my_bot_owner == "" and tab.bot.owner == ""

    tab.token.set("")
    tab.collect(s)
    tab.sync()
    assert tab.bot is None and not FakeBot.made[-1].alive and not live.running
    root.destroy()


def test_the_window_opens_with_the_new_tab(tmp_path, monkeypatch):
    tk = pytest.importorskip("tkinter")
    from velora_vision.gui import main_window as mw
    from velora_vision import settings as settings_mod
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    FakeBot.made.clear()
    monkeypatch.setattr(mw, "MyBotTab", lambda *a, **kw: __import__(
        "velora_vision.gui.my_bot_tab", fromlist=["MyBotTab"]).MyBotTab(*a, bot_factory=FakeBot,
                                                                   live_factory=FakeLive, **kw))
    settings_mod.save(tmp_path, Settings(my_bot_token="123:MINE", run_on_open=False))
    win = mw.MainWindow(root, tmp_path)
    root.update()
    assert win.nb.tab(mw.TAB_MYBOT, "text") == "Мой бот"
    assert win.nb.index(win.nb.select()) == mw.TAB_MYBOT
    assert win.nb.tab(mw.TAB_LOG, "text") == "Журнал"
    assert win.mybot.running()
    win._quit()
    assert not FakeBot.made[-1].alive


def test_the_live_button_gives_the_mini_app_and_keeps_the_menu_up_to_date(tmp_path):
    tg = FakeTelegram([msg(1, OWNER, pb.BTN_LIVE)])
    url = ["https://one.trycloudflare.com"]
    bot = pb.PersonalBot("123:ABC", OWNER, lambda: CAMS, tmp_path, http=tg, live=lambda: url[0], poll_timeout=0)
    bot.step()
    button = json.loads(tg.of("sendMessage")[-1]["reply_markup"])["inline_keyboard"][0][0]
    assert button["web_app"]["url"] == "https://one.trycloudflare.com"
    bot.sync_menu()
    bot.sync_menu()                                   # nothing changed: not sent again
    menus = tg.of("setChatMenuButton")
    assert len(menus) == 1 and json.loads(menus[0]["menu_button"])["web_app"]["url"] == url[0]
    url[0] = "https://two.trycloudflare.com"         # the tunnel started again
    bot.sync_menu()
    assert json.loads(tg.of("setChatMenuButton")[-1]["menu_button"])["web_app"]["url"] == url[0]


def test_live_not_ready_is_said(tmp_path):
    tg = FakeTelegram([msg(1, OWNER, pb.BTN_LIVE)])
    bot = pb.PersonalBot("123:ABC", OWNER, lambda: CAMS, tmp_path, http=tg, live=lambda: None,
                         live_status=lambda: "подключаю…", poll_timeout=0)
    bot.step()
    assert "пока не готов: подключаю…" in tg.texts(OWNER)[-1]


def test_no_menu_button_before_pairing(tmp_path):
    tg = FakeTelegram()
    bot = pb.PersonalBot("123:ABC", "", lambda: CAMS, tmp_path, http=tg, live=lambda: "https://x.trycloudflare.com")
    bot.sync_menu()
    assert not tg.of("setChatMenuButton")
