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
| `voice/voice.ogg` | Recorded voice-over, read along with the video (one take) |
| `voice/mix.py` | Cleans up the recording, lays it on the timeline at `OFFSET`, adds generated background music ducked under the voice → `voice/mix.wav` |

## Render

```bash
npm ci
npx remotion render VeloraReel out/reel.mp4 --codec=h264 --crf=16
# no subtitles, no sound:
npx remotion render VeloraReelClean out/reel_clean.mp4 --codec=h264 --crf=16 --muted
# (in a sandbox without Chrome: --browser-executable=/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell)

pip install numpy scipy soundfile
(cd voice && python3 mix.py)
npx remotion ffmpeg -i out/reel.mp4 -i voice/mix.wav -map 0:v -map 1:a \
  -c:v libx264 -profile:v main -pix_fmt yuv420p -crf 22 -c:a aac -b:a 192k -shortest \
  -movflags +faststart out/BILLION_reel.mp4
```

`OFFSET` (1.2 s) lines the current take up with the subtitle starts; a new
take read along with the video only needs that number re-checked.

## Next: natural voice with Navoiy TTS

Planned: local Uzbek TTS with Navoiy TTS (`aisha-org/navoiy-tts`,
`emotion_600h_joint.pt`) on CosyVoice2-0.5B
(CosyVoice at `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`), generating each
line of `BILLION_ovoz_ssenariy.txt` separately. Needs network access to
`huggingface.co`, `cdn-lfs.huggingface.co` and `cas-bridge.xethub.hf.co`.


## «Mening zarbalarim / Мои удары» (PromoClipsUz, PromoClipsRu)

A 27 s vertical film about the bot's camera function: the camera view with the
shot, the real bot dialog (table, day, time, the video arrives), the logo and
the call to action. 2D (SVG + the Telegram UI of the other reels), no 3D.
Sources: `src/clips/Clips.tsx` (scenes, texts of both languages), `src/clips/Shot.tsx`
(the billiard shot), `voice/clips_score.py` (synthesised sound on the picture's
events), `PROMO_zarbalar_ssenariy.txt` (texts, timings, caption).

```bash
npx remotion render PromoClipsUz out/clips_uz_silent.mp4 --codec=h264 --crf=18 --muted
npx remotion render PromoClipsRu out/clips_ru_silent.mp4 --codec=h264 --crf=18 --muted
pip install numpy scipy soundfile
python3 voice/clips_score.py out/clips_score.wav
npx remotion ffmpeg -i out/clips_uz_silent.mp4 -i out/clips_score.wav -map 0:v -map 1:a \
  -c:v libx264 -profile:v main -pix_fmt yuv420p -crf 22 -c:a aac -b:a 192k -shortest \
  -movflags +faststart out/BILLION_mening_zarbalarim_uz.mp4
```
