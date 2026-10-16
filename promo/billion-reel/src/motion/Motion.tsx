import React, { useMemo } from "react";
import { AbsoluteFill, Easing, Img, interpolate, random, staticFile, useCurrentFrame } from "remotion";
import { ThreeCanvas } from "@remotion/three";
import * as THREE from "three";
import { useThree } from "@react-three/fiber";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { C, FONT } from "../theme";
import "../fonts";

/* "6 tashrif = 1 soat bepul" as 3D motion design: plain ivory balls (Russian
   billiards, no numbers), a ring of six slots, a gold coupon, a phone with
   the bot. Uzbek text. 30 fps, 32 s. */

export const M = {
  DROP: 0, // balls fall onto the floor
  RING: 96, // six slots, a ball for every visit
  GOLD: 304, // the sixth ball is gold
  FLASH: 372, // the balls whirl into a flash
  COUPON: 372, // the coupon spins out of it
  PHONE: 520, // into the bot
  TERMS: 690, // the conditions
  END: 810, // logo and call to action
  LENGTH: 960,
};

const R = 0.06; // ball radius
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const ease = Easing.bezier(0.65, 0, 0.35, 1);
const out = Easing.bezier(0.16, 1, 0.3, 1);
const k = (f: number, a: number, b: number, e = ease) => interpolate(f, [a, b], [0, 1], { ...clamp, easing: e });

const SLOT_R = 0.3;
const slotPos = (i: number): [number, number] => {
  const a = -Math.PI / 2 + (i / 6) * Math.PI * 2;
  return [Math.cos(a) * SLOT_R, Math.sin(a) * SLOT_R];
};
const ARRIVE = (i: number) => M.RING + 24 + i * 32 + 24; // frame ball i sits in its slot

/* ------------------------------------------------------------------ */
/* materials and textures                                              */
/* ------------------------------------------------------------------ */
function useMaterials() {
  return useMemo(
    () => ({
      ivory: new THREE.MeshPhysicalMaterial({
        color: "#f3ead3",
        roughness: 0.12,
        clearcoat: 1,
        clearcoatRoughness: 0.04,
        sheen: 0.2,
        envMapIntensity: 1.2,
      }),
      gold: new THREE.MeshPhysicalMaterial({
        color: "#e8b955",
        metalness: 1,
        roughness: 0.16,
        clearcoat: 0.6,
        envMapIntensity: 2.2,
        emissive: new THREE.Color("#7a4a08"),
        emissiveIntensity: 0.25,
      }),
      floor: new THREE.MeshStandardMaterial({ color: "#05100c", roughness: 0.32, metalness: 0.4 }),
    }),
    [],
  );
}

function canvas(w: number, h: number) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return c;
}

function couponFace() {
  const c = canvas(900, 1500);
  const g = c.getContext("2d")!;
  g.fillStyle = "rgba(52,32,4,.92)";
  g.textAlign = "center";
  g.font = "800 56px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("B I L L I O N   ·   K U P O N", 450, 170);
  g.font = "900 560px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("1", 450, 740);
  g.font = "900 200px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("SOAT", 450, 950);
  g.font = "900 120px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("BEPUL O'YIN", 450, 1100);
  g.setLineDash([26, 20]);
  g.lineWidth = 8;
  g.strokeStyle = "rgba(52,32,4,.4)";
  g.beginPath();
  g.moveTo(90, 1220);
  g.lineTo(810, 1220);
  g.stroke();
  g.font = "700 52px Inter, 'DejaVu Sans', sans-serif";
  g.globalAlpha = 0.8;
  g.fillText("6 ta tashrif uchun sovg'a", 450, 1340);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  return t;
}

function roundRect(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  g.beginPath();
  g.moveTo(x + r, y);
  g.arcTo(x + w, y, x + w, y + h, r);
  g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r);
  g.arcTo(x, y, x + w, y, r);
  g.closePath();
}

/** The phone screen: the club bot's chat with the coupon message. */
function phoneScreen(logo: HTMLImageElement | null) {
  const W = 720;
  const H = 1520;
  const c = canvas(W, H);
  const g = c.getContext("2d")!;
  g.fillStyle = "#0e1621";
  g.fillRect(0, 0, W, H);
  // header
  g.fillStyle = "#17212b";
  g.fillRect(0, 0, W, 190);
  g.fillStyle = "#e9eef2";
  g.font = "600 30px Inter, sans-serif";
  g.fillText("9:41", 48, 56);
  if (logo) {
    g.save();
    g.beginPath();
    g.arc(110, 128, 44, 0, Math.PI * 2);
    g.clip();
    g.drawImage(logo, 66, 84, 88, 88);
    g.restore();
  } else {
    g.fillStyle = "#e5b95c";
    g.beginPath();
    g.arc(110, 128, 44, 0, Math.PI * 2);
    g.fill();
  }
  g.fillStyle = "#f5f8f7";
  g.font = "700 36px Inter, sans-serif";
  g.fillText("Billion billiard", 176, 122);
  g.fillStyle = "#6ab3f3";
  g.font = "400 28px Inter, sans-serif";
  g.fillText("bot", 176, 160);
  // message bubble
  const x = 34;
  const y = 470;
  const w = W - 120;
  const h = 560;
  g.fillStyle = "#182533";
  roundRect(g, x, y, w, h, 34);
  g.fill();
  g.fillStyle = "#f5f8f7";
  g.font = "800 40px Inter, sans-serif";
  g.fillText("🎉 Tabriklaymiz!", x + 34, y + 76);
  g.font = "400 34px Inter, sans-serif";
  g.fillText("Siz klubga 6 marta", x + 34, y + 140);
  g.fillText("tashrif buyurdingiz.", x + 34, y + 186);
  g.font = "800 36px Inter, sans-serif";
  g.fillText("🎁 1 soat BEPUL o'yin", x + 34, y + 262);
  g.fillText("kuponi sizniki!", x + 34, y + 308);
  g.fillStyle = "#e5b95c";
  g.font = "800 36px Inter, sans-serif";
  g.fillText("🎟 Kod: 5CCE46", x + 34, y + 384);
  g.fillStyle = "#c4ced6";
  g.font = "400 30px Inter, sans-serif";
  g.fillText("🕚 Har kuni 11:00 – 17:00", x + 34, y + 446);
  g.fillText("⏳ 7 kun amal qiladi", x + 34, y + 494);
  // button
  g.fillStyle = "rgba(92,140,190,.3)";
  roundRect(g, x, y + h + 18, w, 96, 24);
  g.fill();
  g.fillStyle = "#f5f8f7";
  g.font = "700 32px Inter, sans-serif";
  g.textAlign = "center";
  g.fillText("🎟 Kassada ko'rsating", x + w / 2, y + h + 78);
  g.textAlign = "left";
  // input bar
  g.fillStyle = "#17212b";
  g.fillRect(0, H - 130, W, 130);
  g.fillStyle = "#6c7883";
  g.font = "400 32px Inter, sans-serif";
  g.fillText("Xabar", 60, H - 54);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  return t;
}

/* ------------------------------------------------------------------ */
/* the world                                                           */
/* ------------------------------------------------------------------ */
const Env: React.FC = () => {
  const { gl, scene } = useThree();
  useMemo(() => {
    const pm = new THREE.PMREMGenerator(gl);
    scene.environment = pm.fromScene(new RoomEnvironment(), 0.04).texture;
    scene.environmentIntensity = 0.55;
    scene.background = null;
  }, [gl, scene]);
  return null;
};

type Cam = { p: [number, number, number]; look: [number, number, number]; fov: number };
const lerp3 = (a: number[], b: number[], t: number) => a.map((v, i) => v + (b[i] - v) * t) as [number, number, number];

function cameraAt(f: number): Cam {
  if (f < M.RING) {
    // low dolly towards the line of balls
    const t = k(f, 0, M.RING);
    return { p: lerp3([0.0, 0.2, 2.1], [0.16, 0.26, 1.7], t), look: [0, 0.16, 0], fov: 40 };
  }
  if (f < M.FLASH) {
    // orbit above the ring, closing in
    const t = (f - M.RING) / (M.FLASH - M.RING);
    const a = 0.5 + t * 1.1;
    const dist = 1.25 - 0.15 * k(f, M.RING, M.GOLD);
    const h = 1.75 - 0.25 * t + 0.2 * k(f, M.GOLD, M.FLASH);
    // looking past the centre keeps the ring in the lower half, under the counter
    const ahead = 0.32;
    return {
      p: [Math.sin(a) * dist, h, Math.cos(a) * dist],
      look: [-Math.sin(a) * ahead, 0.02 + 0.2 * k(f, M.GOLD, M.FLASH), -Math.cos(a) * ahead],
      fov: 40,
    };
  }
  if (f < M.PHONE) {
    // face the coupon, slow push in
    const t = k(f, M.COUPON, M.PHONE);
    return { p: lerp3([0, 0.42, 1.95], [0.05, 0.42, 1.65], t), look: [0, 0.43, 0], fov: 34 };
  }
  if (f < M.TERMS) {
    const t = k(f, M.PHONE, M.TERMS);
    return { p: lerp3([-0.25, 0.44, 2.05], [0.08, 0.42, 1.9], t), look: [0, 0.47, 0], fov: 34 };
  }
  // terms and the end: drifting slowly around the floating balls
  const t = (f - M.TERMS) / (M.LENGTH - M.TERMS);
  const a = -0.4 + t * 0.9;
  return { p: [Math.sin(a) * 1.5, 0.5, Math.cos(a) * 1.5], look: [0, 0.3, 0], fov: 38 };
}

const Rig: React.FC<{ f: number }> = ({ f }) => {
  const { camera } = useThree();
  const c = cameraAt(f);
  // impacts shake the camera a little
  const hit = Math.max(
    interpolate(f, [M.GOLD, M.GOLD + 2, M.GOLD + 16], [0, 1, 0], clamp),
    interpolate(f, [M.FLASH, M.FLASH + 2, M.FLASH + 14], [0, 0.8, 0], clamp),
  );
  const cam = camera as THREE.PerspectiveCamera;
  cam.position.set(c.p[0] + Math.sin(f * 2.3) * 0.01 * hit, c.p[1] + Math.cos(f * 2.9) * 0.008 * hit, c.p[2]);
  cam.fov = c.fov;
  cam.lookAt(...c.look);
  cam.updateProjectionMatrix();
  return null;
};

const Ball: React.FC<{ p: [number, number, number]; mat: THREE.Material; s?: number }> = ({ p, mat, s = 1 }) => (
  <mesh position={p} scale={s} castShadow material={mat}>
    <sphereGeometry args={[R, 64, 48]} />
  </mesh>
);

/** A ring of light on the floor that grows and fades: the "ping" of an arrival. */
const Wave: React.FC<{ x: number; z: number; f: number; at: number; color: string; size?: number; dur?: number }> = ({
  x,
  z,
  f,
  at,
  color,
  size = 0.5,
  dur = 26,
}) => {
  if (f < at || f > at + dur) return null;
  const t = (f - at) / dur;
  return (
    <mesh position={[x, 0.002, z]} rotation={[-Math.PI / 2, 0, 0]} scale={0.05 + t * size}>
      <ringGeometry args={[0.9, 1, 96]} />
      <meshBasicMaterial color={color} transparent opacity={(1 - t) * 0.9} blending={THREE.AdditiveBlending} depthWrite={false} />
    </mesh>
  );
};

/** Scene 1: six ivory balls fall from above in a row and bounce. */
const Drop: React.FC<{ f: number; mats: ReturnType<typeof useMaterials> }> = ({ f, mats }) => (
  <group>
    {Array.from({ length: 6 }, (_, i) => {
      const start = 4 + i * 6;
      const t = Math.max(0, (f - start) / 30);
      // fall then damped bounces
      let y: number;
      if (t < 0.45) y = 1.3 * (1 - (t / 0.45) ** 2);
      else {
        const u = t - 0.45;
        y = Math.abs(Math.sin(u * 9)) * 0.22 * Math.exp(-u * 4.2);
      }
      const x = -0.325 + i * 0.13;
      return <Ball key={i} p={[x, R + Math.max(0, y), 0]} mat={mats.ivory} />;
    })}
    {Array.from({ length: 6 }, (_, i) => (
      <Wave key={i} x={-0.325 + i * 0.13} z={0} f={f} at={4 + i * 6 + 13} color="#39efad" size={0.22} dur={20} />
    ))}
  </group>
);

/** Scene 2-3: the ring of six slots; a ball rolls into each, the sixth is gold. */
const Ring: React.FC<{ f: number; mats: ReturnType<typeof useMaterials> }> = ({ f, mats }) => {
  const whirl = k(f, M.GOLD + 18, M.FLASH, Easing.in(Easing.cubic));
  return (
    <group>
      {Array.from({ length: 6 }, (_, i) => {
        const [sx, sz] = slotPos(i);
        const lit = f >= ARRIVE(i);
        const goldAll = f >= M.GOLD;
        const glow = lit ? 0.6 + 0.4 * Math.exp(-(f - ARRIVE(i)) / 10) : 0.12;
        return (
          <mesh key={`s${i}`} position={[sx, 0.003, sz]} rotation={[-Math.PI / 2, 0, 0]}>
            <ringGeometry args={[R * 1.25, R * 1.45, 64]} />
            <meshBasicMaterial
              color={goldAll ? "#ffcf6a" : "#39efad"}
              transparent
              opacity={glow * (1 - whirl)}
              blending={THREE.AdditiveBlending}
              depthWrite={false}
            />
          </mesh>
        );
      })}
      {Array.from({ length: 6 }, (_, i) => {
        const start = ARRIVE(i) - 24;
        if (f < start) return null;
        const [sx, sz] = slotPos(i);
        // rolls in along a spiral from outside
        const t = k(f, start, ARRIVE(i), out);
        const a0 = Math.atan2(sz, sx) - 1.4;
        const a = a0 + (Math.atan2(sz, sx) - a0) * t;
        const r = SLOT_R + (1 - t) * 0.9;
        let x = Math.cos(a) * r;
        let z = Math.sin(a) * r;
        let y = R;
        // then the whirl: rise and spin into the centre
        if (whirl > 0) {
          const wa = Math.atan2(z, x) + whirl * whirl * 9;
          const wr = Math.hypot(x, z) * (1 - whirl);
          x = Math.cos(wa) * wr;
          z = Math.sin(wa) * wr;
          y = R + whirl * 0.34;
        }
        return <Ball key={i} p={[x, y, z]} mat={i === 5 ? mats.gold : mats.ivory} s={1 - whirl * 0.6} />;
      })}
      {Array.from({ length: 6 }, (_, i) => {
        const [sx, sz] = slotPos(i);
        return <Wave key={`w${i}`} x={sx} z={sz} f={f} at={ARRIVE(i)} color={i === 5 ? "#ffcf6a" : "#39efad"} size={i === 5 ? 1.6 : 0.4} dur={i === 5 ? 34 : 24} />;
      })}
    </group>
  );
};

/** Gold and green bits flying out of the flash. */
const Confetti: React.FC<{ f: number; at: number }> = ({ f, at }) => {
  const N = 140;
  const ref = React.useRef<THREE.InstancedMesh>(null);
  const seeds = useMemo(
    () =>
      Array.from({ length: N }, (_, i) => ({
        v: [random(`cx${i}`) * 2 - 1, random(`cy${i}`) * 1.4 + 0.4, random(`cz${i}`) * 2 - 1],
        s: 0.6 + random(`cs${i}`) * 0.9,
        r: random(`cr${i}`) * 10,
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
      o.position.set(sd.v[0] * tt * 0.9, 0.34 + sd.v[1] * tt * 0.9 - 0.9 * tt * tt, sd.v[2] * tt * 0.6);
      o.rotation.set(sd.r + tt * 6, sd.r * 2 + tt * 4, 0);
      o.scale.setScalar(tt > 0 ? sd.s : 0.0001);
      o.updateMatrix();
      m.setMatrixAt(i, o.matrix);
      m.setColorAt(i, new THREE.Color(i % 3 === 0 ? "#39efad" : i % 3 === 1 ? "#ffd27a" : "#f5f1e4"));
    });
    m.instanceMatrix.needsUpdate = true;
    if (m.instanceColor) m.instanceColor.needsUpdate = true;
  });
  if (f < at || f > at + 70) return null;
  return (
    <instancedMesh ref={ref} args={[undefined, undefined, N]}>
      <planeGeometry args={[0.018, 0.03]} />
      <meshStandardMaterial side={THREE.DoubleSide} metalness={0.6} roughness={0.3} emissive="#3a2a08" />
    </instancedMesh>
  );
};

function couponShape(w: number, h: number, r: number, notch: number) {
  const s = new THREE.Shape();
  s.moveTo(-w / 2 + r, -h / 2);
  s.lineTo(w / 2 - r, -h / 2);
  s.quadraticCurveTo(w / 2, -h / 2, w / 2, -h / 2 + r);
  s.lineTo(w / 2, -notch);
  s.absarc(w / 2, 0, notch, -Math.PI / 2, Math.PI / 2, true);
  s.lineTo(w / 2, h / 2 - r);
  s.quadraticCurveTo(w / 2, h / 2, w / 2 - r, h / 2);
  s.lineTo(-w / 2 + r, h / 2);
  s.quadraticCurveTo(-w / 2, h / 2, -w / 2, h / 2 - r);
  s.lineTo(-w / 2, notch);
  s.absarc(-w / 2, 0, notch, Math.PI / 2, -Math.PI / 2, true);
  s.lineTo(-w / 2, -h / 2 + r);
  s.quadraticCurveTo(-w / 2, -h / 2, -w / 2 + r, -h / 2);
  return s;
}

/** Scene 4-5: the coupon spins out of the flash, then flies into the phone. */
const Coupon: React.FC<{ f: number; mats: ReturnType<typeof useMaterials> }> = ({ f, mats }) => {
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
  if (f < M.COUPON || f > M.PHONE + 70) return null;
  const pop = k(f, M.COUPON, M.COUPON + 40, out);
  const spin = (1 - k(f, M.COUPON, M.COUPON + 70, out)) * Math.PI * 5 + Math.sin(f / 24) * 0.18;
  // into the phone screen
  const fly = k(f, M.PHONE + 30, M.PHONE + 64, Easing.in(Easing.cubic));
  const s = (0.2 + 0.8 * pop) * (1 - fly * 0.85);
  const y = 0.34 + Math.sin(f / 20) * 0.01 - fly * 0.02;
  const z = fly * 0.06;
  return (
    <group position={[0, y, z]} rotation={[0, spin, Math.sin(f / 30) * 0.05]} scale={s}>
      <mesh geometry={geo} castShadow material={mats.gold} />
      <mesh position={[0, 0, 0.0075]}>
        <planeGeometry args={[W * 0.97, H * 0.97]} />
        <meshStandardMaterial map={face} transparent roughness={0.4} metalness={0.3} />
      </mesh>
    </group>
  );
};

/** Six ivory balls circling the coupon / logo. */
const Orbit: React.FC<{ f: number; mats: ReturnType<typeof useMaterials>; from: number; y: number; r: number }> = ({ f, mats, from, y, r }) => {
  const p = k(f, from, from + 30, out);
  if (p <= 0) return null;
  return (
    <group>
      {Array.from({ length: 6 }, (_, i) => {
        const a = (i / 6) * Math.PI * 2 + f * 0.03;
        // a tilted ring: the balls pass below the card in front and above it behind
        const z = Math.sin(a) * r * p;
        return <Ball key={i} p={[Math.cos(a) * r * p, y - z * 0.55, z]} mat={i === 0 ? mats.gold : mats.ivory} s={0.7} />;
      })}
    </group>
  );
};

const PhoneMesh: React.FC<{ f: number }> = ({ f }) => {
  const body = useMemo(() => new RoundedBoxGeometry(0.34, 0.7, 0.03, 6, 0.045), []);
  const [logo, setLogo] = React.useState<HTMLImageElement | null>(null);
  React.useEffect(() => {
    const im = new Image();
    im.onload = () => setLogo(im);
    im.src = staticFile("logo_square.jpg");
  }, []);
  const screen = useMemo(() => phoneScreen(logo), [logo]);
  if (f < M.PHONE || f > M.TERMS + 20) return null;
  const inP = k(f, M.PHONE, M.PHONE + 34, out);
  const outP = k(f, M.TERMS - 10, M.TERMS + 20, Easing.in(Easing.cubic));
  // the message appears when the coupon lands in it
  const msg = k(f, M.PHONE + 60, M.PHONE + 76, out);
  return (
    <group position={[0, 0.36 - (1 - inP) * 0.9 + outP * 0.9, -0.02]} rotation={[0, (1 - inP) * -1.4 + Math.sin(f / 40) * 0.08, (1 - inP) * 0.3]}>
      <mesh geometry={body}>
        <meshPhysicalMaterial color="#0b0e12" metalness={0.6} roughness={0.25} clearcoat={1} />
      </mesh>
      <mesh position={[0, 0, 0.0155]}>
        <planeGeometry args={[0.315, 0.665]} />
        <meshBasicMaterial map={screen} toneMapped={false} transparent opacity={0.25 + 0.75 * msg} />
      </mesh>
      {/* notification glow */}
      <mesh position={[0, 0.02, 0.016]}>
        <planeGeometry args={[0.36, 0.72]} />
        <meshBasicMaterial color="#39efad" transparent opacity={interpolate(f, [M.PHONE + 60, M.PHONE + 64, M.PHONE + 90], [0, 0.35, 0], clamp)} blending={THREE.AdditiveBlending} depthWrite={false} />
      </mesh>
    </group>
  );
};

/** The conditions and the end: balls floating in the dark. */
const Float: React.FC<{ f: number; mats: ReturnType<typeof useMaterials> }> = ({ f, mats }) => {
  if (f < M.TERMS - 10) return null;
  const p = k(f, M.TERMS - 10, M.TERMS + 30, out);
  return (
    <group>
      {Array.from({ length: 14 }, (_, i) => {
        const x = (random(`fx${i}`) - 0.5) * 1.6;
        const z = (random(`fz${i}`) - 0.5) * 1.2 - 0.3;
        const y = 0.1 + random(`fy${i}`) * 0.7 + Math.sin(f / 30 + i) * 0.03;
        return <Ball key={i} p={[x, y * p + (1 - p) * -0.4, z]} mat={i % 7 === 0 ? mats.gold : mats.ivory} s={0.6 + random(`fs${i}`) * 0.5} />;
      })}
    </group>
  );
};

const World: React.FC<{ f: number }> = ({ f }) => {
  const mats = useMaterials();
  return (
    <>
      <Env />
      <Rig f={f} />
      <ambientLight intensity={0.15} />
      <spotLight position={[0.3, 2.4, 0.8]} angle={0.55} penumbra={0.8} intensity={30} color="#fff1dc" castShadow shadow-mapSize={[2048, 2048]} shadow-bias={-0.0004} />
      <pointLight position={[-1.1, 0.5, -0.4]} intensity={2.4} distance={3} color="#39efad" />
      <pointLight position={[1.1, 0.6, 0.6]} intensity={1.8} distance={3} color="#ffc56b" />
      <mesh rotation={[-Math.PI / 2, 0, 0]} receiveShadow material={mats.floor}>
        <circleGeometry args={[6, 96]} />
      </mesh>
      {f < M.RING + 6 ? <Drop f={f} mats={mats} /> : null}
      {f >= M.RING - 4 && f < M.FLASH + 2 ? <Ring f={f} mats={mats} /> : null}
      <Confetti f={f} at={M.FLASH} />
      <Coupon f={f} mats={mats} />
      {f >= M.COUPON && f < M.PHONE + 30 ? <Orbit f={f} mats={mats} from={M.COUPON + 20} y={0.36} r={0.5} /> : null}
      <PhoneMesh f={f} />
      <Float f={f} mats={mats} />
    </>
  );
};

/* ------------------------------------------------------------------ */
/* type and overlays                                                   */
/* ------------------------------------------------------------------ */
const goldText: React.CSSProperties = {
  background: "linear-gradient(180deg,#fff3cc 0%,#e8b955 55%,#b5832b 100%)",
  WebkitBackgroundClip: "text",
  color: "transparent",
};

/** Letters pop in one after another, then the word slides out. */
const Kinetic: React.FC<{ text: string; f: number; at: number; to: number; size: number; style?: React.CSSProperties; stagger?: number }> = ({
  text,
  f,
  at,
  to,
  size,
  style,
  stagger = 2,
}) => {
  if (f < at || f > to + 12) return null;
  const leave = k(f, to, to + 12, Easing.in(Easing.cubic));
  return (
    <div style={{ display: "flex", justifyContent: "center", flexWrap: "wrap", opacity: 1 - leave, translate: `0 ${-leave * 40}px` }}>
      {[...text].map((ch, i) => {
        const p = k(f, at + i * stagger, at + i * stagger + 12, Easing.out(Easing.back(2.2)));
        return (
          <span
            key={i}
            style={{
              display: "inline-block",
              whiteSpace: "pre",
              fontSize: size,
              fontWeight: 900,
              letterSpacing: -2,
              color: "#f5f8f7",
              opacity: Math.min(1, p * 1.4),
              scale: `${0.3 + 0.7 * p}`,
              translate: `0 ${(1 - p) * 60}px`,
              textShadow: "0 12px 50px rgba(0,0,0,.6)",
              ...style,
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
  <div style={{ position: "absolute", top, left: 40, right: 40, textAlign: "center", fontFamily: FONT }}>{children}</div>
);

const Tag: React.FC<{ f: number; at: number; to: number; children: React.ReactNode; color?: string }> = ({ f, at, to, children, color = C.green }) => {
  if (f < at || f > to + 10) return null;
  const p = k(f, at, at + 14, out);
  const o = 1 - k(f, to, to + 10);
  return (
    <div
      style={{
        display: "inline-block",
        padding: "18px 34px",
        borderRadius: 999,
        background: "rgba(5,16,12,.72)",
        border: `2px solid ${color}`,
        color: "#f5f8f7",
        fontSize: 44,
        fontWeight: 800,
        opacity: p * o,
        scale: `${0.7 + 0.3 * p}`,
        boxShadow: `0 0 40px ${color}55`,
      }}
    >
      {children}
    </div>
  );
};

const Counter: React.FC<{ f: number }> = ({ f }) => {
  if (f < M.RING + 10 || f > M.FLASH) return null;
  let n = 0;
  for (let i = 0; i < 6; i++) if (f >= ARRIVE(i)) n = i + 1;
  const last = n > 0 ? ARRIVE(n - 1) : -99;
  const pulse = interpolate(f, [last, last + 3, last + 14], [1.4, 1.4, 1], { ...clamp, easing: Easing.out(Easing.back(2)) });
  const inP = k(f, M.RING + 10, M.RING + 26, out);
  const done = n === 6;
  return (
    <Block top={200}>
      <div style={{ opacity: inP, fontSize: 32, fontWeight: 800, letterSpacing: 14, color: "rgba(230,240,236,.85)" }}>TASHRIFLAR</div>
      <div style={{ opacity: inP, fontSize: 230, fontWeight: 900, lineHeight: 1, letterSpacing: -6, color: "#f5f8f7", scale: `${pulse}`, ...(done ? goldText : {}) }}>
        {n}
        <span style={{ fontSize: 120, color: done ? undefined : "rgba(245,248,247,.4)" }}>/6</span>
      </div>
    </Block>
  );
};

const Flash: React.FC<{ f: number }> = ({ f }) => {
  const o = Math.max(
    interpolate(f, [M.FLASH - 6, M.FLASH, M.FLASH + 14], [0, 1, 0], clamp),
    interpolate(f, [M.GOLD, M.GOLD + 1, M.GOLD + 8], [0, 0.5, 0], clamp),
    interpolate(f, [M.RING - 4, M.RING, M.RING + 8], [0, 0.7, 0], clamp),
  );
  return <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 50%, #fff8e6, rgba(255,226,160,.7) 45%, rgba(255,210,120,.2))", opacity: o }} />;
};

const Backdrop: React.FC<{ f: number }> = ({ f }) => {
  // the light behind the scene follows the story: green, gold, telegram blue, green
  const gold = k(f, M.GOLD - 10, M.GOLD + 20) * (1 - k(f, M.PHONE - 10, M.PHONE + 20));
  const blue = k(f, M.PHONE - 10, M.PHONE + 20) * (1 - k(f, M.TERMS - 10, M.TERMS + 20));
  const a = `rgba(${Math.round(30 + 200 * gold - 10 * blue)},${Math.round(190 - 20 * gold - 40 * blue)},${Math.round(130 - 60 * gold + 110 * blue)},.38)`;
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(circle at ${50 + Math.sin(f / 50) * 12}% ${42 + Math.cos(f / 60) * 6}%, ${a}, transparent 55%), radial-gradient(circle at 50% 120%, rgba(57,239,173,.12), transparent 50%), #030806`,
      }}
    />
  );
};

const Terms: React.FC<{ f: number }> = ({ f }) => {
  if (f < M.TERMS || f > M.END + 10) return null;
  const rows: [string, string][] = [
    ["🕚", "Har kuni 11:00 – 17:00"],
    ["⏳", "Kupon 7 kun amal qiladi"],
    ["✅", "60 000 so'm va 1 soatdan"],
    ["📅", "Aksiya 1-dekabrgacha"],
  ];
  const leave = k(f, M.END - 6, M.END + 10, Easing.in(Easing.cubic));
  return (
    <Block top={330}>
      <Kinetic text="SHARTLAR" f={f} at={M.TERMS + 2} to={M.END - 6} size={96} style={goldText} />
      <div style={{ marginTop: 50, display: "flex", flexDirection: "column", gap: 26, alignItems: "center", opacity: 1 - leave }}>
        {rows.map(([icon, text], i) => {
          const p = k(f, M.TERMS + 16 + i * 12, M.TERMS + 34 + i * 12, out);
          return (
            <div
              key={i}
              style={{
                display: "flex",
                gap: 22,
                alignItems: "center",
                width: 860,
                padding: "30px 40px",
                borderRadius: 34,
                background: "linear-gradient(135deg, rgba(16,30,26,.88), rgba(8,16,14,.88))",
                border: "1px solid rgba(57,239,173,.28)",
                boxShadow: "0 30px 80px rgba(0,0,0,.5)",
                fontSize: 50,
                fontWeight: 800,
                color: "#f5f8f7",
                opacity: p,
                translate: `${(1 - p) * (i % 2 ? 260 : -260)}px 0`,
                rotate: `${(1 - p) * (i % 2 ? 6 : -6)}deg`,
              }}
            >
              <span style={{ fontSize: 58 }}>{icon}</span>
              {text}
            </div>
          );
        })}
      </div>
    </Block>
  );
};

const Final: React.FC<{ f: number }> = ({ f }) => {
  if (f < M.END) return null;
  const w = k(f, M.END + 4, M.END + 28, out);
  const b = k(f, M.END + 24, M.END + 44, out);
  const c = k(f, M.END + 44, M.END + 64, out);
  const beat = 1 + 0.04 * Math.max(0, Math.sin(((f - M.END) / 15) * Math.PI));
  const fadeEnd = k(f, M.LENGTH - 14, M.LENGTH);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 40%, rgba(0,0,0,.1), rgba(0,0,0,.7) 70%)" }} />
      <Img src={staticFile("logo.png")} style={{ position: "absolute", top: 360, width: 800, mixBlendMode: "lighten", opacity: w, scale: `${0.8 + 0.2 * w}`, filter: `blur(${(1 - w) * 14}px)` }} />
      <div style={{ position: "absolute", top: 640, textAlign: "center", opacity: b, translate: `0 ${(1 - b) * 30}px` }}>
        <div style={{ fontSize: 32, fontWeight: 800, letterSpacing: 12, color: "rgba(230,240,236,.85)" }}>TELEGRAM BOT</div>
        <div style={{ fontSize: 72, fontWeight: 900, color: C.green, marginTop: 14, textShadow: "0 0 44px rgba(57,239,173,.55)" }}>@billionbiliard_bot</div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 880,
          opacity: c,
          scale: `${(0.8 + 0.2 * c) * beat}`,
          padding: "32px 70px",
          borderRadius: 44,
          background: "linear-gradient(135deg,#5affc1,#18d993)",
          color: "#022d20",
          fontSize: 54,
          fontWeight: 900,
          boxShadow: "0 30px 90px rgba(21,222,147,.4)",
        }}
      >
        «Start» ni bosing
      </div>
      <div style={{ position: "absolute", top: 1080, opacity: c, textAlign: "center", fontSize: 38, lineHeight: 1.55, color: "#d2dad7", fontWeight: 600 }}>
        📍 Ma'rifat ko'chasi 122, Angren
        <br />
        📞 +998 95 969 55 77
      </div>
      <AbsoluteFill style={{ background: "#000", opacity: fadeEnd }} />
    </AbsoluteFill>
  );
};

export const PromoMotion: React.FC = () => {
  const f = useCurrentFrame();
  const blurEnd = interpolate(f, [M.END - 4, M.END + 20], [0, 8], clamp);
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <Backdrop f={f} />
      <AbsoluteFill style={{ filter: blurEnd ? `blur(${blurEnd}px) brightness(.75)` : undefined }}>
        <ThreeCanvas
          width={1080}
          height={1920}
          shadows
          camera={{ fov: 36, near: 0.03, far: 30, position: [0, 0.3, 1.5] }}
          gl={{ antialias: true, alpha: true, toneMapping: THREE.ACESFilmicToneMapping, toneMappingExposure: 1.0 }}
        >
          <World f={f} />
        </ThreeCanvas>
      </AbsoluteFill>

      {/* 1: hook */}
      <Block top={330}>
        <Kinetic text="BILLION" f={f} at={6} to={88} size={44} stagger={1} style={{ letterSpacing: 18, fontWeight: 800, color: "rgba(230,240,236,.85)" }} />
        <div style={{ height: 16 }} />
        <Kinetic text="YANGI" f={f} at={14} to={88} size={150} />
        <Kinetic text="AKSIYA" f={f} at={24} to={88} size={150} style={goldText} />
      </Block>

      {/* 2: visits */}
      <Counter f={f} />
      <Block top={560}>
        <Tag f={f} at={M.RING + 40} to={M.RING + 120}>⏱ 1 soatdan ko'p o'ynang</Tag>
      </Block>
      <Block top={560}>
        <Tag f={f} at={M.RING + 134} to={M.GOLD - 6} color={C.gold}>💳 60 000 so'mdan to'lov</Tag>
      </Block>
      <Block top={560}>
        <Tag f={f} at={M.GOLD + 4} to={M.FLASH - 4} color={C.gold}>6-tashrif — SOVG'A! 🎁</Tag>
      </Block>

      {/* 3: coupon */}
      <Block top={230}>
        <Kinetic text="1 SOAT" f={f} at={M.COUPON + 26} to={M.PHONE - 8} size={140} style={goldText} />
        <Kinetic text="O'YIN BEPUL" f={f} at={M.COUPON + 36} to={M.PHONE - 8} size={100} />
      </Block>

      {/* 4: bot */}
      <Block top={190}>
        <Kinetic text="Kupon" f={f} at={M.PHONE + 10} to={M.TERMS - 10} size={110} />
        <Kinetic text="botga keladi" f={f} at={M.PHONE + 18} to={M.TERMS - 10} size={96} style={{ color: "#6ab3f3" }} />
      </Block>
      <Block top={1520}>
        <Tag f={f} at={M.PHONE + 80} to={M.TERMS - 12} color="#6ab3f3">Kassada ko'rsating — bepul o'ynang!</Tag>
      </Block>

      <Terms f={f} />
      <Final f={f} />
      <Flash f={f} />
      <AbsoluteFill style={{ background: "radial-gradient(ellipse at 50% 45%, transparent 45%, rgba(0,0,0,.55) 85%, rgba(0,0,0,.85))", pointerEvents: "none" }} />
      <AbsoluteFill style={{ background: "#000", opacity: interpolate(f, [0, 6], [1, 0], clamp), pointerEvents: "none" }} />
    </AbsoluteFill>
  );
};
