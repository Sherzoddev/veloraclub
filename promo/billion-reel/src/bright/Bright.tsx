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

/* The bright cut of "6 tashrif = 1 soat bepul": candy-coloured 3D, a new
   colour for every scene, Russian billiard balls (ivory, black numbers),
   sticker type in Uzbek. 30 fps, 30 s. */

export const B = {
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
  { at: B.HOOK, color: "#ffd23f", deep: "#ffb000" },
  { at: B.RING, color: "#2be38b", deep: "#0fbf6b" },
  { at: B.GOLD, color: "#7b3ff2", deep: "#5a1fd1" },
  { at: B.COUPON, color: "#ff3d8b", deep: "#e0156a" },
  { at: B.PHONE, color: "#2aabee", deep: "#1488c8" },
  { at: B.TERMS, color: "#ff7a1a", deep: "#ec5a00" },
  { at: B.END, color: "#1fd17f", deep: "#0c9e5d" },
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
const back = Easing.out(Easing.back(2.2));
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
  scene.fog = new THREE.Fog(col, 2.2, 5.5);
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
      <circleGeometry args={[12, 96]} />
      <meshStandardMaterial color={col} roughness={0.85} />
    </mesh>
  );
};

type Cam = { p: [number, number, number]; look: [number, number, number]; fov: number };
const mix3 = (a: number[], b: number[], t: number) => a.map((v, i) => v + (b[i] - v) * t) as [number, number, number];

function cameraAt(f: number): Cam {
  if (f < B.RING) {
    const t = k(f, 0, B.RING);
    return { p: mix3([0, 0.3, 2.0], [0.12, 0.42, 1.7], t), look: [0, 0.2, 0], fov: 40 };
  }
  if (f < B.COUPON) {
    const t = (f - B.RING) / (B.COUPON - B.RING);
    const a = 0.4 + t * 1.3;
    const dist = 1.2;
    const h = 1.7 - 0.2 * t;
    const ahead = 0.3;
    return { p: [Math.sin(a) * dist, h, Math.cos(a) * dist], look: [-Math.sin(a) * ahead, 0.03 + 0.25 * k(f, B.GOLD + 10, B.COUPON), -Math.cos(a) * ahead], fov: 40 };
  }
  if (f < B.PHONE) {
    const t = k(f, B.COUPON, B.PHONE);
    return { p: mix3([0, 0.42, 1.95], [0.06, 0.42, 1.62], t), look: [0, 0.43, 0], fov: 34 };
  }
  if (f < B.TERMS) {
    const t = k(f, B.PHONE, B.TERMS);
    return { p: mix3([-0.25, 0.44, 2.05], [0.08, 0.42, 1.9], t), look: [0, 0.47, 0], fov: 34 };
  }
  const t = (f - B.TERMS) / (B.LENGTH - B.TERMS);
  const a = -0.4 + t * 0.9;
  return { p: [Math.sin(a) * 1.6, 0.55, Math.cos(a) * 1.6], look: [0, 0.3, 0], fov: 40 };
}

const Rig: React.FC<{ f: number }> = ({ f }) => {
  const { camera } = useThree();
  const c = cameraAt(f);
  const hit = Math.max(
    interpolate(f, [B.GOLD, B.GOLD + 2, B.GOLD + 16], [0, 1, 0], clamp),
    interpolate(f, [B.COUPON, B.COUPON + 2, B.COUPON + 14], [0, 0.8, 0], clamp),
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
  const whirl = k(f, B.GOLD + 24, B.COUPON, Easing.in(Easing.cubic));
  return (
    <group>
      {Array.from({ length: 6 }, (_, i) => {
        const [sx, sz] = slot(i);
        const lit = f >= ARR(i);
        return (
          <mesh key={`h${i}`} position={[sx, 0.002, sz]} rotation={[-Math.PI / 2, 0, 0]}>
            <ringGeometry args={[R * 1.15, R * 1.5, 64]} />
            <meshBasicMaterial color={lit ? "#ffffff" : "#000000"} transparent opacity={(lit ? 0.95 : 0.18) * (1 - whirl)} depthWrite={false} />
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
        return <Ripple key={`r${i}`} x={sx} z={sz} f={f} at={ARR(i)} size={i === 5 ? 2.2 : 0.42} dur={i === 5 ? 30 : 20} color={i === 5 ? "#ffd84d" : "#ffffff"} />;
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
        c: ["#ffffff", "#ffd23f", "#2be38b", "#2aabee", "#7b3ff2"][i % 5],
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
  if (f < B.COUPON || f > B.PHONE + 70) return null;
  const pop = k(f, B.COUPON, B.COUPON + 30, back);
  const spin = (1 - k(f, B.COUPON, B.COUPON + 60, out)) * Math.PI * 6 + Math.sin(f / 20) * 0.2;
  const fly = k(f, B.PHONE + 30, B.PHONE + 62, Easing.in(Easing.cubic));
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
  if (f < B.PHONE || f > B.TERMS + 20) return null;
  const inP = k(f, B.PHONE, B.PHONE + 26, back);
  const outP = k(f, B.TERMS - 10, B.TERMS + 20, Easing.in(Easing.cubic));
  const msg = k(f, B.PHONE + 58, B.PHONE + 72, out);
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
  if (f < B.TERMS - 10) return null;
  const p = k(f, B.TERMS - 10, B.TERMS + 24, back);
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
      {f < B.RING + 6 ? <Popcorn f={f} look={look} /> : null}
      {f >= B.RING - 4 && f < B.COUPON + 2 ? <Ring f={f} look={look} /> : null}
      <Confetti f={f} at={B.COUPON} />
      <Coupon f={f} look={look} />
      <Orbit f={f} look={look} from={B.COUPON + 18} to={B.PHONE + 30} />
      <Phone f={f} />
      <Float f={f} look={look} />
    </>
  );
};

/* ------------------------------------------------------------------ */
/* type                                                                */
/* ------------------------------------------------------------------ */
const ink = "#111111";
/** Bold sticker type: white letters with a thick dark outline and drop. */
const sticker = (fill = "#ffffff"): React.CSSProperties => ({
  color: fill,
  WebkitTextStroke: `10px ${ink}`,
  paintOrder: "stroke fill",
  textShadow: `0 10px 0 ${ink}`,
});

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
  const leave = k(f, to, to + 10, Easing.in(Easing.back(2)));
  return (
    <div style={{ display: "flex", justifyContent: "center", flexWrap: "wrap", rotate: `${tilt}deg`, scale: `${1 - leave}` }}>
      {[...text].map((ch, i) => {
        const p = k(f, at + i * stagger, at + i * stagger + 10, back);
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
              opacity: Math.min(1, p * 2),
              scale: `${p}`,
              rotate: `${(1 - p) * (i % 2 ? 25 : -25)}deg`,
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
  const p = k(f, at, at + 12, back);
  const o = 1 - k(f, to, to + 10, Easing.in(Easing.back(2)));
  return (
    <div
      style={{
        display: "inline-block",
        padding: "20px 38px",
        borderRadius: 26,
        background: bg,
        color,
        border: `6px solid ${ink}`,
        boxShadow: `0 10px 0 ${ink}`,
        fontSize: size,
        fontWeight: 900,
        scale: `${p * o}`,
        rotate: `${tilt + Math.sin((f - at) / 6) * 1.5}deg`,
      }}
    >
      {children}
    </div>
  );
};

const Counter: React.FC<{ f: number }> = ({ f }) => {
  if (f < B.RING + 8 || f > B.COUPON - 2) return null;
  let n = 0;
  for (let i = 0; i < 6; i++) if (f >= ARR(i)) n = i + 1;
  const last = n > 0 ? ARR(n - 1) : -99;
  const pulse = interpolate(f, [last, last + 3, last + 14], [1.45, 1.45, 1], { ...clamp, easing: back });
  const inP = k(f, B.RING + 8, B.RING + 22, back);
  return (
    <Block top={170}>
      <div style={{ scale: `${inP}`, display: "inline-block", padding: "10px 30px", borderRadius: 20, background: ink, color: "#fff", fontSize: 38, fontWeight: 900, letterSpacing: 8 }}>
        TASHRIFLAR
      </div>
      <div style={{ fontSize: 250, fontWeight: 900, lineHeight: 1.05, scale: `${pulse * inP}`, ...sticker(n === 6 ? "#ffd84d" : "#ffffff") }}>
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
      const t = k(f, s.at - 8, s.at, Easing.in(Easing.cubic));
      const o = 1 - k(f, s.at, s.at + 3);
      return (
        <AbsoluteFill key={i} style={{ alignItems: "center", justifyContent: "center", opacity: o }}>
          <div style={{ width: 2400 * t, height: 2400 * t, borderRadius: "50%", background: s.color, boxShadow: `0 0 0 ${40 * t}px ${s.deep}` }} />
        </AbsoluteFill>
      );
    })}
  </>
);

const Terms: React.FC<{ f: number }> = ({ f }) => {
  if (f < B.TERMS || f > B.END + 10) return null;
  const rows: [string, string, string][] = [
    ["🕚", "Har kuni 11:00 – 17:00", "#ffffff"],
    ["⏳", "Kupon 7 kun amal qiladi", "#ffd23f"],
    ["✅", "60 000 so'm va 1 soatdan", "#2be38b"],
    ["📅", "Aksiya 1-dekabrgacha", "#2aabee"],
  ];
  return (
    <Block top={300}>
      <Pop text="SHARTLAR" f={f} at={B.TERMS + 2} to={B.END - 8} size={120} />
      <div style={{ marginTop: 50, display: "flex", flexDirection: "column", gap: 34, alignItems: "center" }}>
        {rows.map(([icon, text, bg], i) => (
          <Label key={i} f={f} at={B.TERMS + 16 + i * 12} to={B.END - 8} bg={bg} tilt={i % 2 ? 3 : -3} size={50}>
            {icon} {text}
          </Label>
        ))}
      </div>
    </Block>
  );
};

const Final: React.FC<{ f: number }> = ({ f }) => {
  if (f < B.END) return null;
  const w = k(f, B.END + 4, B.END + 24, back);
  const b = k(f, B.END + 20, B.END + 38, back);
  const c = k(f, B.END + 36, B.END + 54, back);
  const beat = 1 + 0.05 * Math.max(0, Math.sin(((f - B.END) / 14) * Math.PI));
  const fade = k(f, B.LENGTH - 12, B.LENGTH);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <div style={{ position: "absolute", top: 330, scale: `${w}`, padding: "34px 50px", borderRadius: 50, background: "#0b0f0d", border: `8px solid ${ink}`, boxShadow: `0 14px 0 ${ink}`, rotate: "-3deg" }}>
        <Img src={staticFile("logo.png")} style={{ width: 700, display: "block" }} />
      </div>
      <div style={{ position: "absolute", top: 650, textAlign: "center", scale: `${b}` }}>
        <div style={{ display: "inline-block", padding: "10px 30px", borderRadius: 20, background: ink, color: "#fff", fontSize: 36, fontWeight: 900, letterSpacing: 8 }}>TELEGRAM BOT</div>
        <div style={{ fontSize: 84, fontWeight: 900, marginTop: 16, ...sticker("#ffffff") }}>@billionbiliard_bot</div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 900,
          scale: `${c * beat}`,
          padding: "32px 74px",
          borderRadius: 999,
          background: "#ffd23f",
          color: ink,
          border: `8px solid ${ink}`,
          boxShadow: `0 12px 0 ${ink}`,
          fontSize: 64,
          fontWeight: 900,
        }}
      >
        «START» ni bosing 👆
      </div>
      <div style={{ position: "absolute", top: 1110, scale: `${c}`, textAlign: "center", fontSize: 42, lineHeight: 1.5, fontWeight: 800, color: ink }}>
        📍 Ma'rifat ko'chasi 122, Angren
        <br />
        📞 +998 95 969 55 77
      </div>
      <AbsoluteFill style={{ background: "#000", opacity: fade }} />
    </AbsoluteFill>
  );
};

export const PromoBright: React.FC = () => {
  const f = useCurrentFrame();
  const scene = SCENES[sceneAt(f)];
  const flash = Math.max(interpolate(f, [B.GOLD, B.GOLD + 1, B.GOLD + 7], [0, 0.7, 0], clamp), interpolate(f, [B.COUPON - 3, B.COUPON, B.COUPON + 10], [0, 0.9, 0], clamp));
  return (
    <AbsoluteFill style={{ background: scene.color }}>
      <ThreeCanvas
        width={1080}
        height={1920}
        shadows
        camera={{ fov: 40, near: 0.03, far: 30, position: [0, 0.3, 2] }}
        gl={{ antialias: true, toneMapping: THREE.NeutralToneMapping, toneMappingExposure: 1.05 }}
      >
        <World f={f} />
      </ThreeCanvas>
      {/* sun rays behind the action, turning */}
      <AbsoluteFill
        style={{
          background: `repeating-conic-gradient(from ${f * 0.6}deg at 50% 55%, rgba(255,255,255,.10) 0deg 9deg, transparent 9deg 18deg)`,
          mixBlendMode: "soft-light",
          pointerEvents: "none",
        }}
      />

      {/* hook */}
      <Block top={300}>
        <Label f={f} at={4} to={B.RING - 8} bg="#ffffff" tilt={-5} size={46}>
          🎱 BILLION · BILYARD
        </Label>
        <div style={{ height: 30 }} />
        <Pop text="YANGI" f={f} at={10} to={B.RING - 8} size={190} />
        <Pop text="AKSIYA!" f={f} at={20} to={B.RING - 8} size={190} fill="#ff3d8b" />
      </Block>

      {/* visits */}
      <Counter f={f} />
      <Block top={1560}>
        <Label f={f} at={B.RING + 30} to={B.RING + 92} bg="#ffffff" tilt={-3}>⏱ 1 soatdan ko'p o'ynang</Label>
      </Block>
      <Block top={1560}>
        <Label f={f} at={B.RING + 100} to={B.GOLD - 6} bg="#ffd23f" tilt={3}>💳 60 000 so'mdan to'lov</Label>
      </Block>
      <Block top={1560}>
        <Label f={f} at={B.GOLD + 4} to={B.COUPON - 6} bg="#ffd84d" tilt={-4} size={62}>6-TASHRIF — SOVG'A! 🎁</Label>
      </Block>

      {/* coupon */}
      <Block top={190}>
        <Pop text="1 SOAT" f={f} at={B.COUPON + 18} to={B.PHONE - 8} size={170} fill="#ffd84d" />
        <Pop text="BEPUL!" f={f} at={B.COUPON + 28} to={B.PHONE - 8} size={150} />
      </Block>

      {/* bot */}
      <Block top={170}>
        <Pop text="KUPON" f={f} at={B.PHONE + 8} to={B.TERMS - 10} size={130} />
        <Pop text="BOTGA KELADI" f={f} at={B.PHONE + 16} to={B.TERMS - 10} size={100} stagger={1} fill="#ffd23f" />
      </Block>
      <Block top={1600}>
        <Label f={f} at={B.PHONE + 78} to={B.TERMS - 12} bg="#ffffff" tilt={-3}>Kassada ko'rsating! 😉</Label>
      </Block>

      <Terms f={f} />
      <Final f={f} />
      <Wipes f={f} />
      <AbsoluteFill style={{ background: "#fffbe8", opacity: flash, pointerEvents: "none" }} />
      <AbsoluteFill style={{ background: "#000", opacity: interpolate(f, [0, 4], [1, 0], clamp), pointerEvents: "none" }} />
    </AbsoluteFill>
  );
};
