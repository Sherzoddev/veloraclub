"""Pasting must work with a Russian keyboard layout (Tk binds Ctrl+V to the
letter "v", so Ctrl+м pastes nothing). Needs a screen; skipped without one.

On Windows the key code of a key is the same in every layout (V is 86), which
is what the handler relies on; the tests feed it events as Windows sends them.
"""
from types import SimpleNamespace

import pytest

tk = pytest.importorskip("tkinter")

from velora_vision.gui.common import clipboard_text, install_clipboard_support  # noqa: E402


@pytest.fixture
def window():
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    handler = install_clipboard_support(root, windows=True)
    entry = tk.Entry(root)
    entry.pack()
    root.update()
    entry.focus_force()
    root.update()
    yield root, entry, handler
    root.destroy()


def key(entry, keycode, keysym):
    return SimpleNamespace(widget=entry, keycode=keycode, keysym=keysym)


def test_ctrl_v_with_a_russian_layout_pastes(window):
    root, entry, handler = window
    root.clipboard_clear()
    root.clipboard_append("123456789:AAHtoken")
    assert handler(key(entry, 86, "Cyrillic_em")) == "break"  # V on a Russian layout
    root.update()
    assert entry.get() == "123456789:AAHtoken"


def test_ctrl_c_and_ctrl_x_with_a_russian_layout(window):
    root, entry, handler = window
    entry.insert(0, "hello")
    entry.select_range(0, "end")
    handler(key(entry, 67, "Cyrillic_es"))  # C
    root.update()
    assert root.clipboard_get() == "hello"
    handler(key(entry, 88, "Cyrillic_che"))  # X
    root.update()
    assert entry.get() == ""


def test_ctrl_a_selects_everything(window):
    root, entry, handler = window
    entry.insert(0, "hello")
    assert handler(key(entry, 65, "Cyrillic_ef")) == "break"  # A
    assert entry.selection_get() == "hello"


def test_a_latin_layout_is_left_to_tk_so_nothing_is_pasted_twice(window):
    root, entry, handler = window
    root.clipboard_clear()
    root.clipboard_append("ab")
    assert handler(key(entry, 86, "v")) is None
    assert handler(key(entry, 86, "V")) is None
    assert entry.get() == ""


def test_other_keys_are_not_touched(window):
    root, entry, handler = window
    assert handler(key(entry, 83, "Cyrillic_yeru")) is None  # Ctrl+S


def test_on_other_systems_the_default_binding_is_untouched():
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    try:
        handler = install_clipboard_support(root, windows=False)
        entry = tk.Entry(root)
        assert handler(key(entry, 86, "Cyrillic_em")) is None
    finally:
        root.destroy()


def test_clipboard_text_is_one_trimmed_line(window):
    root, entry, handler = window
    root.clipboard_clear()
    root.clipboard_append("  123:ABC \n ")
    assert clipboard_text(root) == "123:ABC"
    root.clipboard_clear()
    assert clipboard_text(root) == ""
