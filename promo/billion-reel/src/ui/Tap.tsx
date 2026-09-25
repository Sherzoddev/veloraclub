import React from "react";
import { lerp } from "./anim";

/** Finger-tap ripple, rendered inside a relatively positioned element. */
export const Tap: React.FC<{ frame: number; at?: number }> = ({ frame, at }) => {
  if (at === undefined || frame < at - 6 || frame > at + 16) return null;
  const size = lerp(frame, [at - 6, at, at + 16], [70, 34, 90]);
  const opacity = lerp(frame, [at - 6, at - 2, at + 4, at + 16], [0, 0.9, 0.7, 0]);
  return (
    <div
      style={{
        position: "absolute",
        left: "50%",
        top: "50%",
        width: size,
        height: size,
        marginLeft: -size / 2,
        marginTop: -size / 2,
        borderRadius: "50%",
        background: "rgba(255,255,255,.35)",
        border: "2px solid rgba(255,255,255,.8)",
        opacity,
        pointerEvents: "none",
      }}
    />
  );
};
