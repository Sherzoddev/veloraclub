"""Sound for PromoClips (27 s): a soft groove and sound effects that sit on
the events of the picture (frame / 30): the cue hits the ball, the pyramid
breaks, a ball drops into the pocket, taps and messages in the bot, the video
arrives, the logo. Synthesised, so there are no licence questions.

    python3 voice/clips_score.py out/clips_score.wav
"""
import sys

import numpy as np
import soundfile as sf
from scipy import signal

SR = 48000
FPS = 30
LENGTH = 810
N = int(LENGTH / FPS * SR)
rng = np.random.default_rng(7)
out = np.zeros((N, 2))


def sec(f):
    return f / FPS


def midi(n):
    return 440 * 2 ** ((n - 69) / 12)


def lp(x, f):
    return signal.sosfilt(signal.butter(2, f, "lowpass", fs=SR, output="sos"), x)


def hp(x, f):
    return signal.sosfilt(signal.butter(2, f, "highpass", fs=SR, output="sos"), x)


def env(n, a, r):
    t = np.arange(n) / SR
    return np.minimum(t / max(a, 1e-4), 1) * np.exp(-t / r)


def add(*parts):
    """Sum of sounds of different lengths."""
    n = max(len(p) for p in parts)
    return sum(np.pad(p, (0, n - len(p))) for p in parts)


def place(src, at, g=1.0, pan=0.0):
    i = int(at * SR)
    if i >= N:
        return
    end = min(N, i + len(src))
    seg = src[: end - i] * g
    out[i:end, 0] += seg * (1 - max(pan, 0))
    out[i:end, 1] += seg * (1 + min(pan, 0))


def tone(f, dur, a=0.005, r=0.2, wave="sine"):
    t = np.arange(int(dur * SR)) / SR
    ph = 2 * np.pi * f * t
    x = np.sin(ph) if wave == "sine" else signal.sawtooth(ph) * 0.5
    return x * env(len(t), a, r)


def noise(dur, a=0.001, r=0.05):
    n = int(dur * SR)
    return rng.standard_normal(n) * env(n, a, r)


# --- effects ---------------------------------------------------------------
def click(pitch=3000, g=1.0):
    return add(tone(pitch, 0.1, 0.0008, 0.018) * 0.8, lp(noise(0.1, 0.0005, 0.012), 6000) * 0.5) * g


def break_hit():
    return add(click(2200, 1.0), tone(140, 0.3, 0.001, 0.07) * 0.6, hp(noise(0.5, 0.001, 0.09), 1500) * 0.35)


def clack():  # a ball against a ball
    return click(2600 + rng.uniform(-300, 300), 0.5)


def thud():  # a ball drops into the pocket
    return add(tone(95, 0.5, 0.002, 0.12) * 0.9, lp(noise(0.3, 0.002, 0.05), 400) * 0.6)


def tap():
    return add(tone(1500, 0.08, 0.001, 0.015) * 0.5, lp(noise(0.05, 0.0005, 0.01), 5000) * 0.3)


def pop(pitch=700):
    t = np.arange(int(0.18 * SR)) / SR
    return np.sin(2 * np.pi * (pitch + 500 * np.exp(-t * 30)) * t) * env(len(t), 0.002, 0.04) * 0.6


def ding(g=1.0):
    return add(tone(1568, 1.1, 0.002, 0.35), tone(2349, 0.8, 0.002, 0.22) * 0.5) * 0.5 * g


def whoosh(dur=0.6, g=1.0):
    n = int(dur * SR)
    x = noise(dur, 0.2, 0.25)
    filt = signal.sosfilt(signal.butter(2, [300, 4000], "bandpass", fs=SR, output="sos"), x)
    return filt * np.sin(np.linspace(0, np.pi, n)) * 0.5 * g


def boom():
    return add(tone(60, 1.2, 0.005, 0.4) * 0.9, lp(noise(0.8, 0.002, 0.2), 300) * 0.4)


# --- groove ---------------------------------------------------------------
BEAT = 60 / 100
CHORDS = [(57, 60, 64), (53, 57, 60), (48, 52, 55), (55, 59, 62)]  # Am F C G
for bar in range(int(LENGTH / FPS / (BEAT * 4)) + 1):
    t0 = bar * BEAT * 4
    chord = CHORDS[bar % 4]
    for n in chord:
        pad = tone(midi(n), BEAT * 4.2, 0.4, 1.6, "saw")
        place(lp(pad, 1400), t0, 0.05, pan=(n % 3 - 1) * 0.3)
    place(lp(tone(midi(chord[0] - 12), BEAT * 1.5, 0.01, 0.5), 300), t0, 0.28)
    for b in range(4):
        tb = t0 + b * BEAT
        if tb > sec(60):  # the groove starts after the intro hook
            place(lp(tone(55, 0.35, 0.002, 0.09), 200), tb, 0.45)
        place(hp(noise(0.08, 0.001, 0.015), 7000), tb + BEAT / 2, 0.12)

# --- the picture's events ---------------------------------------------------
place(whoosh(0.5), sec(0), 0.5)
place(click(), sec(82), 0.9)                 # cue strikes the ball
place(break_hit(), sec(104), 1.0)            # pyramid breaks
for i in range(6):
    place(clack(), sec(108 + i * 5), 0.35, pan=rng.uniform(-0.5, 0.5))
place(thud(), sec(178), 0.9)                 # drops into the pocket
place(ding(0.5), sec(118), 0.4)              # the question
place(whoosh(0.7), sec(222), 0.6)            # to the bot

CHAT = 230
for lf, kind in [(28, "tap"), (100, "tap"), (158, "tap")]:
    place(tap(), sec(CHAT + lf), 0.9)
for lf in (34, 208):                         # the client's messages
    place(pop(900), sec(CHAT + lf), 0.7)
for lf in (52, 112, 170, 226):               # the bot's messages
    place(pop(620), sec(CHAT + lf), 0.7, pan=-0.2)
place(ding(1.0), sec(CHAT + 290), 0.9)       # the video arrives
place(click(), sec(CHAT + 334), 0.5)         # the shot, inside the video
place(break_hit(), sec(CHAT + 356), 0.5)
place(thud(), sec(CHAT + 422), 0.45)

OUTRO = 650
place(whoosh(0.7), sec(OUTRO - 6), 0.6)
place(boom(), sec(OUTRO + 4), 0.8)           # the logo
place(pop(800), sec(OUTRO + 24), 0.6)
place(ding(1.0), sec(OUTRO + 46), 0.9)       # the button

# fade out, master
fade = np.ones(N)
fade[-int(1.2 * SR):] = np.linspace(1, 0, int(1.2 * SR))
out *= fade[:, None]
peak = np.abs(out).max()
out = out / peak
# loud enough for a social feed: gain, then a soft limiter keeps the peaks in
out = np.tanh(out * 2.6) / np.tanh(2.6) * 0.9
sf.write(sys.argv[1] if len(sys.argv) > 1 else "clips_score.wav", out, SR)
print("score written,", round(N / SR, 1), "s")
