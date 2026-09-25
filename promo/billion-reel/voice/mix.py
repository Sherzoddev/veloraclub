import numpy as np, soundfile as sf
from scipy import signal

SR = 48000
DUR = 142.5
x, sr = sf.read('voice.ogg'); assert sr == SR
# The recording was read along with the video, so it is laid as one piece;
# OFFSET lines its phrases up with the subtitle starts (BILLION_subtitles_uz.srt).
OFFSET = 1.2

# --- voice clean-up: rumble cut, gentle warmth/presence, compression ---
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
v /= np.sqrt((v[np.abs(v) > 1e-4]**2).mean()) / 10**(-19/20)   # speech RMS ≈ -19 dBFS

# --- lay the recording on the video timeline ---
voice = np.zeros(int(DUR*SR))
i = int(OFFSET*SR); voice[i:i+len(v)] = v[:len(voice)-i]
assert OFFSET + len(v)/SR < DUR - 0.5
# where the voice is speaking (50 ms RMS above -45 dBFS) - used for music ducking
w = int(0.05*SR)
env = np.sqrt(np.convolve(voice**2, np.ones(w)/w, 'same'))
active = (env > 10**(-45/20)).astype(float)

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
# peak limiter (5 ms look-ahead) so a few loud syllables don't pull the whole mix down
ceil = 10**(-1/20)
need = np.minimum(1, ceil / (np.abs(mix).max(1) + 1e-12))
la = int(0.005*SR)
from scipy.ndimage import minimum_filter1d
g = minimum_filter1d(need, size=2*la+1)
g = np.minimum(g, signal.lfilter([0.02], [1, -0.98], g))
mix *= np.minimum(g, 1)[:, None]
peak = np.abs(mix).max(); mix *= min(1, 10**(-1/20)/peak)
sf.write('mix.wav', mix.astype(np.float32), SR, subtype='PCM_16')
sf.write('music_only.wav', (music*min(1,10**(-1/20)/peak)).astype(np.float32), SR, subtype='PCM_16')
print("peak", peak, "voice rms dB", 20*np.log10(np.sqrt((voice[active>0]**2).mean())), "music rms dB", 20*np.log10(np.sqrt((music**2).mean())))
