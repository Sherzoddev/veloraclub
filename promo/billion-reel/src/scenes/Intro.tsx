import React from "react";
import { AbsoluteFill, Easing, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { FONT } from "../theme";
import { rise } from "../ui/anim";
import { Backdrop, Subtitles } from "../ui/Scene";

export const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const ball = interpolate(frame, [0, 26], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.bezier(0.2, 1.4, 0.4, 1),
  });
  const word = rise(frame, 18, 18);
  const tag = rise(frame, 34, 18);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <Backdrop />
      <div
        style={{
          position: "absolute",
          top: 400,
          width: 340,
          height: 340,
          borderRadius: "50%",
          scale: String(ball),
          background:
            "radial-gradient(circle at 34% 28%, #ffffff 0, #fbf7ec 22%, #efe6cf 50%, #d2c4a0 78%, #9f8f69 100%)",
          boxShadow: "0 40px 120px rgba(0,0,0,.7), inset -30px -40px 70px rgba(80,60,20,.35), 0 0 120px rgba(57,239,173,.18)",
        }}
      />
      <Img
        src={staticFile("logo.png")}
        style={{
          position: "absolute",
          top: 820,
          width: 800,
          mixBlendMode: "lighten",
          opacity: word,
          translate: `0 ${(1 - word) * 30}px`,
        }}
      />
      <div
        style={{
          position: "absolute",
          top: 1090,
          opacity: tag,
          translate: `0 ${(1 - tag) * 24}px`,
          fontSize: 42,
          fontWeight: 700,
          letterSpacing: 10,
          color: "#c7d0cd",
        }}
      >
        BILLIARD CLUB · ANGREN
      </div>
      <Subtitles lines={[{ text: "BILLION bilyard klubi — endi Telegramda!", from: 30, to: 156 }]} />
    </AbsoluteFill>
  );
};
