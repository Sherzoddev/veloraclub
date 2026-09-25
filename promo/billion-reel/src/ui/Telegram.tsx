import React from "react";
import { useCurrentFrame } from "remotion";
import { Img, staticFile } from "remotion";
import { FONT } from "../theme";

// Telegram's default day theme, as on the club's own screenshots.
const T = {
  header: "#ffffff",
  title: "#000000",
  sub: "#8a8f94",
  bot: "#ffffff",
  user: "#effdde",
  text: "#000000",
  timeBot: "#a0acb6",
  timeUser: "#5ea85a",
  link: "#168acd",
  inline: "rgba(62, 104, 52, 0.55)",
  inlineHot: "rgba(40, 170, 110, 0.85)",
  kbBg: "#ffffff",
  kbKey: "#f1f3f4",
  kbKeyHot: "#dfe7df",
  kbText: "#1d1d1d",
  wallpaper: "linear-gradient(160deg, #8dbb77 0%, #b7d383 38%, #d6dd8e 55%, #9fcb82 100%)",
};
import { lerp, press, rise } from "./anim";
import { Tap } from "./Tap";

export type Btn = { label: string; tapAt?: number };
export type Keyboard = { rows: Btn[][]; at: number };

/** The bot's divider line (DIVIDER in club-bot-service). */
export const Hr: React.FC = () => <span style={{ color: "#7b8288" }}>┄┄┄┄┄┄┄┄┄┄┄┄</span>;

const TapKey: React.FC<{ b: Btn; frame: number; style: React.CSSProperties; hot: string }> = ({ b, frame, style, hot }) => (
  <div
    style={{
      flex: 1,
      position: "relative",
      textAlign: "center",
      fontSize: 13.5,
      fontWeight: 600,
      ...style,
      scale: String(b.tapAt ? press(frame, b.tapAt) : 1),
      background: b.tapAt && frame >= b.tapAt - 2 && frame < b.tapAt + 14 ? hot : style.background,
    }}
  >
    {b.label}
    <Tap frame={frame} at={b.tapAt} />
  </div>
);

/**
 * Telegram (dark theme) chat with the club's client bot. Texts, inline
 * buttons and the reply keyboard are the bot's real ones (club-bot-service).
 */
export const TgChat: React.FC<{ children: React.ReactNode; keyboards?: Keyboard[] }> = ({
  children,
  keyboards = [],
}) => {
  const frame = useCurrentFrame();
  const kb = [...keyboards].reverse().find((k) => frame >= k.at);
  const kbP = kb ? rise(frame, kb.at, 12) : 0;
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        fontFamily: FONT,
        color: T.text,
        display: "flex",
        flexDirection: "column",
        background: T.wallpaper,
      }}
    >
      <div
        style={{
          height: 100,
          paddingTop: 48,
          background: T.header,
          display: "flex",
          alignItems: "center",
          gap: 11,
          paddingLeft: 14,
          flexShrink: 0,
          boxShadow: "0 1px 3px rgba(0,0,0,.12)",
          zIndex: 1,
        }}
      >
        <div style={{ color: "#3c3c3c", fontSize: 24, width: 16, marginTop: -3 }}>←</div>
        <Img
          src={staticFile("logo_square.jpg")}
          style={{ width: 42, height: 42, borderRadius: "50%", objectFit: "cover" }}
        />
        <div>
          <div style={{ fontWeight: 700, fontSize: 16.5, color: T.title }}>Billion billiard</div>
          <div style={{ fontSize: 13, color: T.sub }}>bot</div>
        </div>
      </div>
      <div
        style={{
          flex: 1,
          overflow: "hidden",
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          padding: "8px 9px",
          gap: 6,
        }}
      >
        {children}
      </div>
      <div style={{ background: T.kbBg, flexShrink: 0 }}>
        <div style={{ height: 52, display: "flex", alignItems: "center", gap: 10, padding: "0 10px" }}>
          <div
            style={{
              background: "#3390ec",
              color: "#fff",
              borderRadius: 18,
              padding: "7px 12px",
              fontSize: 13,
              fontWeight: 700,
            }}
          >
            ▢ Klubni ochish
          </div>
          <div style={{ color: "#9aa1a7", fontSize: 14.5, flex: 1 }}>Xabar</div>
          <div style={{ color: "#8a9096", fontSize: 18 }}>⌨︎</div>
        </div>
        {kb ? (
          <div
            style={{
              padding: "4px 6px 24px",
              display: "flex",
              flexDirection: "column",
              gap: 5,
              maxHeight: kbP * 260,
              overflow: "hidden",
            }}
          >
            {kb.rows.map((row, i) => (
              <div key={i} style={{ display: "flex", gap: 5 }}>
                {row.map((b) => (
                  <TapKey
                    key={b.label}
                    b={b}
                    frame={frame}
                    hot={T.kbKeyHot}
                    style={{ background: T.kbKey, color: T.kbText, borderRadius: 10, padding: "11px 4px" }}
                  />
                ))}
              </div>
            ))}
          </div>
        ) : (
          <div style={{ height: 22 }} />
        )}
      </div>
    </div>
  );
};

/**
 * One message, growing in at `at` (and optionally removed at `until`, like
 * the terms prompt the bot deletes). `markups` swaps the inline keyboard
 * over time, as the bot does with editMessageReplyMarkup.
 */
export const Msg: React.FC<{
  at: number;
  until?: number;
  from?: "bot" | "user";
  children: React.ReactNode;
  buttons?: Btn[][];
  markups?: { at: number; rows: Btn[][] }[];
  time?: string;
}> = ({ at, until, from = "bot", children, buttons, markups, time = "19:42" }) => {
  const frame = useCurrentFrame();
  if (frame < at) return null;
  if (until !== undefined && frame >= until + 12) return null;
  const p = rise(frame, at, 12);
  const gone = until !== undefined ? lerp(frame, [until, until + 12], [1, 0]) : 1;
  const user = from === "user";
  const rows = markups ? [...markups].reverse().find((m) => frame >= m.at)?.rows ?? buttons : buttons;
  return (
    <div
      style={{
        maxHeight: lerp(frame, [at, at + 12], [0, 700]) * gone,
        opacity: p * gone,
        translate: `0 ${(1 - p) * 16}px`,
        display: "flex",
        flexDirection: "column",
        alignItems: user ? "flex-end" : "flex-start",
        flexShrink: 0,
        overflow: "hidden",
      }}
    >
      <div
        style={{
          maxWidth: "86%",
          background: user ? T.user : T.bot,
          boxShadow: "0 1px 1.5px rgba(0,0,0,.13)",
          borderRadius: 15,
          borderBottomLeftRadius: user ? 15 : 4,
          borderBottomRightRadius: user ? 4 : 15,
          padding: "7px 10px 5px",
          fontSize: 14,
          lineHeight: 1.33,
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
        }}
      >
        {children}
        <div style={{ textAlign: "right", fontSize: 10.5, color: user ? T.timeUser : T.timeBot, marginTop: 1 }}>
          {time}
          {user ? " ✓✓" : ""}
        </div>
      </div>
      {rows ? (
        <div style={{ width: "86%", display: "flex", flexDirection: "column", gap: 4, marginTop: 4 }}>
          {rows.map((row, i) => (
            <div key={i} style={{ display: "flex", gap: 4 }}>
              {row.map((b) => (
                <TapKey
                  key={b.label}
                  b={b}
                  frame={frame}
                  hot={T.inlineHot}
                  style={{ background: T.inline, color: "#fff", borderRadius: 10, padding: "10px 4px" }}
                />
              ))}
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
};

/** A shared Telegram contact, as it shows after "📱 Raqamni yuborish". */
export const Contact: React.FC<{ at: number; name: string; phone: string }> = ({ at, name, phone }) => (
  <Msg at={at} from="user">
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "2px 2px 0" }}>
      <div
        style={{
          width: 42,
          height: 42,
          borderRadius: "50%",
          background: "linear-gradient(145deg,#f6a55a,#e3703a)",
          display: "grid",
          placeItems: "center",
          fontWeight: 800,
          fontSize: 18,
          color: "#fff",
        }}
      >
        {name[0]}
      </div>
      <div>
        <div style={{ fontWeight: 700 }}>{name}</div>
        <div style={{ fontSize: 13, color: "#4e8a4b" }}>{phone}</div>
      </div>
    </div>
  </Msg>
);

export const LINK = T.link;

/** Telegram's link preview under a message with a t.me link. */
export const Preview: React.FC = () => (
  <div
    style={{
      marginTop: 8,
      borderLeft: "3px solid #9c6ade",
      background: "rgba(156, 106, 222, .10)",
      borderRadius: 6,
      padding: "6px 8px",
      display: "flex",
      gap: 8,
    }}
  >
    <div style={{ flex: 1, fontSize: 13, lineHeight: 1.3 }}>
      <div style={{ color: "#9c6ade", fontWeight: 700 }}>Telegram</div>
      <div style={{ fontWeight: 700 }}>Billion billiard</div>
      Rus bilyardi | Русский бильярд{"\n\n"}Prof stollar | Проф столы{"\n\n"}11:00 - sóngi mijozgacha | до пос-го…
    </div>
    <Img src={staticFile("logo_square.jpg")} style={{ width: 62, height: 62, borderRadius: 6 }} />
  </div>
);
