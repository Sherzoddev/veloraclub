// Screens of the real client Mini App (miniapp/client-webapp.html from the
// repo), answered with BILLION's real club data (club, tables, prices,
// loyalty tiers, bot) from the database. Only the signed-in client's own
// card/chat/match data is a demo profile, since a real customer's must not
// go into an ad.
import { chromium } from "playwright-core";
import fs from "node:fs";

const CLUB = "bb34ee5d-1f9d-4ae5-8cd7-db9ecd6eacdc";
const HTML = fs.readFileSync(new URL("../../../miniapp/client-webapp.html", import.meta.url), "utf8");
const OUT = "out";
fs.mkdirSync(OUT, { recursive: true });

const iso = (h, m = 0, dayOffset = 0) => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + dayOffset);
  d.setUTCHours(h - 5, m, 0, 0); // Asia/Tashkent is UTC+5
  return d.toISOString();
};

const club = {
  name: "BILLION",
  phone: "+998959695577",
  address: "Ma'rifat ko'chasi 122, Angren",
  lat: 41.0122319653143,
  lng: 70.0756349531502,
  photo: null,
  hours: "11:00 - sóngi mijozgacha",
  botUsername: "billionbiliard_bot",
  hasPlaystation: false,
  hasBilliard: true,
  isOpen: true,
  lateNote: null,
  loyaltyTiers: [
    { name: "Новичок", min_total_spent: 0, earn_percent: 3, discount_percent: 0, color: "#64748B" },
    { name: "Серебро", min_total_spent: 500000, earn_percent: 5, discount_percent: 0, color: "#94A3B8" },
    { name: "Золото", min_total_spent: 2000000, earn_percent: 7, discount_percent: 0, color: "#EAB308" },
    { name: "Платина", min_total_spent: 5000000, earn_percent: 10, discount_percent: 0, color: "#38BDF8" },
  ],
};

const me = {
  hasCard: true,
  ok: true,
  id: "demo",
  name: "Aziz",
  phone: "+998 90 ••• •• ••",
  card_token: "7f3a9c21-5b8e-4d10-a2c4-6e9b1d0f8a73",
  tier: "Золото",
  tier_id: "t3",
  level_seen_tier_id: "t3",
  bonus_points: 48500,
  total_spent: 2740000,
  next_tier: "Платина",
  next_min_total_spent: 5000000,
  to_next: 2260000,
  earn_percent: 7,
  discount_percent: 0,
  visits: 23,
};

const resources = [
  ["570f32df-41fe-4f0d-b215-2b193957c4d6", "1 Stol", 1],
  ["9e414228-6992-4ec3-bd15-fd635b01e690", "2 Stol", 2],
  ["9bf21f6c-62ff-4fd2-bdf2-90725ad6f16d", "3 Stol", 3],
].map(([id, name, number]) => ({
  id, name, number, photo_url: null, status: "FREE", is_free: true,
  type_name: "Бильярдный стол", family: "BILLIARD", family_label: "Бильярдный стол",
  price_per_hour: 60000, available_in_minutes: null, playing_minutes: null, is_vip: false,
}));

let scenario = {};
const api = (action) => {
  switch (action) {
    case "bootstrap":
    case "me":
      return { authenticated: true, telegramName: "Aziz", club, me, activeReservation: scenario.active ?? null,
        levelUp: false, termsAccepted: true, unreadChat: scenario.unread ?? 0, openMatches: 2 };
    case "resources": return { resources };
    case "availability": {
      const slots = [];
      for (let h = 10; h <= 23; h++) slots.push({ time: `${String(h).padStart(2, "0")}:00`, available: h >= 15 });
      return { slots };
    }
    case "book": return { ok: true, resourceName: "1 Stol", when: "Bugun, 20:00" };
    case "referrals": return { invited: 3, rewarded: 2, totalBonus: 36000 };
    case "chat_messages": return { messages: scenario.chat ?? [] };
    case "match_board": return scenario.board ?? { open: [] };
    case "reservations": return { reservations: [] };
    case "history": return { history: [] };
    case "notifications": return { notifications: [] };
    default: return { ok: true };
  }
};

const TG_STUB = `window.Telegram={WebApp:{initData:'demo',initDataUnsafe:{user:{id:1,first_name:'Aziz'}},version:'8.0',platform:'ios',colorScheme:'dark',themeParams:{},
ready(){},expand(){},setHeaderColor(){},setBackgroundColor(){},disableVerticalSwipes(){},onEvent(){},offEvent(){},
BackButton:{show(){},hide(){},onClick(){},offClick(){}},MainButton:{show(){},hide(){},setText(){},onClick(){}},
HapticFeedback:{impactOccurred(){},notificationOccurred(){},selectionChanged(){}},showConfirm(t,cb){cb(true)},openLink(){},openTelegramLink(){}}};`;

const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium" });
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, locale: "uz-UZ", timezoneId: "Asia/Tashkent" });
await ctx.route("**/*", async (route) => {
  const url = route.request().url();
  if (url.startsWith("https://miniapp.local/")) return route.fulfill({ contentType: "text/html", body: HTML });
  if (url.includes("receipt_logo.png")) return route.fulfill({ contentType: "image/png", body: fs.readFileSync("billion_logo_crop.png") });
  if (url.includes("telegram-web-app.js")) return route.fulfill({ contentType: "text/javascript", body: TG_STUB });
  if (url.includes("lucide")) return route.fulfill({ contentType: "text/javascript", body: fs.readFileSync("node_modules/lucide/dist/umd/lucide.min.js") });
  if (url.includes("qrcode")) return route.fulfill({ contentType: "text/javascript", body: fs.readFileSync("node_modules/qrcodejs/qrcode.js") });
  if (url.includes("functions/v1/client-webapp")) {
    const body = JSON.parse(route.request().postData() || "{}");
    return route.fulfill({ contentType: "application/json", body: JSON.stringify(api(body.action)) });
  }
  return route.fulfill({ status: 404, body: "" });
});

const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("PAGEERROR", e.message));
const shot = async (name) => {
  await page.evaluate(() => window.lucide?.createIcons?.());
  await page.waitForTimeout(700);
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log("shot", name);
};
const open = async () => {
  await page.goto(`https://miniapp.local/?c=${CLUB}`);
  await page.waitForTimeout(1500);
};

const boxes = {};
const box = async (name, selector) => {
  const b = await page.locator(selector).first().boundingBox();
  boxes[name] = { x: b.x + b.width / 2, y: b.y + b.height / 2 };
};

// --- screens ---
await open();
await shot("01_home");

await box("home_cta", ".cta");
await page.evaluate(() => switchTab("tables"));
await page.waitForTimeout(800);
await shot("02_tables");
await box("tables_first", ".resource");

await page.evaluate(() => openResource(state.resources[0]));
await page.waitForTimeout(1200);
await shot("03_booking");
await box("booking_2h", '[data-duration="120"]');
await page.click('[data-duration="120"]');
await page.waitForTimeout(800);
await box("booking_20", '[data-time="20:00"]');
await page.click('[data-time="20:00"]');
await page.waitForTimeout(400);
await page.evaluate(() => document.querySelector("#bookBtn").scrollIntoView({ block: "end" }));
await shot("04_booking_selected");
await box("booking_btn", "#bookBtn");
await page.click("#bookBtn");
await page.waitForTimeout(1200);
await shot("05_booking_success");

await open();
await page.evaluate(() => showLoyalty());
await page.waitForTimeout(900);
await shot("06_card");
await page.evaluate(() => document.querySelector(".sheet-card").scrollTo(0, 9999));
await shot("07_card_levels");

await open();
await page.evaluate(() => showReferral());
await page.waitForTimeout(1200);
await shot("08_referral");

scenario.board = {
  open: [
    { id: "m1", name: "Sardor", visits: 14, play_at: iso(20), level: "MID", comment: "Pul tikmasdan, do'stona o'yin" },
    { id: "m2", name: "Jasur", visits: 31, play_at: iso(21, 30), level: "PRO", comment: null },
  ],
};
await open();
await page.evaluate(() => showMatch());
await page.waitForTimeout(1200);
await shot("09_match_board");
await box("match_play", ".play-btn");
scenario.board = {
  mine: { id: "m3", status: "MATCHED", play_at: iso(20), level: "MID", comment: null,
    opponent: { name: "Sardor", visits: 14 } },
  open: [],
};
await page.evaluate(() => { mtStop?.(); showMatch(); });
await page.waitForTimeout(1200);
await shot("10_match_found");

scenario.chat = [
  { id: "c1", sender_type: "CLIENT", body: "Salom! Bugun 21:00 ga stol bo'shmi?", created_at: iso(18, 2), read_at: iso(18, 3) },
  { id: "c2", sender_type: "ADMIN", body: "Assalomu alaykum! Ha, bo'sh 👍 Band qilib qo'yaymi?", created_at: iso(18, 3), read_at: iso(18, 3) },
  { id: "c3", sender_type: "CLIENT", body: "Ha, iltimos 🙏", created_at: iso(18, 4), read_at: iso(18, 4) },
  { id: "c4", sender_type: "ADMIN", body: "Tayyor! Sizni 21:00 da kutamiz 🎱", created_at: iso(18, 5), read_at: null },
];
await open();
await page.evaluate(() => showChat());
await page.waitForTimeout(1500);
await shot("11_chat");

await open();
await page.evaluate(() => switchTab("club"));
await page.waitForTimeout(800);
await shot("12_club");

await page.evaluate(() => switchTab("profile"));
await page.waitForTimeout(800);
await shot("13_profile");

fs.writeFileSync(`${OUT}/boxes.json`, JSON.stringify(boxes, null, 1));
await browser.close();
