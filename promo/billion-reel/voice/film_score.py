"""Score for the cinematic coupon reel (PromoFilm, 37 s).

Everything is synthesised so there are no licence questions. The hits are laid
on the film's own events (frame / 30): the break at frame 190, a click and a
rising note for each visit the counter adds, the gold sixth, the coupon, the
Telegram ding and the final chord.

    python3 voice/film_score.py out/film_score.wav
"""
import sys

import numpy as np
import soundfile as sf
from scipy import signal

SR = 48000
FPS = 30
DUR = 1110 / FPS
N = int(DUR * SR)
tt = np.arange(N) / SR
rng = np.random.default_rng(6)


def sec(frame):
    return frame / FPS


STRIKE = sec(96)
TICKS = [sec(330 + s + 20) for s in (12, 42, 72, 102, 132, 162)]
TICKET = sec(570)
TICKET_LAND = sec(616)
DING = sec(760 + 44)
FINAL = sec(940)


def midi(n):
    return 440 * 2 ** ((n - 69) / 12)


def lp(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, "lowpass", fs=SR, output="sos"), x)


def hp(x, f, order=2):
    return signal.sosfilt(signal.butter(order, f, "highpass", fs=SR, output="sos"), x)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(signal.butter(order, [lo, hi], "bandpass", fs=SR, output="sos"), x)


def env_ar(n, attack, release):
    u = np.arange(n) / SR
    return (1 - np.exp(-u / max(attack, 1e-4))) * np.exp(-u / release)


def place(dst, src, at, gain=1.0):
    i = int(at * SR)
    if i >= len(dst):
        return
    m = min(len(src), len(dst) - i)
    dst[i:i + m] += gain * src[:m]


def window(a, b, fade_in, fade_out):
    """1 between a and b, with linear fades outside."""
    up = np.clip((tt - (a - fade_in)) / max(fade_in, 1e-3), 0, 1)
    down = np.clip(((b + fade_out) - tt) / max(fade_out, 1e-3), 0, 1)
    return np.minimum(up, down)


def pad(notes, detune=0.1, bright=0.25):
    out = np.zeros(N)
    for n in notes:
        for d in (-detune, 0, detune):
            f = midi(n) * 2 ** (d / 12)
            ph = rng.uniform(0, 2 * np.pi)
            out += np.sin(2 * np.pi * f * tt + ph) + bright * np.sin(4 * np.pi * f * tt + ph)
    return out


def norm(x, db):
    return x / (np.sqrt((x ** 2).mean()) + 1e-12) * 10 ** (db / 20)


L = np.zeros(N)
R = np.zeros(N)


def add(x, db, pan=0.0):
    """Mix a mono layer at an RMS level, panned -1..1."""
    global L, R
    x = norm(x, db)
    L += x * np.sqrt((1 - pan) / 2) * np.sqrt(2)
    R += x * np.sqrt((1 + pan) / 2) * np.sqrt(2)


def add_raw(x, gain, pan=0.0):
    global L, R
    L += gain * x * np.sqrt((1 - pan) / 2) * np.sqrt(2)
    R += gain * x * np.sqrt((1 + pan) / 2) * np.sqrt(2)


# ---------------------------------------------------------------- drones ---
# D minor throughout the dark half, lifting to F major / Bb for the gift.
dark = lp(pad([38, 45, 50], 0.08, 0.4), 420) * window(0.4, TICKET - 0.5, 3.0, 1.2)
add(dark, -27)
sub = np.sin(2 * np.pi * midi(26) * tt) * window(0.0, TICKET - 0.5, 2.0, 1.0)
add(sub, -31)
warm = lp(pad([53, 57, 60, 65], 0.12, 0.3), 1800) * window(TICKET, FINAL - 0.3, 1.0, 0.6)
add(warm, -28, 0.0)
final_pad = lp(pad([46, 53, 58, 62, 65], 0.12, 0.35), 2400) * window(FINAL, DUR - 2.5, 0.05, 2.4)
add(final_pad, -26)

# ------------------------------------------------------------ heartbeat ---
beat = np.zeros(N)
thump = np.sin(2 * np.pi * 52 * np.arange(int(0.25 * SR)) / SR) * env_ar(int(0.25 * SR), 0.003, 0.07)
for b in np.arange(0.9, STRIKE - 0.4, 60 / 64):
    place(beat, thump, b, 1.0)
    place(beat, thump, b + 0.2, 0.6)
add(lp(beat, 200), -30)

# -------------------------------------------------------------- riser ---
rise = np.zeros(N)
a, b = STRIKE - 3.0, STRIKE
m = (tt >= a) & (tt < b)
u = (tt[m] - a) / (b - a)
noise = rng.standard_normal(m.sum())
rise_seg = bp(noise, 400, 6000) * u ** 2.2
# a pitch climbing with it
f = 110 * 2 ** (u * 2.5)
rise_seg += 0.5 * np.sin(2 * np.pi * np.cumsum(f) / SR) * u ** 2
rise[m] = rise_seg
add(rise, -27)

# ---------------------------------------------------------- the break ---
def ball_click(gain=1.0, pitch=3400):
    n = int(0.18 * SR)
    u = np.arange(n) / SR
    click = np.sin(2 * np.pi * pitch * u) * np.exp(-u / 0.012)
    click += 0.6 * np.sin(2 * np.pi * pitch * 1.52 * u) * np.exp(-u / 0.008)
    click += 0.8 * bp(rng.standard_normal(n), 1500, 7000) * np.exp(-u / 0.004)
    return gain * click


hits = np.zeros(N)
boom_n = int(3.5 * SR)
u = np.arange(boom_n) / SR
boom = np.sin(2 * np.pi * (38 + 60 * np.exp(-u / 0.06)) * u) * np.exp(-u / 0.9)
boom += 0.35 * lp(rng.standard_normal(boom_n), 900) * np.exp(-u / 0.25)
place(hits, boom, STRIKE, 1.0)
place(hits, ball_click(1.6, 3100), STRIKE, 1.0)
# the rack scattering, slowed (the picture is in slow motion)
for k, d in enumerate([0.09, 0.2, 0.33, 0.5, 0.71, 0.95, 1.3, 1.7]):
    place(hits, ball_click(0.55 * 0.85 ** k, 2600 + 150 * (k % 3)), STRIKE + d, 1.0)

# ------------------------------------------------- the six visits ---
# a click and a rising pluck per visit, D minor going up; the sixth rings gold
scale = [62, 65, 69, 72, 74]
for i, at in enumerate(TICKS[:5]):
    place(hits, ball_click(0.7, 3000), at - 0.02, 1.0)
    n = int(1.6 * SR)
    uu = np.arange(n) / SR
    tone = np.sin(2 * np.pi * midi(scale[i]) * uu) + 0.3 * np.sin(4 * np.pi * midi(scale[i]) * uu)
    place(hits, 0.35 * tone * env_ar(n, 0.004, 0.45), at, 1.0)
gold_n = int(4.0 * SR)
uu = np.arange(gold_n) / SR
gold = np.zeros(gold_n)
for n_, g_ in [(65, 1.0), (69, 0.8), (72, 0.8), (77, 0.6), (81, 0.4)]:
    gold += g_ * np.sin(2 * np.pi * midi(n_) * uu) * env_ar(gold_n, 0.006, 1.3)
    gold += 0.25 * g_ * np.sin(2 * np.pi * midi(n_) * 2.76 * uu) * env_ar(gold_n, 0.002, 0.4)  # bell partial
place(hits, ball_click(0.9, 3000), TICKS[5] - 0.02, 1.0)
place(hits, 0.45 * gold, TICKS[5], 1.0)
place(hits, 0.5 * boom[: int(1.5 * SR)], TICKS[5], 1.0)

# ------------------------------------------------------- the coupon ---
shimmer = np.zeros(N)
for _ in range(90):
    at = rng.uniform(TICKET - 0.2, TICKET_LAND + 2.5)
    n_ = rng.choice([77, 81, 84, 89, 93, 96])
    k = int(0.5 * SR)
    uu = np.arange(k) / SR
    place(shimmer, np.sin(2 * np.pi * midi(n_) * uu) * env_ar(k, 0.003, 0.12), at, rng.uniform(0.2, 0.6))
add(hp(shimmer, 1200), -33, 0.25)
whoosh = np.zeros(N)
m = (tt >= TICKET) & (tt < TICKET_LAND)
u = (tt[m] - TICKET) / (TICKET_LAND - TICKET)
whoosh[m] = bp(rng.standard_normal(m.sum()), 300, 3000) * np.sin(np.pi * u) ** 2
add(whoosh, -31, -0.2)
place(hits, 0.6 * boom[: int(2.0 * SR)], TICKET_LAND, 1.0)
land_n = int(3.0 * SR)
uu = np.arange(land_n) / SR
chord = sum(np.sin(2 * np.pi * midi(n_) * uu) for n_ in (53, 60, 65, 69, 72)) * env_ar(land_n, 0.01, 1.2)
place(hits, 0.18 * chord, TICKET_LAND, 1.0)

# --------------------------------------------- the bot: pulse + ding ---
pulse = np.zeros(N)
kick_n = int(0.3 * SR)
uu = np.arange(kick_n) / SR
kick = np.sin(2 * np.pi * (45 + 90 * np.exp(-uu / 0.03)) * uu) * np.exp(-uu / 0.16)
step = 60 / 100
for k, at in enumerate(np.arange(sec(760) + 0.2, FINAL - 0.2, step)):
    place(pulse, kick, at, 1.0)
    hat_n = int(0.06 * SR)
    place(pulse, hp(rng.standard_normal(hat_n), 7000) * env_ar(hat_n, 0.001, 0.015), at + step / 2, 0.25)
add_raw(pulse, 0.5)
bass = np.zeros(N)
for k, at in enumerate(np.arange(sec(760) + 0.2, FINAL - 0.2, step / 2)):
    n_ = [41, 41, 46, 48][(k // 4) % 4]
    k_n = int(step / 2 * SR)
    uu = np.arange(k_n) / SR
    place(bass, lp(signal.sawtooth(2 * np.pi * midi(n_) * uu), 500) * env_ar(k_n, 0.005, 0.2), at, 1.0)
add_raw(bass, 0.14)
ding_n = int(1.2 * SR)
uu = np.arange(ding_n) / SR
ding = np.sin(2 * np.pi * 1318.5 * uu) * env_ar(ding_n, 0.002, 0.25)
ding2 = np.sin(2 * np.pi * 1760 * uu) * env_ar(ding_n, 0.002, 0.35)
place(hits, 0.4 * ding, DING, 1.0)
place(hits, 0.4 * ding2, DING + 0.12, 1.0)

# ------------------------------------------------------------ final ---
place(hits, 0.9 * boom, FINAL, 1.0)
fin_n = int(5.5 * SR)
uu = np.arange(fin_n) / SR
fin = sum(g * np.sin(2 * np.pi * midi(n_) * uu) for n_, g in ((46, 1), (58, 0.8), (62, 0.7), (65, 0.7), (70, 0.5), (74, 0.3)))
place(hits, 0.2 * fin * env_ar(fin_n, 0.02, 2.2), FINAL, 1.0)

# ------------------------------------------------- reverb on the hits ---
ir_n = int(2.6 * SR)
ir_t = np.arange(ir_n) / SR
irL = rng.standard_normal(ir_n) * np.exp(-ir_t / 0.55)
irR = rng.standard_normal(ir_n) * np.exp(-ir_t / 0.55)
irL, irR = lp(irL, 5000), lp(irR, 5000)
irL /= np.sqrt((irL ** 2).sum())
irR /= np.sqrt((irR ** 2).sum())
wetL = signal.fftconvolve(hits, irL)[:N]
wetR = signal.fftconvolve(hits, irR)[:N]
L += hits + 0.35 * wetL
R += hits + 0.35 * wetR

# ---------------------------------------------------- master ---
mix = np.stack([L, R], 1)
mix *= np.clip(np.minimum(tt / 0.3, (DUR - tt) / 2.0), 0, 1)[:, None]
# soft clip then normalise to -1 dBFS
mix /= np.abs(mix).max()
mix = np.tanh(1.6 * mix) / np.tanh(1.6)
mix *= 10 ** (-1 / 20) / np.abs(mix).max()
out = sys.argv[1] if len(sys.argv) > 1 else "film_score.wav"
sf.write(out, mix.astype(np.float32), SR, subtype="PCM_16")
print(out, f"{DUR:.2f}s", "rms dB", round(20 * np.log10(np.sqrt((mix ** 2).mean())), 1))
