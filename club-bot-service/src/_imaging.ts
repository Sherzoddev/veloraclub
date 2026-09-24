// Shared image-compositing engine for the client bot's branded screens.
//
// Everything here renders an SVG string (dynamic text/QR/data laid over one
// of four pre-made background photographs) and rasterizes it with resvg.
// The backgrounds never change; only what's drawn on top of them does, so a
// cold start pays for the background+font fetch once and every request after
// that just re-renders text. Ported from the Deno Edge Function version:
// resvg-wasm (needs a wasm binary fetched+initialized every cold isolate)
// became resvg-js (a native binding, ready synchronously, no init step) --
// the whole point of this service is to never pay that cost per request.

import { Resvg } from "@resvg/resvg-js";
import QRCode from "qrcode";
import { fileURLToPath } from "node:url";

const INK = "#101310";
const PAPER = "#F2F0E8";
const LIME = "#C8F560";
const MOSS = "#263B2D";

const BG = {
  poster: "https://app-uploads.krea.ai/public/eb435ffe-d6d7-4857-a6bb-327012e243ea.png",
  card: "https://app-uploads.krea.ai/public/15b4d730-f089-4c36-9fbd-aba402aba655.png",
  table: "https://app-uploads.krea.ai/public/192fd82e-50cb-4942-b696-4e4ec8bc4f7b-image.png",
  ticket: "https://app-uploads.krea.ai/public/4ddb9b96-73e2-4877-baf3-7f560e0883eb.png",
} as const;

// Manrope TTF, bundled via @expo-google-fonts/manrope instead of fetched
// over the network -- the original Deno version fetched WOFF2 from Google's
// CDN on every cold isolate. Two problems ruled that pattern out here:
// resvg-js (the native, non-wasm binding used in this persistent-process
// service) loads fonts through Rust's fontdb, which -- confirmed by testing
// directly -- silently produces a zero-glyph face for WOFF2 (no error, no
// text, just a blank render); it wants actual TTF/OTF. Bundling the TTFs as
// a dependency sidesteps that entirely and also drops the per-cold-start
// network fetch, since the files are just on disk already.
const FONT_FILES = {
  medium: fileURLToPath(new URL("../node_modules/@expo-google-fonts/manrope/500Medium/Manrope_500Medium.ttf", import.meta.url)),
  bold: fileURLToPath(new URL("../node_modules/@expo-google-fonts/manrope/700Bold/Manrope_700Bold.ttf", import.meta.url)),
  extrabold: fileURLToPath(new URL("../node_modules/@expo-google-fonts/manrope/800ExtraBold/Manrope_800ExtraBold.ttf", import.meta.url)),
} as const;

function font(name: keyof typeof FONT_FILES): string {
  return FONT_FILES[name];
}

const bgCache = new Map<string, string>();
async function bgDataUri(name: keyof typeof BG): Promise<string> {
  const cached = bgCache.get(name);
  if (cached) return cached;
  const bytes = Buffer.from(await (await fetch(BG[name])).arrayBuffer());
  const uri = `data:image/png;base64,${bytes.toString("base64")}`;
  bgCache.set(name, uri);
  return uri;
}

/// Escapes text dropped into an SVG <text> node.
function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function rasterize(svg: string, width: number, fontFiles: string[]): Uint8Array {
  const resvg = new Resvg(svg, {
    fitTo: { mode: "width", value: width },
    font: { fontFiles, loadSystemFonts: false, defaultFontFamily: "Manrope" },
  });
  return resvg.render().asPng();
}

// --- 1. Welcome poster ------------------------------------------------------

export async function renderPoster(clubName: string, lang: "ru" | "uz"): Promise<Uint8Array> {
  const [bg, extrabold, medium] = await Promise.all([bgDataUri("poster"), font("extrabold"), font("medium")]);
  const lines = lang === "uz" ? ["AJOYIB", "OQSHOM.", "NAVBAT SIZDA."] : ["ХОРОШИЙ", "ВЕЧЕР.", "ВАШ ХОД."];
  const w = 1264, h = 848;
  const textLines = lines
    .map((l, i) => `<text x="56" y="${300 + i * 96}" font-family="Manrope" font-weight="800" font-size="76" fill="${PAPER}">${esc(l)}</text>`)
    .join("\n");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
    <image href="${bg}" x="0" y="0" width="${w}" height="${h}" preserveAspectRatio="xMidYMid slice"/>
    <circle cx="62" cy="45" r="5" fill="${LIME}"/>
    <text x="80" y="52" font-family="Manrope" font-weight="500" font-size="21" letter-spacing="2" fill="${PAPER}" fill-opacity="0.8">${esc(clubName.toUpperCase())}</text>
    ${textLines}
  </svg>`;
  return rasterize(svg, w, [extrabold, medium]);
}

// --- 2. Player card ----------------------------------------------------------

export async function renderPlayerCard(opts: {
  clubName: string;
  customerName: string;
  levelLabel: string;
  balance: number;
  discountPct: number | null;
  qrValue: string;
  lang: "ru" | "uz";
}): Promise<Uint8Array> {
  const { clubName, customerName, levelLabel, balance, discountPct, qrValue, lang } = opts;
  const [bg, extrabold, bold, medium] = await Promise.all([
    bgDataUri("card"), font("extrabold"), font("bold"), font("medium"),
  ]);
  const w = 1264, h = 848;

  // Shrink the name if it's long so it never collides with the QR panel.
  const nameSize = customerName.length > 20 ? 34 : customerName.length > 13 ? 42 : 52;
  const balanceDigits = String(Math.round(balance)).length;
  const balanceSize = balanceDigits > 6 ? 68 : balanceDigits > 4 ? 84 : 100;

  const qrSvg = await QRCode.toString(qrValue, { type: "svg", margin: 0, color: { dark: INK, light: "#00000000" } });
  const qrInner = qrSvg.replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "");
  // The light panel in the background photo runs roughly x:806-1213, y:55-790.
  // The QR box (plus its caption underneath) is centered inside that panel,
  // not just dropped at a fixed offset — off-center was the whole complaint.
  const qrSize = 300;
  // Centered in the space left over once the notch/label header and the
  // home-indicator bar (drawn further down) claim their own room at the
  // top and bottom of the panel.
  const panelCx = 1010, panelCy = 443;
  const groupH = (qrSize + 28) + 12 + 22; // outer white box + gap + caption line
  const qrX = panelCx - qrSize / 2;
  const qrY = panelCy - groupH / 2 + 14;

  const discountBlock = discountPct
    ? `<rect x="56" y="640" width="230" height="72" rx="14" fill="none" stroke="${LIME}" stroke-width="2"/>
       <text x="80" y="670" font-family="Manrope" font-weight="500" font-size="15" letter-spacing="1.5" fill="${PAPER}" fill-opacity="0.7">${esc(L(lang, "СКИДКА", "CHEGIRMA"))}</text>
       <text x="80" y="698" font-family="Manrope" font-weight="800" font-size="26" fill="${LIME}">${discountPct}%</text>`
    : "";

  // The light panel reads as a phone screen in the source photo, so it's
  // dressed like one — a notch and a home indicator — instead of leaving the
  // QR floating alone in a bare white rectangle with nothing else going on.
  const panelTop = 55, panelBottom = 790;
  const notchY = panelTop + 22;
  const homeBarY = panelBottom - 30;

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
    <image href="${bg}" x="0" y="0" width="${w}" height="${h}" preserveAspectRatio="xMidYMid slice"/>
    <text x="56" y="76" font-family="Manrope" font-weight="500" font-size="22" letter-spacing="2" fill="${PAPER}" fill-opacity="0.65">${esc(clubName.toUpperCase())}</text>
    <text x="56" y="${76 + nameSize + 30}" font-family="Manrope" font-weight="800" font-size="${nameSize}" fill="${PAPER}">${esc(customerName)}</text>
    <text x="56" y="${76 + nameSize + 78}" font-family="Manrope" font-weight="700" font-size="19" letter-spacing="1.5" fill="${LIME}">${esc(levelLabel.toUpperCase())}</text>
    <text x="56" y="490" font-family="Manrope" font-weight="500" font-size="20" fill="${PAPER}" fill-opacity="0.6">${esc(L(lang, "БАЛАНС БОНУСОВ", "BONUS BALANSI"))}</text>
    <text x="56" y="${490 + balanceSize + 6}" font-family="Manrope" font-weight="800" font-size="${balanceSize}" fill="${PAPER}">${money(balance)}</text>
    ${discountBlock}
    <rect x="${panelCx - 50}" y="${notchY}" width="100" height="20" rx="10" fill="${INK}" fill-opacity="0.14"/>
    <text x="${panelCx}" y="${notchY + 45}" font-family="Manrope" font-weight="700" font-size="13" letter-spacing="2" fill="${INK}" fill-opacity="0.4" text-anchor="middle">${esc(L(lang, "ЦИФРОВАЯ КАРТА", "RAQAMLI KARTA"))}</text>
    <g transform="translate(${qrX}, ${qrY})">
      <rect x="-14" y="-14" width="${qrSize + 28}" height="${qrSize + 28}" rx="18" fill="#FFFFFF"/>
      <svg x="0" y="0" width="${qrSize}" height="${qrSize}" viewBox="0 0 29 29">${qrInner}</svg>
    </g>
    <text x="${qrX + qrSize / 2}" y="${qrY + qrSize + 46}" font-family="Manrope" font-weight="700" font-size="17" fill="${INK}" fill-opacity="0.75" text-anchor="middle">${esc(L(lang, "Покажите на кассе", "Kassada ko'rsating"))}</text>
    <rect x="${panelCx - 60}" y="${homeBarY}" width="120" height="6" rx="3" fill="${INK}" fill-opacity="0.14"/>
  </svg>`;
  return rasterize(svg, w, [extrabold, bold, medium]);
}

function money(n: number): string {
  return new Intl.NumberFormat("ru-RU").format(Math.round(n));
}
function L(lang: "ru" | "uz", ru: string, uz: string) {
  return lang === "uz" ? uz : ru;
}

// --- 3. Table board -----------------------------------------------------------

export type TableStatus = { name: string; free: boolean };

export async function renderTableBoard(tables: TableStatus[], updatedLabel: string, lang: "ru" | "uz"): Promise<Uint8Array> {
  const [icon, bold, medium] = await Promise.all([bgDataUri("table"), font("bold"), font("medium")]);
  const cols = tables.length <= 2 ? tables.length : 3;
  const rows = Math.ceil(tables.length / cols);
  const cell = 300;
  const iconSize = 200;
  const w = cols * cell;
  const h = rows * cell + 70;

  const cells = tables.map((t, i) => {
    const col = i % cols, row = Math.floor(i / cols);
    const cx = col * cell + cell / 2;
    const cy = row * cell + 30;
    const overlay = t.free
      ? `<rect x="${cx - iconSize / 2 - 6}" y="${cy - 6}" width="${iconSize + 12}" height="${iconSize + 12}" rx="16" fill="none" stroke="${LIME}" stroke-width="4"/>`
      : `<rect x="${cx - iconSize / 2}" y="${cy}" width="${iconSize}" height="${iconSize}" rx="12" fill="${INK}" fill-opacity="0.55"/>`;
    const statusText = t.free ? L(lang, "СВОБОДЕН", "BO'SH") : L(lang, "ЗАНЯТ", "BAND");
    const statusColor = t.free ? LIME : PAPER;
    const statusOpacity = t.free ? 1 : 0.45;
    return `
      <image href="${icon}" x="${cx - iconSize / 2}" y="${cy}" width="${iconSize}" height="${iconSize}" opacity="${t.free ? 1 : 0.5}"/>
      ${overlay}
      <text x="${cx}" y="${cy + iconSize + 34}" font-family="Manrope" font-weight="700" font-size="24" fill="${PAPER}" text-anchor="middle">${esc(t.name)}</text>
      <text x="${cx}" y="${cy + iconSize + 58}" font-family="Manrope" font-weight="700" font-size="16" letter-spacing="1" fill="${statusColor}" fill-opacity="${statusOpacity}" text-anchor="middle">${esc(statusText)}</text>
    `;
  }).join("\n");

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
    <rect width="${w}" height="${h}" fill="${INK}"/>
    ${cells}
    <text x="${w / 2}" y="${h - 18}" font-family="Manrope" font-weight="500" font-size="15" fill="${PAPER}" fill-opacity="0.4" text-anchor="middle">${esc(L(lang, "Обновлено", "Yangilandi"))} ${esc(updatedLabel)}</text>
  </svg>`;
  return rasterize(svg, w, [bold, medium]);
}

// --- 4. Booking ticket ---------------------------------------------------------

export async function renderTicket(opts: {
  clubName: string;
  tableName: string;
  dateLabel: string;
  timeLabel: string;
  durationLabel?: string | null;
  lang: "ru" | "uz";
}): Promise<Uint8Array> {
  const { clubName, tableName, dateLabel, timeLabel, durationLabel, lang } = opts;
  const [bg, extrabold, bold, medium] = await Promise.all([
    bgDataUri("ticket"), font("extrabold"), font("bold"), font("medium"),
  ]);
  const w = 1584, h = 672;
  const leftCx = 460, rightCx = 1150;

  const duration = durationLabel
    ? `<text x="${rightCx}" y="470" font-family="Manrope" font-weight="500" font-size="24" fill="${INK}" fill-opacity="0.6" text-anchor="middle">${esc(durationLabel)}</text>`
    : "";

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
    <image href="${bg}" x="0" y="0" width="${w}" height="${h}" preserveAspectRatio="xMidYMid slice"/>
    <text x="${w / 2}" y="115" font-family="Manrope" font-weight="600" font-size="22" letter-spacing="2" fill="${INK}" fill-opacity="0.55" text-anchor="middle">${esc(clubName.toUpperCase())}</text>
    <text x="${w / 2}" y="160" font-family="Manrope" font-weight="700" font-size="30" fill="${INK}" text-anchor="middle">${esc(L(lang, "Ваша игра", "Sizning o'yiningiz"))}</text>
    <text x="${leftCx}" y="320" font-family="Manrope" font-weight="600" font-size="26" letter-spacing="2" fill="${INK}" fill-opacity="0.55" text-anchor="middle">${esc(L(lang, "СТОЛ", "STOL"))}</text>
    <text x="${leftCx}" y="470" font-family="Manrope" font-weight="800" font-size="150" fill="${INK}" text-anchor="middle">${esc(tableName)}</text>
    <text x="${rightCx}" y="330" font-family="Manrope" font-weight="700" font-size="34" fill="${INK}" text-anchor="middle">${esc(dateLabel)}</text>
    <text x="${rightCx}" y="410" font-family="Manrope" font-weight="800" font-size="60" fill="${INK}" text-anchor="middle">${esc(timeLabel)}</text>
    ${duration}
  </svg>`;
  return rasterize(svg, w, [extrabold, bold, medium]);
}
