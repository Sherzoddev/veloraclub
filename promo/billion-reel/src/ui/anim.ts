import { Easing, interpolate } from "remotion";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** 0 → 1 over `dur` frames starting at `start`, eased out. */
export const rise = (frame: number, start: number, dur = 12) =>
  interpolate(frame, [start, start + dur], [0, 1], {
    ...clamp,
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });

/** A quick press: 1 → 0.93 → 1 around `at`. */
export const press = (frame: number, at: number) =>
  interpolate(frame, [at - 4, at, at + 6], [1, 0.93, 1], clamp);

export const lerp = (frame: number, input: number[], output: number[]) =>
  interpolate(frame, input, output, clamp);
