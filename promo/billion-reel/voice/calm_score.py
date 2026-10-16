"""Beat for the calm reel (PromoCalm, 30 s, 120 BPM, minor, deeper).

Synthesised, so no licence questions. The groove starts with the ring of
slots; every hit sits on an event of the picture (frame / 30): the balls
landing, a click for each visit, the gold sixth, the flash, the phone ding,
the logo.

    python3 voice/motion_score.py out/motion_score.wav
"""
import sys

import numpy as np
import soundfile as sf
from scipy import signal

SR = 48000
FPS = 30
LENGTH = 690
DUR = LENGTH / FPS
N = int(DUR * SR)
tt = np.arange(N) / SR
rng = np.random.default_rng(12)


def sec(f):
    return f / FPS


RING, GOLD, FLASH, PHONE, TERMS, END = 60, 200, 250, 360, 476, 566
DROPS = [0.45, 0.58, 0.7, 0.8, 0.95, 1.1, 1.2]
ARRIVALS = [sec(85 + i * 23) for i in range(6)]
BEAT = 60 / 124


def midi(n):
    return 440 * 2 ** ((n - 69) / 12)


def lp(x, f):
    return signal.sosfilt(signal.butter(2, f, "lowpass", fs=SR, output="sos"), x)


def hp(x, f):
    return signal.sosfilt(signal.butter(2, f, "highpass", fs=SR, output="sos"), x)


def bp(x, lo, hi):
    return signal.sosfilt(signal.butter(2, [lo, hi], "bandpass", fs=SR, output="sos"), x)


def env(n, a, r):
    u = np.arange(n) / SR
    return (1 - np.exp(-u / max(a, 1e-4))) * np.exp(-u / r)


def place(dst, src, at, g=1.0):
    i = int(at * SR)
    if i >= len(dst) or i < 0:
        return
    m = min(len(src), len(dst) - i)
    dst[i:i + m] += g * src[:m]


def gate(a, b, fi=0.05, fo=0.3):
    return np.clip(np.minimum((tt - a) / fi + 1, (b - tt) / fo), 0, 1)


L = np.zeros(N)
R = np.zeros(N)


def mix(x, g, pan=0.0):
    global L, R
    L += g * x * (1 - max(0, pan))
    R += g * x * (1 + min(0, pan))


# --- drums -------------------------------------------------------------
def kick():
    n = int(0.35 * SR)
    u = np.arange(n) / SR
    return np.sin(2 * np.pi * (48 + 110 * np.exp(-u / 0.025)) * u) * np.exp(-u / 0.18)


def clap():
    n = int(0.25 * SR)
    u = np.arange(n) / SR
    x = bp(rng.standard_normal(n), 900, 4000)
    e = np.exp(-u / 0.06) * (1 + 0.6 * (np.sin(2 * np.pi * 90 * u) > 0.6))
    return x * e


def hat(open_=False):
    n = int((0.18 if open_ else 0.05) * SR)
    return hp(rng.standard_normal(n), 7500) * env(n, 0.0005, 0.06 if open_ else 0.012)


drums = np.zeros(N)
groove_on = [(sec(6), sec(GOLD) - BEAT), (sec(FLASH), sec(LENGTH) - 1.6)]
for a, b in groove_on:
    for i, t in enumerate(np.arange(a, b, BEAT)):
        place(drums, kick(), t, 1.0)
        if i % 2 == 1:
            place(drums, clap(), t, 0.5)
        place(drums, hat(), t + BEAT / 2, 0.35)
        place(drums, hat(i % 4 == 3), t + BEAT / 4 * 3, 0.18)
mix(drums, 0.55)

# --- bass and chords (C - G - Am - F) ----------------------------------
chords = [[45, 48, 52], [41, 45, 48], [48, 52, 55], [43, 47, 50]]
bass = np.zeros(N)
stabs = np.zeros(N)
bar = 4 * BEAT
start = sec(RING)
for k_, t in enumerate(np.arange(start, DUR - 2, bar)):
    ch = chords[k_ % 4]
    for j in range(8):
        tb = t + j * BEAT / 2
        n = int(BEAT / 2 * SR)
        u = np.arange(n) / SR
        note = ch[0] - 12 + (12 if j % 4 == 3 else 0)
        saw = signal.sawtooth(2 * np.pi * midi(note) * u)
        place(bass, lp(saw, 600) * env(n, 0.004, 0.16), tb, 1.0)
    for off in (0, 1.5 * BEAT, 2.5 * BEAT):
        n = int(0.3 * SR)
        u = np.arange(n) / SR
        st = sum(np.sin(2 * np.pi * midi(nn + 12) * u) + 0.3 * np.sin(4 * np.pi * midi(nn + 12) * u) for nn in ch)
        place(stabs, st * env(n, 0.003, 0.12), t + off, 1.0)
# silence the groove under the gold moment and the flash build
duck = 1 - gate(sec(GOLD) - BEAT, sec(FLASH), 0.1, 0.05) * 0.85
mix(lp(bass, 900) * duck, 0.16)
mix(lp(stabs, 3500) * duck, 0.05, 0.2)

# --- intro pad and risers ----------------------------------------------
pad = np.zeros(N)
for nn in (45, 52, 57, 60):
    for d in (-0.08, 0.08):
        pad += np.sin(2 * np.pi * midi(nn) * 2 ** (d / 12) * tt)
pad = lp(pad, 1400) * (gate(0.0, sec(RING) + 0.2, 0.6, 0.2) + 0.6 * gate(sec(GOLD), sec(FLASH), 0.05, 0.1))
mix(pad, 0.02)


def riser(a, b, g):
    x = np.zeros(N)
    m = (tt >= a) & (tt < b)
    u = (tt[m] - a) / (b - a)
    x[m] = bp(rng.standard_normal(m.sum()), 500, 8000) * u ** 2.5
    x[m] += 0.4 * np.sin(2 * np.pi * np.cumsum(200 * 2 ** (u * 3)) / SR) * u ** 2
    mix(x, g)


riser(sec(RING) - 1.4, sec(RING), 0.10)
riser(sec(GOLD) - 1.6, sec(GOLD), 0.10)
riser(sec(GOLD) + 0.6, sec(FLASH), 0.13)
riser(sec(END) - 1.0, sec(END), 0.08)

# --- hits ----------------------------------------------------------------
hits = np.zeros(N)


def boom(n_sec=2.5):
    n = int(n_sec * SR)
    u = np.arange(n) / SR
    return np.sin(2 * np.pi * (36 + 70 * np.exp(-u / 0.05)) * u) * np.exp(-u / 0.7) + 0.3 * lp(rng.standard_normal(n), 800) * np.exp(-u / 0.2)


def click(g=1.0, pitch=3300):
    n = int(0.15 * SR)
    u = np.arange(n) / SR
    return g * (np.sin(2 * np.pi * pitch * u) * np.exp(-u / 0.01) + 0.7 * bp(rng.standard_normal(n), 1500, 7000) * np.exp(-u / 0.004))


def bell(notes, dur=2.5, g=1.0):
    n = int(dur * SR)
    u = np.arange(n) / SR
    x = np.zeros(n)
    for nn in notes:
        x += np.sin(2 * np.pi * midi(nn) * u) * env(n, 0.003, 0.8) + 0.3 * np.sin(2 * np.pi * midi(nn) * 2.76 * u) * env(n, 0.002, 0.25)
    return g * x


def whoosh(at, dur=0.6, g=1.0):
    n = int(dur * SR)
    u = np.arange(n) / n
    place(hits, g * bp(rng.standard_normal(n), 300, 4000) * np.sin(np.pi * u) ** 2, at - dur * 0.7)


for t in DROPS:
    place(hits, click(0.7, 2900), t)
place(hits, boom(1.5), sec(RING), 0.7)
whoosh(sec(RING), 0.7, 0.6)
scale = [57, 60, 64, 67, 69]
for i, t in enumerate(ARRIVALS[:5]):
    place(hits, click(0.8), t)
    place(hits, bell([scale[i] + 12], 1.2, 0.25), t)
place(hits, boom(), sec(GOLD), 1.0)
place(hits, bell([67, 72, 76, 79, 84], 3.0, 0.3), sec(GOLD))
place(hits, boom(), sec(FLASH), 1.0)
place(hits, bell([72, 76, 79, 84, 88], 3.0, 0.28), sec(FLASH) + 0.05)
for i in range(40):  # sparkle of the coupon
    at = sec(FLASH) + rng.uniform(0.05, 2.5)
    place(hits, bell([int(rng.choice([82, 86, 89, 94]))], 0.4, 0.05), at)
whoosh(sec(PHONE) + 0.6, 0.8, 0.7)
whoosh(sec(PHONE + 36), 0.5, 0.5)
n = int(1.0 * SR)
u = np.arange(n) / SR
place(hits, 0.35 * np.sin(2 * np.pi * 1318.5 * u) * env(n, 0.002, 0.22), sec(PHONE + 44))
place(hits, 0.35 * np.sin(2 * np.pi * 1760 * u) * env(n, 0.002, 0.3), sec(PHONE + 44) + 0.12)
whoosh(sec(TERMS) + 0.3, 0.6, 0.6)
for i in range(4):
    place(hits, click(0.5, 2400), sec(TERMS + 12 + i * 9))
place(hits, boom(3.0), sec(END), 0.9)
place(hits, bell([60, 67, 72, 76, 79], 4.0, 0.28), sec(END))

# small room on the hits
ir_n = int(1.8 * SR)
ir = lp(rng.standard_normal(ir_n) * np.exp(-np.arange(ir_n) / SR / 0.4), 5000)
ir /= np.sqrt((ir ** 2).sum())
wet = signal.fftconvolve(hits, ir)[:N]
mix(hits, 0.8)
mix(wet, 0.25)

out = np.stack([L, R], 1)
out *= np.clip(np.minimum(tt / 0.05, (DUR - tt) / 2.0), 0, 1)[:, None]
out /= np.abs(out).max()
out = np.tanh(1.8 * out) / np.tanh(1.8)
out *= 10 ** (-1 / 20) / np.abs(out).max()
dst = sys.argv[1] if len(sys.argv) > 1 else "calm_score.wav"
sf.write(dst, out.astype(np.float32), SR, subtype="PCM_16")
print(dst, f"{DUR:.1f}s", "rms dB", round(20 * np.log10(np.sqrt((out ** 2).mean())), 1))
