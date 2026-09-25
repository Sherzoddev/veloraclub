import React from "react";
import { Img, staticFile, useCurrentFrame } from "remotion";
import { lerp } from "./anim";
import { Tap } from "./Tap";

export type Step = { src: string; at: number; slide?: boolean };
export type TapAt = { x: number; y: number; at: number };

/**
 * Real Mini App screenshots (390×844 @3x) shown one after another inside the
 * phone, cross-fading (or sliding up, like the app's sheets), with finger taps
 * at the real button positions recorded during capture.
 */
export const Screens: React.FC<{ steps: Step[]; taps?: TapAt[] }> = ({ steps, taps = [] }) => {
  const frame = useCurrentFrame();
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      {steps.map((s, i) => {
        if (frame < s.at) return null;
        const next = steps[i + 1];
        if (next && frame >= next.at + 10) return null;
        const p = i === 0 ? 1 : lerp(frame, [s.at, s.at + 10], [0, 1]);
        return (
          <Img
            key={s.src + i}
            src={staticFile(`screens/${s.src}.png`)}
            style={{
              position: "absolute",
              inset: 0,
              width: 390,
              height: 844,
              opacity: s.slide ? 1 : p,
              translate: s.slide ? `0 ${(1 - p) * 844}px` : undefined,
            }}
          />
        );
      })}
      {taps.map((t) => (
        <div key={t.at} style={{ position: "absolute", left: t.x, top: t.y, width: 0, height: 0 }}>
          <Tap frame={frame} at={t.at} />
        </div>
      ))}
    </div>
  );
};
