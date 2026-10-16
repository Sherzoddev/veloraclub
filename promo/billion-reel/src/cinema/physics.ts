import * as THREE from "three";

/** Table geometry in metres: the cloth is X (long) by Z (short), y is up. */
export const TABLE = { L: 1.8, W: 0.9, ball: 0.03, pocket: 0.058, rail: 0.13, height: 0.8 };
export const BALL_R = TABLE.ball;

export const POCKETS: [number, number][] = [
  [-TABLE.L / 2, -TABLE.W / 2],
  [TABLE.L / 2, -TABLE.W / 2],
  [-TABLE.L / 2, TABLE.W / 2],
  [TABLE.L / 2, TABLE.W / 2],
  [0, -TABLE.W / 2 - 0.012],
  [0, TABLE.W / 2 + 0.012],
];

export type BallState = {
  x: number;
  z: number;
  vx: number;
  vz: number;
  potted: number; // step at which it dropped in (-1: still on the table)
};

export type Track = {
  /** per step: x, z, quaternion (x,y,z,w) and whether it is in a pocket */
  pos: Float32Array;
  rot: Float32Array;
  potted: number;
};

export const DT = 1 / 240;

/** A deterministic break: the cue ball hits a rack of balls, a few are potted. */
export function simulateBreak(steps: number) {
  const balls: BallState[] = [];
  const spacing = BALL_R * 2 + 0.0004;
  // rack: pyramid (5 rows) on the right
  const rackX = 0.42;
  for (let row = 0; row < 5; row++) {
    for (let k = 0; k <= row; k++) {
      balls.push({
        x: rackX + row * spacing * 0.866,
        z: (k - row / 2) * spacing,
        vx: 0,
        vz: 0,
        potted: -1,
      });
    }
  }
  // cue ball: left of the rack, a little off-centre so the rack opens up
  balls.push({ x: -0.55, z: 0.012, vx: 5.6, vz: 0.05, potted: -1 });
  const n = balls.length;
  const pos = Array.from({ length: n }, () => new Float32Array(steps * 2));
  const rot = Array.from({ length: n }, () => new Float32Array(steps * 4));
  const q = Array.from({ length: n }, () => new THREE.Quaternion());
  const axis = new THREE.Vector3();
  const dq = new THREE.Quaternion();
  const hx = TABLE.L / 2 - BALL_R;
  const hz = TABLE.W / 2 - BALL_R;
  for (let s = 0; s < steps; s++) {
    // motion
    for (const b of balls) {
      if (b.potted >= 0) continue;
      const sp = Math.hypot(b.vx, b.vz);
      if (sp > 0) {
        const dec = Math.min(sp, 0.55 * DT * 9.81 * 0.9);
        b.vx -= (b.vx / sp) * dec;
        b.vz -= (b.vz / sp) * dec;
      }
      b.x += b.vx * DT;
      b.z += b.vz * DT;
    }
    // cushions (except where a pocket is)
    for (const b of balls) {
      if (b.potted >= 0) continue;
      for (const [px, pz] of POCKETS) {
        if (Math.hypot(b.x - px, b.z - pz) < TABLE.pocket * 0.82) {
          b.potted = s;
          b.vx = 0;
          b.vz = 0;
          b.x = px;
          b.z = pz;
        }
      }
      if (b.potted >= 0) continue;
      if (b.x > hx) {
        b.x = hx;
        b.vx = -Math.abs(b.vx) * 0.78;
      } else if (b.x < -hx) {
        b.x = -hx;
        b.vx = Math.abs(b.vx) * 0.78;
      }
      if (b.z > hz) {
        b.z = hz;
        b.vz = -Math.abs(b.vz) * 0.78;
      } else if (b.z < -hz) {
        b.z = -hz;
        b.vz = Math.abs(b.vz) * 0.78;
      }
    }
    // ball-ball
    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        const a = balls[i];
        const b = balls[j];
        if (a.potted >= 0 || b.potted >= 0) continue;
        const dx = b.x - a.x;
        const dz = b.z - a.z;
        const d = Math.hypot(dx, dz);
        if (d < BALL_R * 2 && d > 1e-6) {
          const nx = dx / d;
          const nz = dz / d;
          const overlap = BALL_R * 2 - d;
          a.x -= (nx * overlap) / 2;
          a.z -= (nz * overlap) / 2;
          b.x += (nx * overlap) / 2;
          b.z += (nz * overlap) / 2;
          const rv = (b.vx - a.vx) * nx + (b.vz - a.vz) * nz;
          if (rv < 0) {
            const imp = -(1 + 0.97) * rv / 2;
            a.vx -= imp * nx;
            a.vz -= imp * nz;
            b.vx += imp * nx;
            b.vz += imp * nz;
          }
        }
      }
    }
    // record, and roll the balls
    for (let i = 0; i < n; i++) {
      const b = balls[i];
      pos[i][s * 2] = b.x;
      pos[i][s * 2 + 1] = b.z;
      const sp = Math.hypot(b.vx, b.vz);
      if (sp > 1e-4 && b.potted < 0) {
        axis.set(b.vz, 0, -b.vx).normalize();
        dq.setFromAxisAngle(axis, (sp * DT) / BALL_R);
        q[i].premultiply(dq);
      }
      rot[i][s * 4] = q[i].x;
      rot[i][s * 4 + 1] = q[i].y;
      rot[i][s * 4 + 2] = q[i].z;
      rot[i][s * 4 + 3] = q[i].w;
    }
  }
  return { n, tracks: balls.map((b, i) => ({ pos: pos[i], rot: rot[i], potted: b.potted }) as Track) };
}
