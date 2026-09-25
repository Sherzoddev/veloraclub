import numpy as np, soundfile as sf
from scipy import signal

SR = 48000
DUR = 142.5
x, sr = sf.read('voice.wav'); assert sr == SR

# --- phrase segments (from silence detection), grouped per subtitle line ---
segs = [(0.06,2.56),(3.44,6.72),(7.56,10.88),(11.7,14.06),(14.92,18.82),(19.66,22.96),(23.82,26.72),
 (27.56,29.74),(30.6,32.9),(33.78,36.54),(37.38,39.96),(40.8,44.2),(45.04,48.64),(49.5,52.78),
 (53.66,54.58),(55.42,56.8),(57.64,61.64),(62.52,65.76),(66.62,69.62),(70.48,73.0),(73.84,76.72),
 (77.58,79.94),(80.78,83.3),(84.14,85.82),(86.68,88.92),(89.78,92.44),(93.28,96.6),(97.46,100.5),(101.34,102.86)]
groups = [[i] for i in range(14)] + [[14,15]] + [[i] for i in range(16,23)] + [[23,24]] + [[i] for i in range(25,29)]
assert len(groups) == 27
# subtitle start times of the video (s), from BILLION_subtitles_uz.srt
starts = [1.00,4.93,9.80,15.27,20.13,24.93,31.80,37.60,42.13,47.13,52.13,56.93,61.33,65.80,71.27,75.47,
          81.13,86.80,92.60,97.13,103.47,107.93,114.80,120.27,125.13,130.60,136.50]

# --- voice clean-up: rumble cut, gentle warmth/presence, compression, a touch of room ---
def biquad_peak(f0, gain_db, q):
    A = 10**(gain_db/40); w = 2*np.pi*f0/SR; a = np.sin(w)/(2*q)
    b = [1+a*A, -2*np.cos(w), 1-a*A]; aa = [1+a/A, -2*np.cos(w), 1-a/A]
    return np.array(b)/aa[0], np.array(aa)/aa[0]
v = signal.sosfilt(signal.butter(2, 85, 'highpass', fs=SR, output='sos'), x)
for f0, g, q in [(220, 1.5, 0.8), (3200, 1.5, 1.0), (7500, -2.0, 2.0)]:
    b, a = biquad_peak(f0, g, q); v = signal.lfilter(b, a, v)
# RMS compressor 3:1 above -24 dBFS, 10 ms attack / 150 ms release
env = np.sqrt(signal.lfilter([0.002], [1, -0.998], v**2) + 1e-12)
lvl = 20*np.log10(env)
over = np.maximum(lvl + 24, 0)
gain_db = -over * (1 - 1/3)
gain = 10**(gain_db/20)
gain = signal.lfilter([0.01], [1, -0.99], gain)
v = v * gain
# small room: short decaying noise IR, 7% wet
rng = np.random.default_rng(7)
t = np.arange(int(0.35*SR))/SR
ir = rng.standard_normal(len(t)) * np.exp(-t/0.07)
ir = signal.sosfilt(signal.butter(2, [300, 5000], 'bandpass', fs=SR, output='sos'), ir)
ir /= np.sqrt((ir**2).sum())
wet = signal.fftconvolve(v, ir)[:len(v)]
v = v + 0.07 * wet * (np.sqrt((v**2).mean()) / (np.sqrt((wet**2).mean()) + 1e-12))
v /= np.sqrt((v[np.abs(v) > 1e-4]**2).mean()) / 10**(-19/20)   # speech RMS ≈ -19 dBFS

# --- lay phrases on the video timeline ---
voice = np.zeros(int(DUR*SR))
active = np.zeros_like(voice)
prev_end = 0.0
for g, st in zip(groups, starts):
    a, b = segs[g[0]][0] - 0.03, segs[g[-1]][1] + 0.12
    clip = v[int(a*SR):int(b*SR)].copy()
    fade = int(0.012*SR); clip[:fade] *= np.linspace(0, 1, fade); clip[-fade:] *= np.linspace(1, 0, fade)
    at = max(st + 0.15, prev_end + 0.25)
    i = int(at*SR); voice[i:i+len(clip)] += clip; active[i:i+len(clip)] = 1
    prev_end = at + len(clip)/SR
    print(f"line at {at:6.2f}s  len {len(clip)/SR:4.2f}s")
assert prev_end < DUR - 0.5

# --- background music: calm A-minor pad + soft arpeggio + sub, 84 BPM ---
BPM = 84; beat = 60/BPM
tt = np.arange(int(DUR*SR))/SR
def midi(n): return 440*2**((n-69)/12)
chords = [[57,60,64],[53,57,60],[48,52,55],[55,59,62]]  # Am F C G
bars_per_chord = 2
chord_len = 4*beat*bars_per_chord
music = np.zeros((len(tt), 2))
pad = np.zeros(len(tt)); sub = np.zeros(len(tt)); arp = np.zeros(len(tt))
n_chords = int(np.ceil(DUR/chord_len))
for k in range(n_chords):
    notes = chords[k % 4]
    s0 = k*chord_len; s1 = min(DUR, s0 + chord_len)
    i0, i1 = int(s0*SR), int(s1*SR); seg = tt[i0:i1] - s0
    envp = np.minimum(1, seg/1.2) * np.minimum(1, (chord_len - seg)/0.8)
    for n in notes:
        for det in (-0.12, 0.12):
            f = midi(n+12) * 2**(det/12)
            pad[i0:i1] += envp * (np.sin(2*np.pi*f*seg) + 0.3*np.sin(2*np.pi*2*f*seg) + 0.12*np.sin(2*np.pi*3*f*seg))
    sub[i0:i1] += envp * np.sin(2*np.pi*midi(notes[0]-12)*seg)
    # eighth-note arpeggio through the chord, an octave up
    order = [0,1,2,1,2,1,0,1]
    step = beat/2
    for j in range(int(chord_len/step)):
        ts = s0 + j*step
        if ts >= DUR: break
        n = notes[order[j % 8]] + 24
        a0 = int(ts*SR); a1 = min(len(tt), a0 + int(1.2*SR))
        u = tt[a0:a1] - ts
        arp[a0:a1] += np.exp(-u/0.35) * np.sin(2*np.pi*midi(n)*u) * (1 - np.exp(-u/0.004))
pad = signal.sosfilt(signal.butter(2, 1400, 'lowpass', fs=SR, output='sos'), pad)
arp = signal.sosfilt(signal.butter(2, 3500, 'lowpass', fs=SR, output='sos'), arp)
def norm(s, db): return s / (np.sqrt((s**2).mean()) + 1e-12) * 10**(db/20)
pad, sub, arp = norm(pad, -30), norm(sub, -33), norm(arp, -34)
# gentle stereo: arp delayed a little on the right, pad slightly wide
dl = int(0.012*SR)
L = pad + sub + arp
R = np.roll(pad, int(0.007*SR)) + sub + np.roll(arp, dl)
music = np.stack([L, R], 1)
fade_in, fade_out = 2.0, 3.5
music *= np.clip(np.minimum(tt/fade_in, (DUR - tt)/fade_out), 0, 1)[:, None]
# ducking: music drops ~8 dB under the voice, smoothed
duck = 1 - 0.6 * signal.lfilter([0.0006], [1, -0.9994], active)
duck = np.clip(duck, 0.4, 1)
music *= duck[:, None]

mix = music + voice[:, None]
peak = np.abs(mix).max(); mix *= min(1, 10**(-1/20)/peak)
sf.write('mix.wav', mix.astype(np.float32), SR, subtype='PCM_16')
sf.write('music_only.wav', (music*min(1,10**(-1/20)/peak)).astype(np.float32), SR, subtype='PCM_16')
print("peak", peak, "voice rms dB", 20*np.log10(np.sqrt((voice[active>0]**2).mean())), "music rms dB", 20*np.log10(np.sqrt((music**2).mean())))
