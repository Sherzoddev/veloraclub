import React, { useMemo } from "react";
import * as THREE from "three";
import { useThree } from "@react-three/fiber";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import { BALL_R, DT, simulateBreak, TABLE } from "./physics";

export const FPS = 30;

/* ------------------------------------------------------------------ */
/* textures                                                            */
/* ------------------------------------------------------------------ */
function canvas(w: number, h: number) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return c;
}

/** Fine woven grain for the cloth, used as a bump map. */
function useClothBump() {
  return useMemo(() => {
    const c = canvas(512, 512);
    const g = c.getContext("2d")!;
    const img = g.createImageData(512, 512);
    let seed = 7;
    const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    for (let i = 0; i < 512 * 512; i++) {
      const x = i % 512;
      const y = (i / 512) | 0;
      const weave = 0.5 + 0.18 * Math.sin(x * 1.9) * Math.sin(y * 1.9);
      const v = Math.max(0, Math.min(1, weave + (rnd() - 0.5) * 0.35)) * 255;
      img.data[i * 4] = img.data[i * 4 + 1] = img.data[i * 4 + 2] = v;
      img.data[i * 4 + 3] = 255;
    }
    g.putImageData(img, 0, 0);
    const t = new THREE.CanvasTexture(c);
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(6, 3);
    return t;
  }, []);
}


/** Russian billiards: every ball is ivory with its number printed twice in
 *  black; the cue ball ("биток") is a warmer cream with red dots. */
function ballTexture(base: string, n: number, opts: { dots?: string; ink?: string } = {}) {
  const c = canvas(512, 256);
  const g = c.getContext("2d")!;
  // a faint warm gradient so the ivory does not look like flat plastic
  const grad = g.createLinearGradient(0, 0, 0, 256);
  grad.addColorStop(0, base);
  grad.addColorStop(0.5, base);
  grad.addColorStop(1, base);
  g.fillStyle = grad;
  g.fillRect(0, 0, 512, 256);
  if (n > 0) {
    for (const u of [128, 384]) {
      g.fillStyle = opts.ink ?? "#141210";
      g.font = "800 78px Inter, Arial, sans-serif";
      g.textAlign = "center";
      g.textBaseline = "middle";
      g.fillText(String(n), u, 132);
      if (n === 6 || n === 9) g.fillRect(u - 20, 172, 40, 7);
    }
  }
  if (opts.dots) {
    g.fillStyle = opts.dots;
    for (const [u, v] of [[128, 128], [384, 128], [256, 40], [0, 128], [512, 128], [256, 216]] as const) {
      g.beginPath();
      g.arc(u, v, 11, 0, Math.PI * 2);
      g.fill();
    }
  }
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  return t;
}

const IVORY = "#f2ead6";

export function useBallTextures() {
  return useMemo(
    () => ({
      cue: ballTexture("#f3dfae", 0, { dots: "#c4262b" }),
      numbered: Array.from({ length: 15 }, (_, i) => ballTexture(IVORY, i + 1)),
      six: Array.from({ length: 6 }, (_, i) => ballTexture(IVORY, i + 1)),
      gold: ballTexture("#e5b95c", 6, { ink: "#5a3c0c" }),
    }),
    [],
  );
}

/* ------------------------------------------------------------------ */
/* environment, lamp, room                                             */
/* ------------------------------------------------------------------ */
export const Environment: React.FC<{ exposure?: number }> = ({ exposure = 0.1 }) => {
  const { gl, scene } = useThree();
  React.useMemo(() => {
    const pm = new THREE.PMREMGenerator(gl);
    const env = pm.fromScene(new RoomEnvironment(), 0.04).texture;
    scene.environment = env;
    scene.environmentIntensity = exposure;
    scene.background = new THREE.Color("#020607");
    scene.fog = new THREE.FogExp2("#020708", 0.6);
  }, [gl, scene, exposure]);
  return null;
};

/** The lamp over the table: a warm spot, a faint cone of light and drifting dust. */
export const Lamp: React.FC<{ intensity: number; frame: number }> = ({ intensity, frame }) => {
  const dust = useMemo(() => {
    let seed = 3;
    const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    return Array.from({ length: 140 }, () => ({
      x: (rnd() - 0.5) * 1.5,
      y: 0.9 + rnd() * 1.4,
      z: (rnd() - 0.5) * 1.1,
      s: 0.002 + rnd() * 0.004,
      p: rnd() * 6.28,
    }));
  }, []);
  const coneMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        side: THREE.DoubleSide,
        uniforms: { k: { value: 0 } },
        vertexShader: "varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0);} ",
        fragmentShader:
          "varying vec2 vUv; uniform float k; void main(){ float a = pow(1.0 - vUv.y, 1.6) * 0.085 * k; gl_FragColor = vec4(1.0,0.82,0.55,a);} ",
      }),
    [],
  );
  coneMat.uniforms.k.value = intensity;
  return (
    <group>
      <spotLight
        position={[0, 2.2, 0]}
        target-position={[0, 0, 0]}
        angle={0.5}
        penumbra={0.9}
        intensity={22 * intensity}
        decay={2}
        color="#ffd9a3"
        castShadow
        shadow-mapSize={[2048, 2048]}
        shadow-bias={-0.0004}
        shadow-radius={5}
      />
      <pointLight position={[1.6, 0.7, -1.2]} intensity={1.6 * intensity} color="#3fe6b0" distance={2.2} decay={2} />
      <pointLight position={[-1.8, 0.5, 1.3]} intensity={0.9 * intensity} color="#ff9a4a" distance={2.2} decay={2} />
      <mesh position={[0, 1.1, 0]} material={coneMat}>
        <cylinderGeometry args={[0.04, 1.25, 2.2, 48, 1, true]} />
      </mesh>
      <mesh position={[0, 2.23, 0]}>
        <cylinderGeometry args={[0.06, 0.3, 0.14, 32]} />
        <meshStandardMaterial color="#0c1210" roughness={0.5} metalness={0.6} emissive="#ffcf8a" emissiveIntensity={2.2 * intensity} />
      </mesh>
      {dust.map((d, i) => (
        <mesh key={i} position={[d.x + Math.sin(frame / 90 + d.p) * 0.05, d.y - ((frame * d.s) % 1.2) + 0.6, d.z]}>
          <sphereGeometry args={[0.0022, 6, 6]} />
          <meshBasicMaterial color="#ffe2b0" transparent opacity={0.5 * intensity} />
        </mesh>
      ))}
      <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, 0, 0]} receiveShadow>
        <circleGeometry args={[2.4, 48]} />
        <meshStandardMaterial color="#000000" roughness={1} metalness={0} />
      </mesh>
    </group>
  );
};

/* ------------------------------------------------------------------ */
/* the table                                                           */
/* ------------------------------------------------------------------ */
export const Table: React.FC = () => {
  const bump = useClothBump();
  const { L, W, rail, height } = TABLE;
  const wood = { color: "#2e170d", roughness: 0.38, metalness: 0.05 } as const;
  return (
    <group position={[0, height, 0]}>
      {/* cloth */}
      <mesh rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
        <planeGeometry args={[L + 0.1, W + 0.1]} />
        <meshStandardMaterial color="#04442e" roughness={0.95} bumpMap={bump} bumpScale={1.2} />
      </mesh>
      {/* cushions */}
      {[
        [0, -(W / 2 + 0.025), L + 0.1, 0.05],
        [0, W / 2 + 0.025, L + 0.1, 0.05],
      ].map(([x, z, w, d], i) => (
        <mesh key={`cz${i}`} position={[x as number, 0.018, z as number]} castShadow receiveShadow>
          <boxGeometry args={[w as number, 0.045, d as number]} />
          <meshStandardMaterial color="#0a6a47" roughness={0.9} />
        </mesh>
      ))}
      {[-(L / 2 + 0.025), L / 2 + 0.025].map((x, i) => (
        <mesh key={`cx${i}`} position={[x, 0.018, 0]} castShadow receiveShadow>
          <boxGeometry args={[0.05, 0.045, W + 0.1]} />
          <meshStandardMaterial color="#0a6a47" roughness={0.9} />
        </mesh>
      ))}
      {/* wooden frame */}
      <mesh position={[0, 0.02, -(W / 2 + 0.05 + rail / 2)]} castShadow receiveShadow>
        <boxGeometry args={[L + 0.1 + rail * 2, 0.1, rail]} />
        <meshStandardMaterial {...wood} />
      </mesh>
      <mesh position={[0, 0.02, W / 2 + 0.05 + rail / 2]} castShadow receiveShadow>
        <boxGeometry args={[L + 0.1 + rail * 2, 0.1, rail]} />
        <meshStandardMaterial {...wood} />
      </mesh>
      {[-1, 1].map((s) => (
        <mesh key={s} position={[s * (L / 2 + 0.05 + rail / 2), 0.02, 0]} castShadow receiveShadow>
          <boxGeometry args={[rail, 0.1, W + 0.1]} />
          <meshStandardMaterial {...wood} />
        </mesh>
      ))}
      {/* pockets */}
      {[
        [-1, -1],
        [1, -1],
        [-1, 1],
        [1, 1],
      ].map(([sx, sz], i) => (
        <mesh key={`p${i}`} position={[sx * (L / 2 + 0.01), 0.004, sz * (W / 2 + 0.01)]} rotation={[-Math.PI / 2, 0, 0]}>
          <circleGeometry args={[0.062, 28]} />
          <meshBasicMaterial color="#000" />
        </mesh>
      ))}
      {[-1, 1].map((sz) => (
        <mesh key={`m${sz}`} position={[0, 0.004, sz * (W / 2 + 0.016)]} rotation={[-Math.PI / 2, 0, 0]}>
          <circleGeometry args={[0.062, 28]} />
          <meshBasicMaterial color="#000" />
        </mesh>
      ))}
      {/* legs */}
      {[-1, 1].flatMap((sx) =>
        [-1, 1].map((sz) => (
          <mesh key={`${sx}${sz}`} position={[sx * (L / 2 + 0.02), -height / 2, sz * (W / 2 + 0.02)]} castShadow>
            <boxGeometry args={[0.16, height, 0.16]} />
            <meshStandardMaterial {...wood} />
          </mesh>
        )),
      )}
    </group>
  );
};

/* ------------------------------------------------------------------ */
/* balls                                                               */
/* ------------------------------------------------------------------ */
export const Ball: React.FC<{
  position: [number, number, number];
  quaternion?: [number, number, number, number];
  map: THREE.Texture;
  emissive?: string;
  emissiveIntensity?: number;
  gold?: boolean;
}> = ({ position, quaternion, map, emissive, emissiveIntensity = 0, gold }) => (
  <mesh position={position} quaternion={quaternion ? new THREE.Quaternion(...quaternion) : undefined} castShadow receiveShadow>
    <sphereGeometry args={[BALL_R, 48, 32]} />
    <meshPhysicalMaterial
      map={map}
      roughness={gold ? 0.18 : 0.14}
      metalness={gold ? 0.9 : 0}
      clearcoat={gold ? 0.4 : 1}
      clearcoatRoughness={0.06}
      emissive={emissive ?? "#000"}
      emissiveIntensity={emissiveIntensity}
      envMapIntensity={1.6}
    />
  </mesh>
);

/** The break: the cue strikes, the rack opens up. `t` is seconds of table time. */
export const BreakShot: React.FC<{ t: number; strikeAt: number }> = ({ t, strikeAt }) => {
  const tex = useBallTextures();
  const sim = useMemo(() => simulateBreak(2400), []);
  const step = Math.max(0, Math.min(2399, Math.round(Math.max(0, t - strikeAt) / DT)));
  const y = TABLE.height + BALL_R;
  // cue approaches, hits and follows through
  const pull = t < strikeAt ? 0.34 * Math.pow(Math.max(0, 1 - Math.max(0, t - (strikeAt - 1.2)) / 1.2), 1) : 0;
  const cueX = -0.55 - BALL_R - 0.002 - (t < strikeAt ? Math.max(0, pull) : -Math.min(0.06, (t - strikeAt) * 0.9));
  return (
    <group>
      {sim.tracks.map((tr, i) => {
        const x = tr.pos[step * 2];
        const z = tr.pos[step * 2 + 1];
        const rq = [tr.rot[step * 4], tr.rot[step * 4 + 1], tr.rot[step * 4 + 2], tr.rot[step * 4 + 3]] as [number, number, number, number];
        const sunk = tr.potted >= 0 && step >= tr.potted;
        const drop = sunk ? Math.min(0.09, (step - tr.potted) * DT * 0.35) : 0;
        if (sunk && drop >= 0.09) return null;
        const isCue = i === sim.n - 1;
        return (
          <Ball key={i} position={[x, y - drop, z]} quaternion={rq} map={isCue ? tex.cue : tex.numbered[i % 15]} />
        );
      })}
      {/* cue stick */}
      <mesh position={[cueX - 0.8, y + 0.012, 0.012]} rotation={[0, 0, Math.PI / 2 + 0.035]} castShadow>
        <cylinderGeometry args={[0.0075, 0.0135, 1.6, 20]} />
        <meshStandardMaterial color="#c79a62" roughness={0.35} />
      </mesh>
      <mesh position={[cueX - 0.001, y + 0.0003, 0.012]} rotation={[0, 0, Math.PI / 2 + 0.035]}>
        <cylinderGeometry args={[0.0078, 0.0078, 0.012, 20]} />
        <meshStandardMaterial color="#1c4f9a" roughness={0.9} />
      </mesh>
    </group>
  );
};

/* ------------------------------------------------------------------ */
/* six visits: numbered balls roll in and line up                      */
/* ------------------------------------------------------------------ */
export const SIX_START = [12, 42, 72, 102, 132, 162]; // frames (scene-local) each ball starts rolling

export const SixBalls: React.FC<{ frame: number }> = ({ frame }) => {
  const tex = useBallTextures();
  const y = TABLE.height + BALL_R;
  return (
    <group>
      {SIX_START.map((start, i) => {
        const dur = 26;
        const p = Math.max(0, Math.min(1, (frame - start) / dur));
        if (frame < start) return null;
        const e = 1 - Math.pow(1 - p, 3);
        const tx = -0.375 + i * 0.15;
        const z = -0.42 + 0.42 * e;
        const dist = 0.42 * e;
        const q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), dist / BALL_R);
        const last = i === 5;
        const glow = last ? Math.max(0, Math.min(1, (frame - start - dur) / 20)) : 0;
        return (
          <Ball
            key={i}
            position={[tx, y, z]}
            quaternion={[q.x, q.y, q.z, q.w]}
            map={last ? tex.gold : tex.six[i]}
            gold={last}
            emissive={last ? "#ffb84a" : undefined}
            emissiveIntensity={last ? 0.35 * glow : 0}
          />
        );
      })}
    </group>
  );
};

/* ------------------------------------------------------------------ */
/* the gold coupon                                                     */
/* ------------------------------------------------------------------ */
function ticketShape(w: number, h: number, r: number, notch: number) {
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

function ticketFace() {
  // portrait: the reel is vertical
  const c = canvas(900, 1600);
  const g = c.getContext("2d")!;
  g.clearRect(0, 0, 900, 1600);
  g.fillStyle = "rgba(48,30,4,.92)";
  g.textBaseline = "alphabetic";
  g.textAlign = "center";
  g.font = "800 58px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("B I L L I O N  ·  K U P O N", 450, 170);
  g.font = "900 560px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("1", 450, 720);
  g.font = "900 190px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("SOAT", 450, 920);
  g.font = "900 104px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("O'YIN BEPUL", 450, 1060);
  g.setLineDash([26, 20]);
  g.lineWidth = 8;
  g.strokeStyle = "rgba(48,30,4,.4)";
  g.beginPath();
  g.moveTo(90, 1200);
  g.lineTo(810, 1200);
  g.stroke();
  g.font = "700 54px Inter, 'DejaVu Sans', sans-serif";
  g.globalAlpha = 0.8;
  g.fillText("6 ta tashrif uchun sovg'a", 450, 1330);
  g.font = "800 50px Inter, 'DejaVu Sans', sans-serif";
  g.fillText("BILL-6-2481", 450, 1440);
  g.globalAlpha = 1;
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  return t;
}

export const Ticket: React.FC<{ frame: number }> = ({ frame }) => {
  const W = 0.27;
  const Hh = 0.48;
  const geo = useMemo(() => {
    const g = new THREE.ExtrudeGeometry(ticketShape(W, Hh, 0.025, 0.028), {
      depth: 0.006,
      bevelEnabled: true,
      bevelThickness: 0.002,
      bevelSize: 0.002,
      bevelSegments: 3,
      curveSegments: 24,
    });
    g.center();
    return g;
  }, []);
  const face = useMemo(() => ticketFace(), []);
  // falls in from above, settles hovering, slowly turns
  const p = Math.max(0, Math.min(1, frame / 46));
  const e = 1 - Math.pow(1 - p, 3);
  const y = TABLE.height + 0.3 + (1 - e) * 0.9 + Math.sin(frame / 22) * 0.006;
  const tilt = -0.42 - (1 - e) * 0.7;
  const spin = (1 - e) * 2.2 + Math.sin(frame / 40) * 0.14;
  return (
    <group position={[0, y, 0.02]} rotation={[tilt, spin, 0]}>
      <mesh geometry={geo} castShadow>
        <meshPhysicalMaterial color="#e3b04d" metalness={1} roughness={0.24} clearcoat={0.6} clearcoatRoughness={0.1} envMapIntensity={2.2} />
      </mesh>
      <mesh position={[0, 0, 0.0052]}>
        <planeGeometry args={[W * 0.97, Hh * 0.97]} />
        <meshStandardMaterial map={face} transparent roughness={0.4} metalness={0.2} />
      </mesh>
    </group>
  );
};
