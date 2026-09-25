# BILLION — Instagram reel

Vertical 1080×1920 reel (2:22) about the club's Telegram bot and Mini App,
Uzbek subtitles. Built with [Remotion](https://www.remotion.dev).

| Path | What |
|---|---|
| `src/` | Remotion scenes (`Reel.tsx` = scene order and lengths) |
| `public/screens/` | Real Mini App screens (captured by `capture/`) |
| `public/logo*.{png,jpg}`, `public/fonts/` | BILLION logo, Inter font |
| `capture/capture.mjs` | Opens `miniapp/client-webapp.html` in Chromium with BILLION's club data and a demo client, saves the screens |
| `BILLION_subtitles_uz.srt` | Subtitles with exact timings |
| `BILLION_ovoz_ssenariy.txt` | Voice-over script with timings |
| `voice/voice.wav` | Recorded voice-over (27 lines, one file) |
| `voice/mix.py` | Cuts the recording into lines, places each on its subtitle, adds generated background music → `voice/mix.wav` |

## Render

```bash
npm ci
npx remotion render VeloraReel out/reel.mp4 --codec=h264 --crf=16
# (in a sandbox without Chrome: --browser-executable=/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell)

pip install numpy scipy soundfile
(cd voice && python3 mix.py)
npx remotion ffmpeg -i out/reel.mp4 -i voice/mix.wav -map 0:v -map 1:a \
  -c:v libx264 -profile:v main -pix_fmt yuv420p -crf 22 -c:a aac -b:a 192k -shortest \
  -movflags +faststart out/BILLION_reel.mp4
```

`mix.py`'s segment list matches the current `voice.wav`; a new recording
needs its silence-detected segments (and the two lines split by a pause)
updated.

## Next: natural voice with Navoiy TTS

Planned: local Uzbek TTS with Navoiy TTS (`aisha-org/navoiy-tts`,
`emotion_600h_joint.pt`) on CosyVoice2-0.5B
(CosyVoice at `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`), generating each
line of `BILLION_ovoz_ssenariy.txt` separately. Needs network access to
`huggingface.co`, `cdn-lfs.huggingface.co` and `cas-bridge.xethub.hf.co`.
