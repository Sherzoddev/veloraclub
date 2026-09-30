import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { C, FONT } from "../theme";
import { rise } from "../ui/anim";
import { Backdrop, Subtitles } from "../ui/Scene";

export const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const w = rise(frame, 4, 18);
  const b = rise(frame, 24, 16);
  const cta = rise(frame, 46, 16);
  return (
    <AbsoluteFill style={{ fontFamily: FONT, alignItems: "center" }}>
      <Backdrop />
      <Img
        src={staticFile("logo.png")}
        style={{
          position: "absolute",
          top: 330,
          width: 760,
          mixBlendMode: "lighten",
          opacity: w,
          translate: `0 ${(1 - w) * 30}px`,
          
        }}
      />
      <div
        style={{
          position: "absolute",
          top: 560,
          opacity: b,
          translate: `0 ${(1 - b) * 24}px`,
          textAlign: "center",
          color: C.text,
        }}
      >
        <div style={{ fontSize: 40, color: C.muted, fontWeight: 600 }}>Telegram bot</div>
        <div
          style={{
            fontSize: 66,
            fontWeight: 900,
            color: C.green,
            marginTop: 10,
            textShadow: "0 0 30px rgba(57,239,173,.5)",
          }}
        >
          @billionbiliard_bot
        </div>
      </div>
      <div
        style={{
          position: "absolute",
          top: 820,
          opacity: cta,
          translate: `0 ${(1 - cta) * 30}px`,
          scale: String(1 + 0.03 * Math.sin(frame / 6) * cta),
          padding: "34px 64px",
          borderRadius: 40,
          background: "linear-gradient(135deg,#5affc1,#18d993)",
          color: "#022d20",
          fontSize: 54,
          fontWeight: 900,
          boxShadow: "0 30px 90px rgba(21,222,147,.35)",
        }}
      >
        Botni hoziroq oching
      </div>
      <div
        style={{
          position: "absolute",
          top: 1010,
          opacity: cta,
          textAlign: "center",
          fontSize: 38,
          lineHeight: 1.5,
          color: "#c7d0cd",
          fontWeight: 600,
        }}
      >
        📍 Ma'rifat ko'chasi 122, Angren
        <br />
        📞 +998 95 969 55 77
      </div>
      <Subtitles lines={[{ text: "BILLION — sizni kutamiz!", from: 20, to: 196 }]} />
    </AbsoluteFill>
  );
};
