import React from "react";
import { C } from "../theme";

/** Phone mock-up holding a 390×844 screen, scaled up. */
export const PHONE_W = 390;
export const PHONE_H = 844;
export const PHONE_SCALE = 1.26;

export const Phone: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      position: "absolute",
      left: (1080 - PHONE_W * PHONE_SCALE) / 2 - 12,
      top: 344,
      width: PHONE_W * PHONE_SCALE + 24,
      height: PHONE_H * PHONE_SCALE + 24,
      borderRadius: 70,
      background: "linear-gradient(145deg,#2a3431,#0a0f0e 40%,#1b2421)",
      padding: 12,
      boxShadow:
        "0 60px 140px rgba(0,0,0,.65), 0 0 0 2px rgba(255,255,255,.06), 0 0 120px rgba(57,239,173,.12)",
    }}
  >
    <div
      style={{
        width: PHONE_W * PHONE_SCALE,
        height: PHONE_H * PHONE_SCALE,
        borderRadius: 58,
        overflow: "hidden",
        position: "relative",
        background: C.bg,
      }}
    >
      <div
        style={{
          width: PHONE_W,
          height: PHONE_H,
          scale: String(PHONE_SCALE),
          transformOrigin: "0 0",
          position: "absolute",
          inset: 0,
        }}
      >
        {children}
      </div>
    </div>
  </div>
);
