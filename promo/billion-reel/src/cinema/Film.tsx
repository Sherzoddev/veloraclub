import React from "react";
import { AbsoluteFill, Easing, Img, interpolate, random, staticFile, useCurrentFrame } from "remotion";
import { ThreeCanvas } from "@remotion/three";
import * as THREE from "three";
import { useThree } from "@react-three/fiber";
import { BreakShot, Environment, FPS, Lamp, SixBalls, Ticket, Table } from "./Stage";
import { TABLE } from "./physics";
import { C, FONT } from "../theme";
import { Subtitles, type Line } from "../ui/Scene";
import "../fonts";

/* The "6 visits = 1 free hour" promo as a short film: one 3D billiard table
   under a lamp, shot by a moving camera, with Uzbek titles. 30 fps. */

type V3 = [number, number, number];
type Key = { f: number; p: V3; look: V3; fov?: number };

export const FILM = {
  A: 0, // lamp on, behind the cue ball
  B: 150, // the break, slow motion
  C: 330, // six visits
  D: 570, // the gold coupon
  E: 760, // the coupon in the bot
  F: 940, // logo and call to action
  END: 1110,
};
const STRIKE = 190;
const H = TABLE.height;
const ease = Easing.bezier(0.45, 0, 0.25, 1);
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** Camera keys. Two keys a frame apart make a cut (hidden in a dip to black). */
const KEYS: Key[] = [
  { f: 0, p: [-1.45, H + 0.16, 0.25], look: [0.2, H + 0.03, 0], fov: 30 },
  { f: 150, p: [-0.98, H + 0.085, 0.06], look: [0.2, H + 0.035, 0], fov: 26 },
  { f: 190, p: [-0.7, H + 0.12, 0.36], look: [0.2, H + 0.04, 0], fov: 26 },
  { f: 329, p: [0.2, H + 0.22, 0.72], look: [0.45, H + 0.03, 0.05], fov: 32 },
  // six visits: from the end of the row, so the line runs up the frame and
  // the gold sixth lands nearest
  { f: 330, p: [1.3, H + 0.62, 0.1], look: [0.02, H + 0.0, -0.01], fov: 34 },
  { f: 569, p: [1.16, H + 0.48, -0.06], look: [0.04, H + 0.0, 0.0], fov: 34 },
  // the coupon: front and a little above, slow push in
  { f: 570, p: [0.0, H + 0.5, 1.8], look: [0.0, H + 0.31, 0.0], fov: 36 },
  { f: 759, p: [0.03, H + 0.44, 1.58], look: [0.0, H + 0.31, 0.0], fov: 35 },
  // the bot card over a soft orbit of the table
  { f: 760, p: [-0.9, H + 0.9, 1.2], look: [0.0, H, 0.0], fov: 38 },
  { f: 939, p: [-0.3, H + 1.0, 1.35], look: [0.0, H, 0.0], fov: 38 },
  // final: high over the table, slowly turning
  { f: 940, p: [0.0, H + 1.65, 1.05], look: [0.0, H, 0.0], fov: 40 },
  { f: 1110, p: [0.35, H + 1.55, 0.9], look: [0.0, H, 0.0], fov: 38 },
];

function cameraAt(frame: number) {
  let i = 0;
  while (i < KEYS.length - 2 && frame >= KEYS[i + 1].f) i++;
  const a = KEYS[i];
  const b = KEYS[i + 1];
  const t = b.f === a.f ? 1 : ease(Math.max(0, Math.min(1, (frame - a.f) / (b.f - a.f))));
  const mix = (x: V3, y: V3): V3 => [x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t];
  return { p: mix(a.p, b.p), look: mix(a.look, b.look), fov: (a.fov ?? 32) + ((b.fov ?? 32) - (a.fov ?? 32)) * t };
}

const Rig: React.FC<{ frame: number }> = ({ frame }) => {
  const { camera } = useThree();
  const c = cameraAt(frame);
  // a hand-held breath
  const sway = [Math.sin(frame / 47) * 0.004, Math.sin(frame / 61) * 0.003, 0] as const;
  const cam = camera as THREE.PerspectiveCamera;
  cam.position.set(c.p[0] + sway[0], c.p[1] + sway[1], c.p[2]);
  cam.fov = c.fov;
  cam.lookAt(...c.look);
  cam.updateProjectionMatrix();
  return null;
};

const World: React.FC<{ frame: number }> = ({ frame }) => {
  const lamp =
    frame < FILM.B
      ? interpolate(frame, [0, 46], [0.02, 1], { ...clamp, easing: Easing.out(Easing.quad) })
      : frame >= FILM.D && frame < FILM.E
        ? interpolate(frame, [FILM.D, FILM.D + 30], [0.8, 1.1], clamp)
        : 1;
  // table time: real time until the strike, then slow motion
  const tReal = frame / FPS;
  const strike = STRIKE / FPS;
  const t = tReal < strike ? tReal : strike + (tReal - strike) * 0.3;
  return (
    <>
      <Environment />
      <Rig frame={frame} />
      <Lamp intensity={lamp} frame={frame} />
      <Table />
      {frame < FILM.C ? <BreakShot t={t} strikeAt={strike} /> : null}
      {frame >= FILM.C && frame < FILM.D ? <SixBalls frame={frame - FILM.C} /> : null}
      {frame >= FILM.D && frame < FILM.E ? <Ticket frame={frame - FILM.D} /> : null}
      {frame >= FILM.E ? <SixBalls frame={400} /> : null}
    </>
  );
};

/* ------------------------------------------------------------------ */
/* overlays: grain, vignette, dips, titles                             */
/* ------------------------------------------------------------------ */
const Grain: React.FC<{ frame: number }> = ({ frame }) => (
  <AbsoluteFill style={{ mixBlendMode: "overlay", opacity: 0.22, pointerEvents: "none" }}>
    <svg width="1080" height="1920">
      <filter id="g">
        <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed={Math.floor(random(`g${frame}`) * 1000)} />
        <feColorMatrix type="saturate" values="0" />
      </filter>
      <rect width="1080" height="1920" filter="url(#g)" />
    </svg>
  </AbsoluteFill>
);

const Vignette: React.FC = () => (
  <AbsoluteFill
    style={{
      background: "radial-gradient(ellipse at 50% 46%, transparent 38%, rgba(0,0,0,.55) 78%, rgba(0,0,0,.9) 100%)",
      pointerEvents: "none",
    }}
  />
);

const CUTS = [FILM.C, FILM.D, FILM.E, FILM.F];
const Dips: React.FC<{ frame: number }> = ({ frame }) => {
  let o = interpolate(frame, [0, 18], [1, 0], clamp);
  for (const c of CUTS) o = Math.max(o, interpolate(frame, [c - 9, c, c + 9], [0, 1, 0], clamp));
  o = Math.max(o, interpolate(frame, [FILM.END - 14, FILM.END], [0, 1], clamp));
  return <AbsoluteFill style={{ background: "#000", opacity: o }} />;
};

const rise = (frame: number, at: number, dur = 18) =>
  interpolate(frame, [at, at + dur], [0, 1], { ...clamp, easing: Easing.bezier(0.16, 1, 0.3, 1) });
const fadeOut = (frame: number, at: number, dur = 12) => interpolate(frame, [at, at + dur], [1, 0], clamp);

/** A title that rises in with a soft blur and fades out. */
const Title: React.FC<{
  frame: number;
  from: number;
  to: number;
  top: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ frame, from, to, top, children, style }) => {
  if (frame < from || frame > to + 14) return null;
  const p = rise(frame, from, 22);
  const o = Math.min(p, fadeOut(frame, to));
  return (
    <div
      style={{
        position: "absolute",
        left: 60,
        right: 60,
        top,
        textAlign: "center",
        fontFamily: FONT,
        opacity: o,
        translate: `0 ${(1 - p) * 26}px`,
        filter: `blur(${(1 - p) * 10}px)`,
        ...style,
      }}
    >
      {children}
    </div>
  );
};

const small: React.CSSProperties = { fontSize: 30, fontWeight: 700, letterSpacing: 14, color: "rgba(230,240,236,.8)" };
const big: React.CSSProperties = {
  fontSize: 118,
  fontWeight: 900,
  letterSpacing: -3,
  lineHeight: 0.98,
  color: "#f5f8f7",
  textShadow: "0 10px 50px rgba(0,0,0,.7)",
};
const gold: React.CSSProperties = {
  background: "linear-gradient(180deg,#fff1c6 0%,#e5b95c 55%,#b8862e 100%)",
  WebkitBackgroundClip: "text",
  color: "transparent",
};

const Counter: React.FC<{ frame: number }> = ({ frame }) => {
  const local = frame - FILM.C;
  if (local < 0 || frame >= FILM.D) return null;
  const starts = [12, 42, 72, 102, 132, 162];
  const n = starts.filter((s) => local >= s + 20).length;
  const p = rise(frame, FILM.C + 8, 20);
  const done = n >= 6;
  return (
    <div style={{ position: "absolute", top: 250, left: 0, right: 0, textAlign: "center", fontFamily: FONT, opacity: p }}>
      <div style={small}>TASHRIFLAR</div>
      <div style={{ ...big, fontSize: 210, marginTop: 6, ...(done ? gold : {}) }}>
        {n}
        <span style={{ fontSize: 110, color: done ? undefined : "rgba(245,248,247,.45)" }}> / 6</span>
      </div>
    </div>
  );
};

const BotCard: React.FC<{ frame: number }> = ({ frame }) => {
  const local = frame - FILM.E;
  if (local < 0 || frame >= FILM.F) return null;
  const p = rise(frame, FILM.E + 16, 26);
  const msg = rise(frame, FILM.E + 44, 18);
  const btn = rise(frame, FILM.E + 70, 16);
  return (
    <div
      style={{
        position: "absolute",
        left: 110,
        right: 110,
        top: 560,
        opacity: p,
        translate: `0 ${(1 - p) * 60}px`,
        scale: String(0.94 + 0.06 * p),
        fontFamily: FONT,
        borderRadius: 46,
        padding: 34,
        background: "rgba(14,22,33,.86)",
        border: "1px solid rgba(255,255,255,.08)",
        boxShadow: "0 50px 140px rgba(0,0,0,.7), 0 0 0 1px rgba(57,239,173,.08)",
        backdropFilter: "blur(14px)",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
        <Img src={staticFile("logo_square.jpg")} style={{ width: 86, height: 86, borderRadius: "50%", objectFit: "cover" }} />
        <div>
          <div style={{ fontSize: 36, fontWeight: 800, color: "#f5f8f7" }}>Billion billiard</div>
          <div style={{ fontSize: 26, color: "#6ab3f3" }}>bot</div>
        </div>
      </div>
      <div
        style={{
          marginTop: 28,
          padding: "26px 30px",
          borderRadius: 30,
          borderBottomLeftRadius: 8,
          background: "#182533",
          color: "#f5f8f7",
          fontSize: 36,
          lineHeight: 1.38,
          opacity: msg,
          translate: `0 ${(1 - msg) * 18}px`,
        }}
      >
        🎉 <b>Tabriklaymiz!</b>
        <br />
        Siz 6 marta tashrif buyurdingiz.
        <br />
        🎁 <b>1 soat BEPUL o'yin</b> kuponi sizniki!
        <br />
        <span style={{ color: "#e5b95c", fontWeight: 800 }}>🎟 BILL-6-2481</span>
      </div>
      <div
        style={{
          marginTop: 14,
          padding: "22px 0",
          borderRadius: 24,
          textAlign: "center",
          background: "rgba(92,140,190,.25)",
          color: "#f5f8f7",
          fontSize: 32,
          fontWeight: 700,
          opacity: btn,
        }}
      >
        🎟 Mening kuponlarim
      </div>
    </div>
  );
};

const Final: React.FC<{ frame: number }> = ({ frame }) => {
  if (frame < FILM.F) return null;
  const w = rise(frame, FILM.F + 10, 24);
  const b = rise(frame, FILM.F + 34, 20);
  const c = rise(frame, FILM.F + 58, 20);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 40%, rgba(0,0,0,.15), rgba(0,0,0,.72) 70%)" }} />
      <Img
        src={staticFile("logo.png")}
        style={{ position: "absolute", top: 380, width: 780, mixBlendMode: "lighten", opacity: w, filter: `blur(${(1 - w) * 12}px)` }}
      />
      <div style={{ position: "absolute", top: 640, textAlign: "center", opacity: b, translate: `0 ${(1 - b) * 20}px` }}>
        <div style={{ ...small, letterSpacing: 10 }}>TELEGRAM BOT</div>
        <div style={{ fontSize: 70, fontWeight: 900, color: C.green, marginTop: 14, textShadow: "0 0 40px rgba(57,239,173,.5)" }}>
          @billionbiliard_bot
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 870,
          opacity: c,
          translate: `0 ${(1 - c) * 24}px`,
          padding: "30px 60px",
          borderRadius: 40,
          background: "linear-gradient(135deg,#5affc1,#18d993)",
          color: "#022d20",
          fontSize: 50,
          fontWeight: 900,
          textAlign: "center",
          boxShadow: "0 30px 90px rgba(21,222,147,.35)",
        }}
      >
        «Start» ni bosing
      </div>
      <div style={{ position: "absolute", top: 1060, opacity: c, textAlign: "center", fontSize: 36, lineHeight: 1.55, color: "#c7d0cd", fontWeight: 600 }}>
        📍 Ma'rifat ko'chasi 122, Angren
        <br />
        📞 +998 95 969 55 77
      </div>
    </AbsoluteFill>
  );
};

/** Subtitles = the voice-over (PROMO_ovoz_ssenariy.txt has the same lines). */
export const FILM_LINES: Line[] = [
  { text: "BILLION'da yangi aksiya!", from: 24, to: 144 },
  { text: "Klubga olti marta keling — bir soat o'yin sizga bepul!", from: 156, to: 318 },
  { text: "Har bir tashrifingiz hisobingizga yoziladi.", from: 340, to: 462 },
  { text: "Oltinchi tashrif — va sovg'a sizniki!", from: 468, to: 562 },
  { text: "Bir soatlik o'yin kuponi — butunlay bepul.", from: 584, to: 752 },
  { text: "Kupon darhol Telegram botingizga keladi.", from: 772, to: 856 },
  { text: "Keyingi safar ko'rsating — va bepul o'ynang!", from: 860, to: 934 },
  { text: "Hali botda yo'qmisiz? «Start» ni bosing!", from: 952, to: 1030 },
  { text: "BILLION — sizni kutamiz!", from: 1034, to: 1100 },
];

export const PromoFilm: React.FC<{ subtitles?: boolean }> = ({ subtitles = true }) => {
  const frame = useCurrentFrame();
  const blur = frame >= FILM.E && frame < FILM.F ? interpolate(frame, [FILM.E, FILM.E + 30], [0, 9], clamp) : frame >= FILM.F ? 6 : 0;
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <AbsoluteFill style={{ filter: blur ? `blur(${blur}px) brightness(.7)` : undefined }}>
        <ThreeCanvas
          width={1080}
          height={1920}
          shadows
          camera={{ fov: 30, near: 0.03, far: 20, position: [0, 1.6, 2] }}
          gl={{ antialias: true, toneMapping: THREE.ACESFilmicToneMapping, toneMappingExposure: 0.95 }}
        >
          <World frame={frame} />
        </ThreeCanvas>
      </AbsoluteFill>
      {/* warm haze around the lamp */}
      <AbsoluteFill
        style={{
          background: "radial-gradient(circle at 50% 0%, rgba(255,196,120,.16), transparent 45%)",
          mixBlendMode: "screen",
          pointerEvents: "none",
        }}
      />
      <Title frame={frame} from={40} to={140} top={300}>
        <div style={small}>BILLION · BILYARD KLUBI</div>
        <div style={{ ...big, marginTop: 18 }}>
          YANGI
          <br />
          <span style={gold}>AKSIYA</span>
        </div>
      </Title>
      <Title frame={frame} from={206} to={322} top={250}>
        <div style={{ ...big, fontSize: 104 }}>6 marta keling</div>
        <div style={{ ...big, fontSize: 84, marginTop: 22, opacity: rise(frame, 252, 18) }}>
          1 soat o'yin — <span style={gold}>BEPUL</span>
        </div>
      </Title>
      <Counter frame={frame} />
      <Title frame={frame} from={FILM.D + 40} to={FILM.E - 12} top={250}>
        <div style={small}>SOVG'A</div>
        <div style={{ ...big, fontSize: 96, marginTop: 14 }}>
          Kupon — <span style={gold}>sizniki</span>
        </div>
      </Title>
      <Title frame={frame} from={FILM.E + 8} to={FILM.F - 12} top={300}>
        <div style={small}>TELEGRAM</div>
        <div style={{ ...big, fontSize: 84, marginTop: 14 }}>Kupon botga keladi</div>
      </Title>
      <BotCard frame={frame} />
      <Final frame={frame} />
      <Vignette />
      <Grain frame={frame} />
      {subtitles ? <Subtitles lines={FILM_LINES} /> : null}
      <Dips frame={frame} />
    </AbsoluteFill>
  );
};
