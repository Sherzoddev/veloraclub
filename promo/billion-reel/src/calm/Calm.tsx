import React, { useMemo } from "react";
import { AbsoluteFill, Easing, Img, interpolate, random, staticFile, useCurrentFrame } from "remotion";
import { ThreeCanvas } from "@remotion/three";
import * as THREE from "three";
import { useThree } from "@react-three/fiber";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { ballTexture, IVORY } from "../cinema/Stage";
import { couponFace, couponShape, phoneScreen } from "../motion/Motion";
import { FONT } from "../theme";
import "../fonts";

/* The calm cut of "6 tashrif = 1 soat bepul": the bright reel's pace and
   scenes, in deep, rich colours with clean type and gold accents -- premium
   rather than cartoon. Russian billiard balls, Uzbek. 30 fps, 30 s. */

export const CB = {
  HOOK: 0,
  RING: 75,
  GOLD: 250,
  COUPON: 322,
  PHONE: 470,
  TERMS: 630,
  END: 750,
  LENGTH: 900,
};
const ARR = (i: number) => 110 + i * 28; // ball i sits in its slot (ARR(5) = GOLD)

/** Scene colours: the floor, the fog and the page all take it, so the stage is seamless. */
const SCENES: { at: number; color: string; deep: string }[] = [
  { at: CB.HOOK, color: "#1d5c49", deep: "#0f3b2f" },
  { at: CB.RING, color: "#226b52", deep: "#124535" },
  { at: CB.GOLD, color: "#3d2b5e", deep: "#251a3b" },
  { at: CB.COUPON, color: "#5e2034", deep: "#3a1220" },
  { at: CB.PHONE, color: "#1f4f78", deep: "#12304a" },
  { at: CB.TERMS, color: "#5e4322", deep: "#3a2914" },
  { at: CB.END, color: "#1d5c49", deep: "#0f3b2f" },
];
const sceneAt = (f: number) => {
  let i = 0;
  while (i < SCENES.length - 1 && f >= SCENES[i + 1].at) i++;
  return i;
};

const R = 0.06;
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const ease = Easing.bezier(0.65, 0, 0.35, 1);
const out = Easing.bezier(0.16, 1, 0.3, 1);
const back = Easing.out(Easing.back(1.4));
const k = (f: number, a: number, b: number, e = ease) => interpolate(f, [a, b], [0, 1], { ...clamp, easing: e });

const SLOT_R = 0.3;
const slot = (i: number): [number, number] => {
  const a = -Math.PI / 2 + (i / 6) * Math.PI * 2;
  return [Math.cos(a) * SLOT_R, Math.sin(a) * SLOT_R];
};

/* ------------------------------------------------------------------ */
/* 3D                                                                  */
/* ------------------------------------------------------------------ */
function useLook() {
  return useMemo(() => {
    const ball = (n: number) =>
      new THREE.MeshPhysicalMaterial({
        map: ballTexture(IVORY, n),
        roughness: 0.1,
        clearcoat: 1,
        clearcoatRoughness: 0.03,
        envMapIntensity: 1.1,
      });
    return {
      balls: Array.from({ length: 16 }, (_, n) => ball(n)),
      gold: new THREE.MeshPhysicalMaterial({
        map: ballTexture("#ffcf5a", 6, { ink: "#5a3c0c" }),
        color: "#ffffff",
        metalness: 0.85,
        roughness: 0.18,
        clearcoat: 0.8,
        envMapIntensity: 2,
      }),
      couponGold: new THREE.MeshPhysicalMaterial({ color: "#ffc531", metalness: 1, roughness: 0.18, clearcoat: 0.7, envMapIntensity: 2.2 }),
    };
  }, []);
}
type Look = ReturnType<typeof useLook>;

const Stage: React.FC<{ f: number }> = ({ f }) => {
  const { gl, scene } = useThree();
  useMemo(() => {
    const pm = new THREE.PMREMGenerator(gl);
    scene.environment = pm.fromScene(new RoomEnvironment(), 0.04).texture;
    scene.environmentIntensity = 0.9;
  }, [gl, scene]);
  const col = SCENES[sceneAt(f)].color;
  scene.background = new THREE.Color(col);
  scene.fog = new THREE.Fog(col, 2.0, 4.6);
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
      <circleGeometry args={[12, 96]} />
      <meshStandardMaterial color={col} roughness={0.6} metalness={0.15} />
    </mesh>
  );
};

type Cam = { p: [number, number, number]; look: [number, number, number]; fov: number };
const mix3 = (a: number[], b: number[], t: number) => a.map((v, i) => v + (b[i] - v) * t) as [number, number, number];

function cameraAt(f: number): Cam {
  if (f < CB.RING) {
    const t = k(f, 0, CB.RING);
    return { p: mix3([0, 0.3, 2.0], [0.12, 0.42, 1.7], t), look: [0, 0.2, 0], fov: 40 };
  }
  if (f < CB.COUPON) {
    const t = (f - CB.RING) / (CB.COUPON - CB.RING);
    const a = 0.4 + t * 1.3;
    const dist = 1.2;
    const h = 1.7 - 0.2 * t;
    const ahead = 0.3;
    return { p: [Math.sin(a) * dist, h, Math.cos(a) * dist], look: [-Math.sin(a) * ahead, 0.03 + 0.25 * k(f, CB.GOLD + 10, CB.COUPON), -Math.cos(a) * ahead], fov: 40 };
  }
  if (f < CB.PHONE) {
    const t = k(f, CB.COUPON, CB.PHONE);
    return { p: mix3([0, 0.42, 1.95], [0.06, 0.42, 1.62], t), look: [0, 0.43, 0], fov: 34 };
  }
  if (f < CB.TERMS) {
    const t = k(f, CB.PHONE, CB.TERMS);
    return { p: mix3([-0.25, 0.44, 2.05], [0.08, 0.42, 1.9], t), look: [0, 0.47, 0], fov: 34 };
  }
  const t = (f - CB.TERMS) / (CB.LENGTH - CB.TERMS);
  const a = -0.4 + t * 0.9;
  return { p: [Math.sin(a) * 1.6, 0.55, Math.cos(a) * 1.6], look: [0, 0.3, 0], fov: 40 };
}

const Rig: React.FC<{ f: number }> = ({ f }) => {
  const { camera } = useThree();
  const c = cameraAt(f);
  const hit = Math.max(
    interpolate(f, [CB.GOLD, CB.GOLD + 2, CB.GOLD + 16], [0, 1, 0], clamp),
    interpolate(f, [CB.COUPON, CB.COUPON + 2, CB.COUPON + 14], [0, 0.8, 0], clamp),
    interpolate(f, [10, 12, 24], [0, 0.5, 0], clamp),
  );
  const cam = camera as THREE.PerspectiveCamera;
  cam.position.set(c.p[0] + Math.sin(f * 2.3) * 0.012 * hit, c.p[1] + Math.cos(f * 2.9) * 0.01 * hit, c.p[2]);
  cam.fov = c.fov;
  cam.lookAt(...c.look);
  cam.updateProjectionMatrix();
  return null;
};

/** A ball that rolls: the number turns with the distance travelled. */
const Ball: React.FC<{ p: [number, number, number]; mat: THREE.Material; spin?: [number, number, number]; s?: number }> = ({ p, mat, spin = [0, 0, 0], s = 1 }) => (
  <mesh position={p} rotation={spin} scale={s} castShadow material={mat}>
    <sphereGeometry args={[R, 64, 48]} />
  </mesh>
);

const Ripple: React.FC<{ x: number; z: number; f: number; at: number; size?: number; dur?: number; color?: string }> = ({ x, z, f, at, size = 0.4, dur = 22, color = "#ffffff" }) => {
  if (f < at || f > at + dur) return null;
  const t = (f - at) / dur;
  return (
    <mesh position={[x, 0.003, z]} rotation={[-Math.PI / 2, 0, 0]} scale={0.05 + t * size}>
      <ringGeometry args={[0.86, 1, 96]} />
      <meshBasicMaterial color={color} transparent opacity={(1 - t) * 0.95} depthWrite={false} />
    </mesh>
  );
};

/** Hook: a shower of balls lands and bounces like popcorn. */
const Popcorn: React.FC<{ f: number; look: Look }> = ({ f, look }) => (
  <group>
    {Array.from({ length: 11 }, (_, i) => {
      const x = (random(`px${i}`) - 0.5) * 0.9;
      const z = (random(`pz${i}`) - 0.5) * 0.7;
      const start = 2 + Math.floor(random(`pt${i}`) * 26);
      const t = Math.max(0, (f - start) / 30);
      let y: number;
      if (t < 0.4) y = 1.4 * (1 - (t / 0.4) ** 2);
      else {
        const u = t - 0.4;
        y = Math.abs(Math.sin(u * 10)) * 0.25 * Math.exp(-u * 3.6);
      }
      const n = 1 + (i % 15);
      return <Ball key={i} p={[x, R + y, z]} mat={look.balls[n]} spin={[0.2, -0.6 + random(`pr${i}`) * 1.2 + t * 2, 0]} />;
    })}
    {Array.from({ length: 11 }, (_, i) => (
      <Ripple key={i} x={(random(`px${i}`) - 0.5) * 0.9} z={(random(`pz${i}`) - 0.5) * 0.7} f={f} at={2 + Math.floor(random(`pt${i}`) * 26) + 12} size={0.18} dur={16} />
    ))}
  </group>
);

/** The ring: a ball rolls into a slot for every visit; the sixth is gold. */
const Ring: React.FC<{ f: number; look: Look }> = ({ f, look }) => {
  const whirl = k(f, CB.GOLD + 24, CB.COUPON, Easing.in(Easing.cubic));
  return (
    <group>
      {Array.from({ length: 6 }, (_, i) => {
        const [sx, sz] = slot(i);
        const lit = f >= ARR(i);
        return (
          <mesh key={`h${i}`} position={[sx, 0.002, sz]} rotation={[-Math.PI / 2, 0, 0]}>
            <ringGeometry args={[R * 1.15, R * 1.5, 64]} />
            <meshBasicMaterial color={lit ? "#e8b955" : "#000000"} transparent opacity={(lit ? 0.9 : 0.22) * (1 - whirl)} depthWrite={false} />
          </mesh>
        );
      })}
      {Array.from({ length: 6 }, (_, i) => {
        const start = ARR(i) - 22;
        if (f < start) return null;
        const [sx, sz] = slot(i);
        const t = k(f, start, ARR(i), out);
        const a1 = Math.atan2(sz, sx);
        const a = a1 - 1.5 * (1 - t);
        const r = SLOT_R + (1 - t) * 0.9;
        let x = Math.cos(a) * r;
        let z = Math.sin(a) * r;
        let y = R + (i === 5 ? (1 - t) * 0.9 : 0);
        if (whirl > 0) {
          const wa = Math.atan2(z, x) + whirl * whirl * 10;
          const wr = Math.hypot(x, z) * (1 - whirl);
          x = Math.cos(wa) * wr;
          z = Math.sin(wa) * wr;
          y = R + whirl * 0.36;
        }
        // numbers face the camera when they stop, roll on the way in
        const roll = (1 - t) * 9;
        return <Ball key={i} p={[x, y, z]} mat={i === 5 ? look.gold : look.balls[i + 1]} spin={[roll, Math.PI / 2 - a1 * 0.2 + 0.4, 0]} s={1 - whirl * 0.6} />;
      })}
      {Array.from({ length: 6 }, (_, i) => {
        const [sx, sz] = slot(i);
        return <Ripple key={`r${i}`} x={sx} z={sz} f={f} at={ARR(i)} size={i === 5 ? 2.2 : 0.42} dur={i === 5 ? 30 : 20} color={i === 5 ? "#e8b955" : "#f3ead3"} />;
      })}
    </group>
  );
};

const Confetti: React.FC<{ f: number; at: number }> = ({ f, at }) => {
  const N = 180;
  const ref = React.useRef<THREE.InstancedMesh>(null);
  const seeds = useMemo(
    () =>
      Array.from({ length: N }, (_, i) => ({
        v: [random(`cx${i}`) * 2 - 1, random(`cy${i}`) * 1.6 + 0.5, random(`cz${i}`) * 2 - 1],
        s: 0.7 + random(`cs${i}`),
        r: random(`cr${i}`) * 10,
        c: ["#f3ead3", "#e8b955", "#c99a3e", "#fff3cc"][i % 4],
      })),
    [],
  );
  const t = (f - at) / 30;
  React.useLayoutEffect(() => {
    const m = ref.current;
    if (!m) return;
    const o = new THREE.Object3D();
    seeds.forEach((sd, i) => {
      const tt = Math.max(0, t);
      o.position.set(sd.v[0] * tt * 0.9, 0.36 + sd.v[1] * tt * 0.9 - 0.85 * tt * tt, sd.v[2] * tt * 0.6);
      o.rotation.set(sd.r + tt * 7, sd.r * 2 + tt * 5, 0);
      o.scale.setScalar(tt > 0 ? sd.s : 0.0001);
      o.updateMatrix();
      m.setMatrixAt(i, o.matrix);
      m.setColorAt(i, new THREE.Color(sd.c));
    });
    m.instanceMatrix.needsUpdate = true;
    if (m.instanceColor) m.instanceColor.needsUpdate = true;
  });
  if (f < at || f > at + 80) return null;
  return (
    <instancedMesh ref={ref} args={[undefined, undefined, N]}>
      <planeGeometry args={[0.02, 0.034]} />
      <meshStandardMaterial side={THREE.DoubleSide} roughness={0.5} />
    </instancedMesh>
  );
};

const Coupon: React.FC<{ f: number; look: Look }> = ({ f, look }) => {
  const W = 0.27;
  const H = 0.45;
  const geo = useMemo(() => {
    const g = new THREE.ExtrudeGeometry(couponShape(W, H, 0.024, 0.026), {
      depth: 0.008,
      bevelEnabled: true,
      bevelThickness: 0.003,
      bevelSize: 0.003,
      bevelSegments: 4,
      curveSegments: 24,
    });
    g.center();
    return g;
  }, []);
  const face = useMemo(() => couponFace(), []);
  if (f < CB.COUPON || f > CB.PHONE + 70) return null;
  const pop = k(f, CB.COUPON, CB.COUPON + 30, back);
  const spin = (1 - k(f, CB.COUPON, CB.COUPON + 60, out)) * Math.PI * 6 + Math.sin(f / 20) * 0.2;
  const fly = k(f, CB.PHONE + 30, CB.PHONE + 62, Easing.in(Easing.cubic));
  const s = (0.1 + 0.9 * pop) * (1 - fly * 0.85);
  return (
    <group position={[0, 0.34 + Math.sin(f / 16) * 0.012 - fly * 0.02, fly * 0.06]} rotation={[0, spin, Math.sin(f / 26) * 0.07]} scale={s}>
      <mesh geometry={geo} castShadow material={look.couponGold} />
      <mesh position={[0, 0, 0.0075]}>
        <planeGeometry args={[W * 0.97, H * 0.97]} />
        <meshStandardMaterial map={face} transparent roughness={0.4} metalness={0.25} />
      </mesh>
    </group>
  );
};

const Orbit: React.FC<{ f: number; look: Look; from: number; to: number }> = ({ f, look, from, to }) => {
  if (f < from || f > to) return null;
  const p = k(f, from, from + 24, back) * (1 - k(f, to - 16, to));
  return (
    <group>
      {Array.from({ length: 6 }, (_, i) => {
        const a = (i / 6) * Math.PI * 2 + f * 0.035;
        const z = Math.sin(a) * 0.5 * p;
        return <Ball key={i} p={[Math.cos(a) * 0.5 * p, 0.36 - z * 0.55, z]} mat={i === 0 ? look.gold : look.balls[i + 1]} spin={[0, -a + Math.PI / 2, 0]} s={0.75} />;
      })}
    </group>
  );
};

const Phone: React.FC<{ f: number }> = ({ f }) => {
  const body = useMemo(() => new RoundedBoxGeometry(0.34, 0.7, 0.03, 6, 0.045), []);
  const [logo, setLogo] = React.useState<HTMLImageElement | null>(null);
  React.useEffect(() => {
    const im = new Image();
    im.onload = () => setLogo(im);
    im.src = staticFile("logo_square.jpg");
  }, []);
  const screen = useMemo(() => phoneScreen(logo), [logo]);
  if (f < CB.PHONE || f > CB.TERMS + 20) return null;
  const inP = k(f, CB.PHONE, CB.PHONE + 26, back);
  const outP = k(f, CB.TERMS - 10, CB.TERMS + 20, Easing.in(Easing.cubic));
  const msg = k(f, CB.PHONE + 58, CB.PHONE + 72, out);
  return (
    <group position={[0, 0.36 - (1 - inP) * 0.9 + outP * 0.9, -0.02]} rotation={[0, (1 - inP) * -1.6 + Math.sin(f / 30) * 0.1, (1 - inP) * 0.3]}>
      <mesh geometry={body} castShadow>
        <meshPhysicalMaterial color="#14171c" metalness={0.5} roughness={0.25} clearcoat={1} />
      </mesh>
      <mesh position={[0, 0, 0.0155]}>
        <planeGeometry args={[0.315, 0.665]} />
        <meshBasicMaterial map={screen} toneMapped={false} transparent opacity={0.3 + 0.7 * msg} />
      </mesh>
    </group>
  );
};

const Float: React.FC<{ f: number; look: Look }> = ({ f, look }) => {
  if (f < CB.TERMS - 10) return null;
  const p = k(f, CB.TERMS - 10, CB.TERMS + 24, back);
  return (
    <group>
      {Array.from({ length: 14 }, (_, i) => {
        const x = (random(`fx${i}`) - 0.5) * 1.7;
        const z = (random(`fz${i}`) - 0.5) * 1.2 - 0.35;
        const y = 0.1 + random(`fy${i}`) * 0.75 + Math.sin(f / 22 + i) * 0.04;
        return <Ball key={i} p={[x, y * p + (1 - p) * -0.4, z]} mat={i % 7 === 0 ? look.gold : look.balls[1 + (i % 15)]} spin={[f * 0.02 + i, f * 0.03 + i * 2, 0]} s={0.6 + random(`fs${i}`) * 0.5} />;
      })}
    </group>
  );
};

const World: React.FC<{ f: number }> = ({ f }) => {
  const look = useLook();
  return (
    <>
      <Stage f={f} />
      <Rig f={f} />
      <hemisphereLight args={["#ffffff", "#888888", 1.4]} />
      <directionalLight position={[0.8, 2.5, 1.2]} intensity={2.6} castShadow shadow-mapSize={[2048, 2048]} shadow-camera-left={-1.5} shadow-camera-right={1.5} shadow-camera-top={1.5} shadow-camera-bottom={-1.5} shadow-bias={-0.0004} />
      {f < CB.RING + 6 ? <Popcorn f={f} look={look} /> : null}
      {f >= CB.RING - 4 && f < CB.COUPON + 2 ? <Ring f={f} look={look} /> : null}
      <Confetti f={f} at={CB.COUPON} />
      <Coupon f={f} look={look} />
      <Orbit f={f} look={look} from={CB.COUPON + 18} to={CB.PHONE + 30} />
      <Phone f={f} />
      <Float f={f} look={look} />
    </>
  );
};

/* ------------------------------------------------------------------ */
/* type                                                                */
/* ------------------------------------------------------------------ */
const ink = "#0b0f0d";
const GOLD = "linear-gradient(180deg,#fff3cc 0%,#e8b955 55%,#b5832b 100%)";
/** Clean heavy type: white with a soft shadow, or a gold gradient. */
const sticker = (fill = "#ffffff"): React.CSSProperties =>
  fill === "gold"
    ? { background: GOLD, WebkitBackgroundClip: "text", color: "transparent", filter: "drop-shadow(0 8px 24px rgba(0,0,0,.45))" }
    : { color: fill, textShadow: "0 8px 30px rgba(0,0,0,.45)" };

const Pop: React.FC<{ text: string; f: number; at: number; to: number; size: number; fill?: string; stagger?: number; tilt?: number }> = ({
  text,
  f,
  at,
  to,
  size,
  fill = "#ffffff",
  stagger = 2,
  tilt = 0,
}) => {
  if (f < at || f > to + 10) return null;
  const leave = k(f, to, to + 10, Easing.in(Easing.cubic));
  return (
    <div style={{ display: "flex", justifyContent: "center", flexWrap: "wrap", rotate: `${tilt * 0}deg`, opacity: 1 - leave, translate: `0 ${-leave * 30}px` }}>
      {[...text].map((ch, i) => {
        const p = k(f, at + i * stagger, at + i * stagger + 14, out);
        return (
          <span
            key={i}
            style={{
              display: "inline-block",
              whiteSpace: "pre",
              fontSize: size,
              fontWeight: 900,
              letterSpacing: -1,
              lineHeight: 1.02,
              opacity: Math.min(1, p * 1.6),
              translate: `0 ${(1 - p) * 40}px`,
              filter: `blur(${(1 - p) * 8}px)`,
              ...sticker(fill),
            }}
          >
            {ch}
          </span>
        );
      })}
    </div>
  );
};

const Block: React.FC<{ top: number; children: React.ReactNode }> = ({ top, children }) => (
  <div style={{ position: "absolute", top, left: 30, right: 30, textAlign: "center", fontFamily: FONT }}>{children}</div>
);

/** A rotated label that slaps on and wobbles. */
const Label: React.FC<{ f: number; at: number; to: number; bg: string; color?: string; tilt?: number; size?: number; children: React.ReactNode }> = ({
  f,
  at,
  to,
  bg,
  color = ink,
  tilt = -4,
  size = 52,
  children,
}) => {
  if (f < at || f > to + 10) return null;
  const p = k(f, at, at + 14, out);
  const o = 1 - k(f, to, to + 10, Easing.in(Easing.cubic));
  void bg;
  void color;
  void tilt;
  return (
    <div
      style={{
        display: "inline-block",
        padding: "22px 40px",
        borderRadius: 999,
        background: "rgba(8,14,12,.55)",
        color: "#f5f1e6",
        border: "1.5px solid rgba(232,185,85,.65)",
        boxShadow: "0 20px 60px rgba(0,0,0,.35)",
        backdropFilter: "blur(10px)",
        fontSize: size * 0.9,
        fontWeight: 800,
        opacity: p * o,
        translate: `0 ${(1 - p) * 30}px`,
      }}
    >
      {children}
    </div>
  );
};

const Counter: React.FC<{ f: number }> = ({ f }) => {
  if (f < CB.RING + 8 || f > CB.COUPON - 2) return null;
  let n = 0;
  for (let i = 0; i < 6; i++) if (f >= ARR(i)) n = i + 1;
  const last = n > 0 ? ARR(n - 1) : -99;
  const pulse = interpolate(f, [last, last + 3, last + 14], [1.18, 1.18, 1], { ...clamp, easing: back });
  const inP = k(f, CB.RING + 8, CB.RING + 22, back);
  return (
    <Block top={170}>
      <div style={{ opacity: inP, fontSize: 32, fontWeight: 800, letterSpacing: 14, color: "rgba(245,241,230,.8)" }}>
        TASHRIFLAR
      </div>
      <div style={{ fontSize: 240, fontWeight: 900, lineHeight: 1.05, letterSpacing: -6, scale: `${pulse * inP}`, ...sticker(n === 6 ? "gold" : "#ffffff") }}>
        {n}/6
      </div>
    </Block>
  );
};

/** Circle wipe in the next scene's colour, from the centre. */
const Wipes: React.FC<{ f: number }> = ({ f }) => (
  <>
    {SCENES.slice(1).map((s, i) => {
      if (f < s.at - 8 || f > s.at + 3) return null;
      const o = interpolate(f, [s.at - 8, s.at, s.at + 3], [0, 1, 0], clamp);
      return <AbsoluteFill key={i} style={{ background: `radial-gradient(circle at 50% 50%, ${s.color}, ${s.deep})`, opacity: o }} />;
    })}
  </>
);

const Terms: React.FC<{ f: number }> = ({ f }) => {
  if (f < CB.TERMS || f > CB.END + 10) return null;
  const rows: [string, string, string][] = [
    ["🕚", "Har kuni 11:00 – 17:00", "#ffffff"],
    ["⏳", "Kupon 7 kun amal qiladi", "#ffd23f"],
    ["✅", "60 000 so'm va 1 soatdan", "#2be38b"],
    ["📅", "Aksiya 1-dekabrgacha", "#2aabee"],
  ];
  return (
    <Block top={300}>
      <Pop text="SHARTLAR" f={f} at={CB.TERMS + 2} to={CB.END - 8} size={120} />
      <div style={{ marginTop: 50, display: "flex", flexDirection: "column", gap: 34, alignItems: "center" }}>
        {rows.map(([icon, text, bg], i) => (
          <Label key={i} f={f} at={CB.TERMS + 16 + i * 12} to={CB.END - 8} bg={bg} tilt={i % 2 ? 3 : -3} size={50}>
            {icon} {text}
          </Label>
        ))}
      </div>
    </Block>
  );
};

const Final: React.FC<{ f: number }> = ({ f }) => {
  if (f < CB.END) return null;
  const w = k(f, CB.END + 4, CB.END + 26, out);
  const b = k(f, CB.END + 20, CB.END + 40, out);
  const c = k(f, CB.END + 36, CB.END + 56, out);
  const beat = 1 + 0.05 * Math.max(0, Math.sin(((f - CB.END) / 14) * Math.PI));
  const fade = k(f, CB.LENGTH - 12, CB.LENGTH);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <div style={{ position: "absolute", top: 330, opacity: w, scale: `${0.9 + 0.1 * w}`, padding: "34px 50px", borderRadius: 44, background: "rgba(8,14,12,.7)", border: "1.5px solid rgba(232,185,85,.6)", boxShadow: "0 30px 90px rgba(0,0,0,.45)" }}>
        <Img src={staticFile("logo.png")} style={{ width: 700, display: "block" }} />
      </div>
      <div style={{ position: "absolute", top: 650, textAlign: "center", scale: `${b}` }}>
        <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: 12, color: "rgba(245,241,230,.8)" }}>TELEGRAM BOT</div>
        <div style={{ fontSize: 84, fontWeight: 900, marginTop: 16, ...sticker("#ffffff") }}>@billionbiliard_bot</div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 900,
          scale: `${c * beat}`,
          padding: "32px 74px",
          borderRadius: 999,
          background: GOLD,
          color: "#2a1c05",
          boxShadow: "0 24px 70px rgba(232,185,85,.35)",
          fontSize: 60,
          fontWeight: 900,
        }}
      >
        «Start» ni bosing
      </div>
      <div style={{ position: "absolute", top: 1110, opacity: c, textAlign: "center", fontSize: 40, lineHeight: 1.5, fontWeight: 700, color: "rgba(245,241,230,.9)" }}>
        📍 Ma'rifat ko'chasi 122, Angren
        <br />
        📞 +998 95 969 55 77
      </div>
      <AbsoluteFill style={{ background: "#000", opacity: fade }} />
    </AbsoluteFill>
  );
};

export const PromoCalm: React.FC = () => {
  const f = useCurrentFrame();
  const scene = SCENES[sceneAt(f)];
  const flash = Math.max(interpolate(f, [CB.GOLD, CB.GOLD + 1, CB.GOLD + 8], [0, 0.35, 0], clamp), interpolate(f, [CB.COUPON - 3, CB.COUPON, CB.COUPON + 12], [0, 0.75, 0], clamp));
  return (
    <AbsoluteFill style={{ background: scene.color }}>
      <AbsoluteFill style={{ filter: f >= CB.END - 4 ? `blur(${interpolate(f, [CB.END - 4, CB.END + 20], [0, 8], clamp)}px) brightness(.7)` : undefined }}>
      <ThreeCanvas
        width={1080}
        height={1920}
        shadows
        camera={{ fov: 40, near: 0.03, far: 30, position: [0, 0.3, 2] }}
        gl={{ antialias: true, toneMapping: THREE.NeutralToneMapping, toneMappingExposure: 1.05 }}
      >
        <World f={f} />
      </ThreeCanvas>
      </AbsoluteFill>
      {/* sun rays behind the action, turning */}
      <AbsoluteFill
        style={{
          background: "radial-gradient(ellipse at 50% 0%, rgba(255,236,200,.18), transparent 55%), radial-gradient(ellipse at 50% 50%, transparent 50%, rgba(0,0,0,.45) 100%)",
          pointerEvents: "none",
        }}
      />

      {/* hook */}
      <Block top={300}>
        <Label f={f} at={4} to={CB.RING - 8} bg="#ffffff" tilt={-5} size={46}>
          BILLION · BILYARD KLUBI
        </Label>
        <div style={{ height: 30 }} />
        <Pop text="YANGI" f={f} at={10} to={CB.RING - 8} size={190} />
        <Pop text="AKSIYA!" f={f} at={20} to={CB.RING - 8} size={190} fill="gold" />
      </Block>

      {/* visits */}
      <Counter f={f} />
      <Block top={1560}>
        <Label f={f} at={CB.RING + 30} to={CB.RING + 92} bg="#ffffff" tilt={-3}>⏱ 1 soatdan ko'p o'ynang</Label>
      </Block>
      <Block top={1560}>
        <Label f={f} at={CB.RING + 100} to={CB.GOLD - 6} bg="#ffd23f" tilt={3}>💳 60 000 so'mdan to'lov</Label>
      </Block>
      <Block top={1560}>
        <Label f={f} at={CB.GOLD + 4} to={CB.COUPON - 6} bg="#ffd84d" tilt={-4} size={62}>6-TASHRIF — SOVG'A! 🎁</Label>
      </Block>

      {/* coupon */}
      <Block top={190}>
        <Pop text="1 SOAT" f={f} at={CB.COUPON + 18} to={CB.PHONE - 8} size={170} fill="gold" />
        <Pop text="BEPUL!" f={f} at={CB.COUPON + 28} to={CB.PHONE - 8} size={150} />
      </Block>

      {/* bot */}
      <Block top={170}>
        <Pop text="KUPON" f={f} at={CB.PHONE + 8} to={CB.TERMS - 10} size={130} />
        <Pop text="BOTGA KELADI" f={f} at={CB.PHONE + 16} to={CB.TERMS - 10} size={100} stagger={1} fill="gold" />
      </Block>
      <Block top={1600}>
        <Label f={f} at={CB.PHONE + 78} to={CB.TERMS - 12} bg="#ffffff" tilt={-3}>Kassada ko'rsating! 😉</Label>
      </Block>

      <Terms f={f} />
      <Final f={f} />
      <Wipes f={f} />
      <AbsoluteFill style={{ background: "radial-gradient(circle, #fff6df, rgba(255,226,160,.6) 60%)", opacity: flash, pointerEvents: "none" }} />
      <AbsoluteFill style={{ background: "#000", opacity: interpolate(f, [0, 4], [1, 0], clamp), pointerEvents: "none" }} />
    </AbsoluteFill>
  );
};
