import React from "react";
import { AbsoluteFill, Img, Sequence, staticFile, useCurrentFrame } from "remotion";
import { C, FONT } from "../theme";
import "../fonts";
import { lerp, rise } from "../ui/anim";
import { Phone } from "../ui/Phone";
import { Backdrop, Line, Subtitles } from "../ui/Scene";
import { Hr, Keyboard, Msg, TgChat } from "../ui/Telegram";
import { Shot, SHOT_LENGTH } from "./Shot";

/* "🎬 Mening zarbalarim" -- the new camera function of the club bot.
   A client names a table and a minute in the bot and gets the video of it.
   Texts of the bot are the real ones (club-bot-service). 30 fps, 27 s. */

export type Lang = "uz" | "ru";

const T = {
  uz: {
    eyebrow: "BILLION · YANGI FUNKSIYA",
    title: ["Mening", "zarbalarim"],
    ask: "Zo'r zarba urdingizmi?",
    askSub: "Kamera uni yozib oldi",
    chatStep: "BILLION · BOT",
    chatTitle: "Zarbangiz — videoda",
    ui: { open: "Klubni ochish", placeholder: "Xabar" },
    keys: [
      ["🎮 Bo'sh joylar", "📅 Band qilish"],
      ["⚪ Raqib topish", "🎬 Mening zarbalarim"],
      ["🎁 Bonuslarim", "👤 Ma'lumotlarim"],
    ],
    mine: "🎬 Mening zarbalarim",
    tables: ["1 Stol", "2 Stol", "3 Stol"],
    pick: "Kamera o'yinni yozib boradi. Stolni tanlang, vaqtni (daqiqani) yozing — men shu daqiqaning videosini yuboraman.",
    when: "Bu qachon bo'lgan? Yozuv 24 soat saqlanadi.",
    days: ["Bugun · 15.11", "Kecha · 14.11"],
    time: "Zarba vaqtini yozing, masalan 21:47.",
    typed: "19:52",
    wait: "🎬 Videoni tayyorlayapman — bir-ikki daqiqada shu yerga yuboraman.",
    caption: "🎬 Sizning zarbangiz\n🎱 1 Stol · 19:52",
    cta: "Botni hoziroq oching",
    outroSub: "Zarbangizni yozib oling — BILLION'da!",
    s1: ["BILLION botida yangi funksiya!", "Kameralar o'yinni to'xtovsiz yozib boradi."],
    s2: [
      "Botda «Mening zarbalarim» tugmasini bosing.",
      "Stol va kunni tanlang.",
      "Zarba vaqtini yozing.",
      "O'sha daqiqaning videosi Telegramingizda!",
    ],
  },
  ru: {
    eyebrow: "BILLION · НОВАЯ ФУНКЦИЯ",
    title: ["Мои", "удары"],
    ask: "Сделали классный удар?",
    askSub: "Камера его записала",
    chatStep: "BILLION · БОТ",
    chatTitle: "Ваш удар — на видео",
    ui: { open: "Открыть клуб", placeholder: "Сообщение" },
    keys: [
      ["🎮 Свободные столы", "📅 Забронировать"],
      ["⚪ Найти соперника", "🎬 Мои удары"],
      ["🎁 Мои бонусы", "👤 Мои данные"],
    ],
    mine: "🎬 Мои удары",
    tables: ["1 Stol", "2 Stol", "3 Stol"],
    pick: "Камера записывает игру. Выберите стол и укажите время (минуту) — и я пришлю видео этой минуты.",
    when: "Когда это было? Запись хранится 24 часа.",
    days: ["Сегодня · 15.11", "Вчера · 14.11"],
    time: "Напишите время удара, например 21:47.",
    typed: "19:52",
    wait: "🎬 Готовлю ролик — пришлю сюда в течение пары минут.",
    caption: "🎬 Ваш удар\n🎱 1 Stol · 19:52",
    cta: "Откройте бота",
    outroSub: "Ваш лучший удар — на видео. BILLION!",
    s1: ["В боте BILLION новая функция!", "Камеры записывают игру без остановки."],
    s2: [
      "Нажмите «Мои удары» в боте.",
      "Выберите стол и день.",
      "Напишите время удара.",
      "Видео этой минуты уже в вашем Telegram!",
    ],
  },
} as const;

export const CL = { INTRO: 0, CHAT: 230, OUTRO: 650, LENGTH: 810 };
const CHAT_LEN = CL.OUTRO - CL.CHAT;
const FADE = 14;

/* ------------------------------------------------------------------ */
/* camera view                                                         */
/* ------------------------------------------------------------------ */
const pad2 = (n: number) => String(n).padStart(2, "0");

/** The shot as the club's camera shows it: REC, camera name, running clock. */
const CameraView: React.FC<{ t: number; small?: boolean }> = ({ t, small = false }) => {
  const sec = 52 * 60 + Math.floor(t / 30) + 1; // 19:52:01 ...
  const clock = `2026-11-15  19:${pad2(Math.floor(sec / 60) % 60)}:${pad2(sec % 60)}`;
  const f = small ? 0.38 : 1;
  const blink = Math.floor(t / 15) % 2 === 0;
  return (
    <div style={{ position: "relative", width: "100%", height: "100%", overflow: "hidden", fontFamily: FONT }}>
      <Shot t={Math.min(Math.max(t, 0), SHOT_LENGTH)} />
      <div
        style={{
          position: "absolute",
          inset: 0,
          background: "radial-gradient(ellipse at 50% 50%, transparent 55%, rgba(0,0,0,.45) 100%)",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 90 * f,
          top: 60 * f,
          display: "flex",
          alignItems: "center",
          gap: 12 * f,
          color: "#fff",
          fontSize: 34 * f,
          fontWeight: 800,
          textShadow: "0 2px 8px rgba(0,0,0,.7)",
        }}
      >
        <span style={{ width: 22 * f, height: 22 * f, borderRadius: "50%", background: "#ff3b30", opacity: blink ? 1 : 0.25 }} />
        REC · 1 STOL
      </div>
      <div
        style={{
          position: "absolute",
          right: 90 * f,
          top: 62 * f,
          color: "#fff",
          fontSize: 30 * f,
          fontWeight: 700,
          fontVariantNumeric: "tabular-nums",
          textShadow: "0 2px 8px rgba(0,0,0,.7)",
        }}
      >
        {clock}
      </div>
    </div>
  );
};

/* ------------------------------------------------------------------ */
/* scene 1: the camera                                                 */
/* ------------------------------------------------------------------ */
const Intro: React.FC<{ lang: Lang }> = ({ lang }) => {
  const frame = useCurrentFrame();
  const x = T[lang];
  const a = rise(frame, 4, 18);
  const panel = rise(frame, 14, 22);
  const q = rise(frame, 118, 16);
  const lines: Line[] = [
    { text: x.s1[0], from: 8, to: 112 },
    { text: x.s1[1], from: 120, to: 226 },
  ];
  return (
    <AbsoluteFill style={{ fontFamily: FONT }}>
      <Backdrop />
      <div style={{ position: "absolute", top: 150, left: 70, right: 70, textAlign: "center", opacity: a, translate: `0 ${(1 - a) * -26}px` }}>
        <div style={{ fontSize: 28, letterSpacing: 7, fontWeight: 800, color: C.green, textShadow: "0 0 18px rgba(57,239,173,.6)" }}>
          {x.eyebrow}
        </div>
        <div style={{ fontSize: 118, fontWeight: 900, color: C.text, letterSpacing: -3, lineHeight: 1.0, marginTop: 14 }}>
          🎬 {x.title[0]}
          <br />
          {x.title[1]}
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          left: 60,
          top: 620,
          width: 960,
          height: 540,
          borderRadius: 34,
          overflow: "hidden",
          boxShadow: "0 50px 130px rgba(0,0,0,.7), 0 0 0 3px rgba(255,255,255,.08), 0 0 140px rgba(57,239,173,.18)",
          opacity: panel,
          scale: String(0.94 + 0.06 * panel),
        }}
      >
        <CameraView t={frame - 30} />
      </div>
      <div
        style={{
          position: "absolute",
          top: 1210,
          left: 70,
          right: 70,
          textAlign: "center",
          opacity: q,
          translate: `0 ${(1 - q) * 24}px`,
        }}
      >
        <div style={{ fontSize: 58, fontWeight: 900, color: C.text, letterSpacing: -1 }}>{x.ask}</div>
        <div style={{ fontSize: 44, fontWeight: 700, color: C.gold, marginTop: 8 }}>🎥 {x.askSub}</div>
      </div>
      <Subtitles lines={lines} />
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------------ */
/* scene 2: the bot                                                    */
/* ------------------------------------------------------------------ */
const VideoBubble: React.FC<{ at: number; playAt: number; lang: Lang }> = ({ at, playAt, lang }) => {
  const frame = useCurrentFrame();
  const x = T[lang];
  const playing = frame >= playAt;
  const t = Math.max(0, frame - playAt);
  const btn = lerp(frame, [playAt - 4, playAt + 6], [1, 0]);
  return (
    <Msg at={at} time="19:54">
      <div style={{ margin: "-7px -10px 6px", width: 320, height: 180, position: "relative", borderRadius: "13px 13px 0 0", overflow: "hidden", background: "#0b3a2c" }}>
        <CameraView t={playing ? t + 40 : 40} small />
        <div
          style={{
            position: "absolute",
            right: 8,
            bottom: 8,
            background: "rgba(0,0,0,.6)",
            color: "#fff",
            fontSize: 12,
            fontWeight: 700,
            padding: "2px 7px",
            borderRadius: 10,
          }}
        >
          1:00
        </div>
        <div
          style={{
            position: "absolute",
            left: "50%",
            top: "50%",
            width: 52,
            height: 52,
            marginLeft: -26,
            marginTop: -26,
            borderRadius: "50%",
            background: "rgba(0,0,0,.55)",
            color: "#fff",
            fontSize: 24,
            display: "grid",
            placeItems: "center",
            opacity: btn,
            scale: String(0.9 + 0.1 * btn),
          }}
        >
          ▶
        </div>
      </div>
      <div style={{ fontWeight: 600 }}>{x.caption}</div>
    </Msg>
  );
};

const Chat: React.FC<{ lang: Lang }> = ({ lang }) => {
  const frame = useCurrentFrame();
  const x = T[lang];
  const p = rise(frame, 0, 20);
  const keyboards: Keyboard[] = [
    {
      at: 0,
      rows: x.keys.map((row) => row.map((label) => ({ label, tapAt: label === x.mine ? 28 : undefined }))),
    },
  ];
  const lines: Line[] = [
    { text: x.s2[0], from: 6, to: 98 },
    { text: x.s2[1], from: 102, to: 196 },
    { text: x.s2[2], from: 200, to: 286 },
    { text: x.s2[3], from: 292, to: CHAT_LEN - 6 },
  ];
  return (
    <AbsoluteFill style={{ fontFamily: FONT }}>
      <Backdrop />
      <div style={{ position: "absolute", top: 170, left: 90, right: 90, textAlign: "center", opacity: p, translate: `0 ${(1 - p) * -24}px` }}>
        <div style={{ fontSize: 26, letterSpacing: 7, fontWeight: 800, color: C.green, textShadow: "0 0 18px rgba(57,239,173,.6)" }}>
          {x.chatStep}
        </div>
        <div style={{ fontSize: 76, fontWeight: 900, color: C.text, letterSpacing: -2, marginTop: 8, lineHeight: 1.02 }}>{x.chatTitle}</div>
      </div>
      <div style={{ position: "absolute", inset: 0, opacity: p, translate: `0 ${(1 - p) * 90}px` }}>
        <Phone>
          <TgChat keyboards={keyboards} ui={x.ui}>
            <Msg at={34} from="user" time="19:52">
              {x.mine}
            </Msg>
            <Msg at={52} time="19:52" buttons={[x.tables.map((label, i) => ({ label, tapAt: i === 0 ? 100 : undefined }))]}>
              <b>🎬 {x.mine.slice(3)}</b>
              {"\n"}
              <Hr />
              {"\n\n"}
              {x.pick}
            </Msg>
            <Msg at={112} time="19:53" buttons={[x.days.map((label, i) => ({ label, tapAt: i === 0 ? 158 : undefined }))]}>
              <b>🎬 1 Stol</b>
              {"\n\n"}
              {x.when}
            </Msg>
            <Msg at={170} time="19:53">
              <b>🎬 1 Stol · 15.11.2026</b>
              {"\n\n"}
              {x.time}
            </Msg>
            <Msg at={208} from="user" time="19:53">
              {x.typed}
            </Msg>
            <Msg at={226} time="19:53">
              {x.wait}
            </Msg>
            <VideoBubble at={290} playAt={322} lang={lang} />
          </TgChat>
        </Phone>
      </div>
      <Subtitles lines={lines} />
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------------ */
/* scene 3: call to action                                             */
/* ------------------------------------------------------------------ */
const Outro: React.FC<{ lang: Lang }> = ({ lang }) => {
  const frame = useCurrentFrame();
  const x = T[lang];
  const w = rise(frame, 4, 18);
  const b = rise(frame, 24, 16);
  const cta = rise(frame, 46, 16);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <Backdrop />
      <Img
        src={staticFile("logo.png")}
        style={{ position: "absolute", top: 330, width: 760, mixBlendMode: "lighten", opacity: w, translate: `0 ${(1 - w) * 30}px` }}
      />
      <div style={{ position: "absolute", top: 560, opacity: b, translate: `0 ${(1 - b) * 24}px`, textAlign: "center", color: C.text }}>
        <div style={{ fontSize: 40, color: C.muted, fontWeight: 600 }}>Telegram bot</div>
        <div style={{ fontSize: 66, fontWeight: 900, color: C.green, marginTop: 10, textShadow: "0 0 30px rgba(57,239,173,.5)" }}>
          @billionbiliard_bot
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 820,
          opacity: cta,
          translate: `0 ${(1 - cta) * 30}px`,
          scale: String(1 + 0.03 * Math.sin(frame / 6) * cta),
          padding: "34px 64px",
          borderRadius: 40,
          background: "linear-gradient(135deg,#5affc1,#18d993)",
          color: "#022d20",
          fontSize: 54,
          fontWeight: 900,
          boxShadow: "0 30px 90px rgba(21,222,147,.35)",
        }}
      >
        {x.cta}
      </div>
      <div style={{ position: "absolute", top: 1010, opacity: cta, textAlign: "center", fontSize: 38, lineHeight: 1.5, color: "#c7d0cd", fontWeight: 600 }}>
        📍 Ma'rifat ko'chasi 122, Angren
        <br />
        📞 +998 95 969 55 77
      </div>
      <Subtitles lines={[{ text: x.outroSub, from: 20, to: CL.LENGTH - CL.OUTRO - 6 }]} />
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------------ */
export const PromoClips: React.FC<{ lang?: Lang }> = ({ lang = "uz" }) => {
  const frame = useCurrentFrame();
  const fade = (from: number, to: number) =>
    Math.min(lerp(frame, [from, from + FADE], [0, 1]), lerp(frame, [to - FADE, to], [1, 0]));
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <Sequence from={CL.INTRO} durationInFrames={CL.CHAT - CL.INTRO + FADE} layout="none">
        <div style={{ position: "absolute", inset: 0, opacity: lerp(frame, [CL.CHAT, CL.CHAT + FADE], [1, 0]) }}>
          <Intro lang={lang} />
        </div>
      </Sequence>
      <Sequence from={CL.CHAT} durationInFrames={CL.OUTRO - CL.CHAT + FADE} layout="none">
        <div style={{ position: "absolute", inset: 0, opacity: fade(CL.CHAT, CL.OUTRO + FADE) }}>
          <Chat lang={lang} />
        </div>
      </Sequence>
      <Sequence from={CL.OUTRO} durationInFrames={CL.LENGTH - CL.OUTRO} layout="none">
        <div style={{ position: "absolute", inset: 0, opacity: lerp(frame, [CL.OUTRO, CL.OUTRO + FADE], [0, 1]) }}>
          <Outro lang={lang} />
        </div>
      </Sequence>
    </AbsoluteFill>
  );
};
