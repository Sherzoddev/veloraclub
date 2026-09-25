import React from "react";
import { Sequence, useCurrentFrame } from "remotion";
import { lerp } from "./anim";

/**
 * Screens of one feature shown in turn inside the phone (e.g. the Telegram
 * chat, then the Mini App), cross-fading. Each part gets its own timeline
 * starting at 0.
 */
export const Parts: React.FC<{ parts: { from: number; node: React.ReactNode }[] }> = ({ parts }) => {
  const frame = useCurrentFrame();
  return (
    <>
      {parts.map((part, i) => {
        const next = parts[i + 1];
        const fadeIn = i === 0 ? 1 : lerp(frame, [part.from, part.from + 16], [0, 1]);
        const fadeOut = next ? lerp(frame, [next.from, next.from + 16], [1, 0]) : 1;
        return (
          <Sequence key={i} from={part.from} durationInFrames={next ? next.from + 16 - part.from : undefined} layout="none">
            <div style={{ position: "absolute", inset: 0, opacity: Math.min(fadeIn, fadeOut) }}>{part.node}</div>
          </Sequence>
        );
      })}
    </>
  );
};
