import React from "react";
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import { C, FONT } from "../theme";
import { lerp, rise } from "./anim";
import { Phone } from "./Phone";

export type Line = { text: string; from: number; to: number };

/** Background shared by every scene: dark with a slow green glow. */
export const Backdrop: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(circle at ${30 + Math.sin(frame / 60) * 8}% 18%, rgba(26,160,115,.28), transparent 42%),
          radial-gradient(circle at 85% 88%, rgba(229,185,92,.10), transparent 35%), ${C.bg}`,
      }}
    />
  );
};

/** Off for the clean cut (VeloraReelClean): no subtitles, no voice. */
export const SubtitlesOn = React.createContext(true);

/** Karaoke-style subtitles, kept above Instagram's bottom caption area. */
export const Subtitles: React.FC<{ lines: Line[] }> = ({ lines }) => {
  const frame = useCurrentFrame();
  const on = React.useContext(SubtitlesOn);
  const line = lines.find((l) => frame >= l.from && frame < l.to);
  if (!on || !line) return null;
  const words = line.text.split(" ");
  const span = Math.max(1, (line.to - line.from) * 0.7);
  const shown = ((frame - line.from) / span) * words.length;
  const inP = rise(frame, line.from, 8);
  const out = lerp(frame, [line.to - 6, line.to], [1, 0]);
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 300,
        display: "flex",
        justifyContent: "center",
        opacity: Math.min(inP, out),
        translate: `0 ${(1 - inP) * 18}px`,
      }}
    >
      <div
        style={{
          maxWidth: 860,
          padding: "18px 30px",
          borderRadius: 26,
          background: "rgba(3,8,7,.82)",
          border: "1px solid rgba(57,239,173,.25)",
          boxShadow: "0 20px 60px rgba(0,0,0,.5)",
          fontFamily: FONT,
          fontWeight: 800,
          fontSize: 43,
          lineHeight: 1.25,
          textAlign: "center",
          color: C.text,
        }}
      >
        {words.map((w, i) => (
          <span
            key={i}
            style={{
              color: i < Math.floor(shown) ? C.text : i === Math.floor(shown) ? C.green : "rgba(245,248,247,.38)",
            }}
          >
            {w}
            {i < words.length - 1 ? " " : ""}
          </span>
        ))}
      </div>
    </div>
  );
};

export type Label = { at: number; text: string };

export const Headline: React.FC<{ step: string; title: string; labels?: Label[] }> = ({ step, title, labels = [] }) => {
  const frame = useCurrentFrame();
  const p = rise(frame, 2, 16);
  const label = [...labels].reverse().find((l) => frame >= l.at);
  const lp = label ? rise(frame, label.at, 12) : 0;
  return (
    <div
      style={{
        position: "absolute",
        top: 190,
        left: 90,
        right: 90,
        textAlign: "center",
        fontFamily: FONT,
        opacity: p,
        translate: `0 ${(1 - p) * -24}px`,
      }}
    >
      <div
        style={{
          fontSize: 26,
          letterSpacing: 7,
          fontWeight: 800,
          color: C.green,
          textShadow: "0 0 18px rgba(57,239,173,.6)",
        }}
      >
        BILLION · {step}
        {label ? (
          <span style={{ opacity: lp, color: "#c7d0cd" }}>
            {" · "}
            {label.text}
          </span>
        ) : null}
      </div>
      <div
        style={{
          fontSize: 76,
          fontWeight: 900,
          color: C.text,
          letterSpacing: -2,
          marginTop: 8,
          lineHeight: 1.02,
        }}
      >
        {title}
      </div>
    </div>
  );
};

/** A feature scene: headline, phone with the given screen, subtitles. */
export const FeatureScene: React.FC<{
  step: string;
  title: string;
  lines: Line[];
  labels?: Label[];
  children: React.ReactNode;
}> = ({ step, title, lines, labels, children }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const p = rise(frame, 0, 20);
  return (
    <AbsoluteFill style={{ fontFamily: FONT }}>
      <Backdrop />
      <Headline step={step} title={title} labels={labels} />
      <div
        style={{
          position: "absolute",
          inset: 0,
          opacity: p,
          translate: `0 ${(1 - p) * 90 + lerp(frame, [0, durationInFrames], [0, -10])}px`,
        }}
      >
        <Phone>{children}</Phone>
      </div>
      <Subtitles lines={lines} />
    </AbsoluteFill>
  );
};
