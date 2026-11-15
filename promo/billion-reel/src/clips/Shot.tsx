import React from "react";
import { Easing, interpolate, random } from "remotion";

/* A top-down view of a Russian-billiards table: the cue ball strikes the
   pyramid, the balls scatter and one drops into the pocket. Drawn as SVG, so
   it needs no footage of the club. `t` counts frames from the start of the
   shot (the cue is drawn back at t=0 and hits at t=HIT). */

export const HIT = 52;
export const SHOT_LENGTH = 200;

const W = 1600;
const H = 900;
const RAIL = 74;
const BALL = 30;
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const outQuart = Easing.bezier(0.25, 1, 0.5, 1);
const k = (t: number, a: number, b: number, e = outQuart) => interpolate(t, [a, b], [0, 1], { ...clamp, easing: e });

const POCKETS: [number, number][] = [
  [RAIL, RAIL],
  [W / 2, RAIL - 8],
  [W - RAIL, RAIL],
  [RAIL, H - RAIL],
  [W / 2, H - RAIL + 8],
  [W - RAIL, H - RAIL],
];

const TINT = ["#d8412f", "#2f6fd8", "#e0a526", "#36a35a", "#8a4bd0", "#e0622a", "#2aa5b0", "#c93a79", "#5d6b78", "#a0732d"];

type BallDef = { n: number; x0: number; y0: number; x1: number; y1: number; hero: boolean };

// Pyramid of ten, apex towards the cue ball.
const APEX: [number, number] = [1060, H / 2];
const BALLS: BallDef[] = (() => {
  const out: BallDef[] = [];
  let n = 1;
  for (let row = 0; row < 4; row++) {
    for (let i = 0; i <= row; i++) {
      const x0 = APEX[0] + row * 54;
      const y0 = APEX[1] + (i - row / 2) * 62;
      const hero = n === 8;
      // Scatter: further from the apex the less far it goes; deterministic.
      const sx = (random(`bx${n}`) - 0.5) * 520 + row * 30;
      const sy = (random(`by${n}`) - 0.5) * 560;
      const x1 = Math.min(W - RAIL - BALL - 4, Math.max(RAIL + BALL + 4, x0 + sx));
      const y1 = Math.min(H - RAIL - BALL - 4, Math.max(RAIL + BALL + 4, y0 + sy));
      out.push({ n: n++, x0, y0, x1: hero ? POCKETS[2][0] - 10 : x1, y1: hero ? POCKETS[2][1] + 10 : y1, hero });
    }
  }
  return out;
})();

const Ball: React.FC<{ x: number; y: number; n: number; scale?: number; opacity?: number; cue?: boolean }> = ({
  x,
  y,
  n,
  scale = 1,
  opacity = 1,
  cue = false,
}) => (
  <g transform={`translate(${x} ${y}) scale(${scale})`} opacity={opacity}>
    <ellipse cx={6} cy={BALL * 0.85} rx={BALL * 0.9} ry={BALL * 0.35} fill="rgba(0,0,0,.38)" />
    <circle r={BALL} fill="url(#ivory)" />
    {cue ? (
      <circle r={5} cx={0} cy={-10} fill="#d8412f" />
    ) : (
      <>
        <circle r={13} fill={TINT[(n - 1) % TINT.length]} />
        <text y={5} textAnchor="middle" fontSize={15} fontWeight={800} fill="#fff" fontFamily="Inter, sans-serif">
          {n}
        </text>
      </>
    )}
    <ellipse cx={-9} cy={-12} rx={9} ry={5} fill="rgba(255,255,255,.7)" />
  </g>
);

export const Shot: React.FC<{ t: number }> = ({ t }) => {
  // Cue ball: from the left to the pyramid, then bounces away a little.
  const cx0 = 330;
  const cy = H / 2;
  const travel = k(t, HIT, HIT + 22, Easing.in(Easing.quad));
  const cueX = cx0 + travel * (APEX[0] - BALL * 2 - cx0) + k(t, HIT + 22, HIT + 70) * -150;
  const cueY = cy + k(t, HIT + 22, HIT + 70) * 70;

  // Cue stick: drawn back, then pushed forward.
  const gap = interpolate(t, [0, HIT - 24, HIT - 2, HIT], [22, 120, 120, 8], clamp);
  const stickX = cx0 - BALL - gap;
  const stick = k(t, HIT + 6, HIT + 20, Easing.linear);

  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" height="100%" style={{ display: "block" }}>
      <defs>
        <radialGradient id="felt" cx="50%" cy="45%" r="75%">
          <stop offset="0" stopColor="#2c9a72" />
          <stop offset="0.7" stopColor="#1a7455" />
          <stop offset="1" stopColor="#0f4b38" />
        </radialGradient>
        <linearGradient id="wood" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#6a3d20" />
          <stop offset="1" stopColor="#3b200f" />
        </linearGradient>
        <radialGradient id="ivory" cx="38%" cy="32%" r="75%">
          <stop offset="0" stopColor="#fffdf3" />
          <stop offset="0.65" stopColor="#ece4cd" />
          <stop offset="1" stopColor="#bdb394" />
        </radialGradient>
      </defs>
      <rect width={W} height={H} rx={34} fill="url(#wood)" />
      <rect x={RAIL - 14} y={RAIL - 14} width={W - 2 * RAIL + 28} height={H - 2 * RAIL + 28} rx={16} fill="#0b3a2c" />
      <rect x={RAIL} y={RAIL} width={W - 2 * RAIL} height={H - 2 * RAIL} rx={8} fill="url(#felt)" />
      {POCKETS.map(([px, py], i) => (
        <circle key={i} cx={px} cy={py} r={46} fill="#060b0a" stroke="#c9a24a" strokeWidth={5} />
      ))}
      <circle cx={APEX[0] + 160} cy={H / 2} r={5} fill="rgba(255,255,255,.35)" />
      <circle cx={330} cy={H / 2} r={5} fill="rgba(255,255,255,.35)" />

      {BALLS.map((b) => {
        const p = k(t, HIT + 20, HIT + 20 + (b.hero ? 82 : 70 - b.n * 1.5));
        const x = b.x0 + (b.x1 - b.x0) * p;
        const y = b.y0 + (b.y1 - b.y0) * p;
        const drop = b.hero ? k(t, HIT + 88, HIT + 104, Easing.in(Easing.quad)) : 0;
        return <Ball key={b.n} x={x} y={y} n={b.n} scale={1 - drop * 0.75} opacity={1 - drop} />;
      })}
      <Ball x={cueX} y={cueY} n={0} cue />

      <g opacity={1 - stick}>
        <rect x={stickX - 760} y={cy - 8} width={760} height={16} rx={8} fill="#d9b27a" />
        <rect x={stickX - 760} y={cy - 8} width={300} height={16} rx={8} fill="#3a2314" />
        <rect x={stickX - 12} y={cy - 8} width={14} height={16} fill="#3d7fcf" />
      </g>
    </svg>
  );
};
