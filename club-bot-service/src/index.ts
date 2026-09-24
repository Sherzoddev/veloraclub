// The club's own Telegram bot — one bot, two audiences.
//
// Which club an update belongs to comes from a secret in the webhook URL, so
// a single deployed service serves every club that has pasted a BotFather
// token into the app.
//
// The first person to press /start owns the bot: they become ADMIN, and
// everyone after them is a CLIENT until an admin invites them with a code.
// Клиенты никогда не видят админских кнопок — the menu is built from the
// caller's role, not hidden behind a check.
//
// Ported from the Supabase Edge Function (Deno) version: that architecture
// paid a cold-start tax on nearly every request (confirmed in prod logs --
// even a bare GET with zero DB work took 2+ seconds) because each incoming
// webhook could spin up a fresh Deno isolate. This is the same bot logic
// running as a persistent Node process instead, matching how the club's
// other (faster) reference bot at mini-app/bot is built: one warm process,
// one Supabase client, image/font caches that survive across requests.

import "dotenv/config";
import express from "express";
import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { Agent, fetch as undiciFetch } from "undici";

let imagingModule: Promise<typeof import("./_imaging.js")> | null = null;
const imaging = () => imagingModule ??= import("./_imaging.js");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY не заданы — задайте их в переменных окружения сервиса.");
  process.exit(1);
}

// One client, created once at process start and reused for every request --
// the whole point of running as a persistent process rather than a
// per-request serverless invocation.
// The DB lives in Sydney and this service in Amsterdam: a fresh TLS
// handshake there costs ~3 round trips (~1s). Node's default fetch drops idle
// sockets after 4s, so almost every tap from a quiet bot paid that handshake
// again -- keep sockets open far longer, and keepDbWarm() below stops them
// from going idle at all.
const dbAgent = new Agent({ keepAliveTimeout: 120_000, keepAliveMaxTimeout: 600_000, connections: 16 });
const dbFetch = ((input: any, init?: any) =>
  undiciFetch(input, { ...init, dispatcher: dbAgent })) as unknown as typeof fetch;
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
  global: { fetch: dbFetch },
});

// A handler fans out up to ~3 queries at once, so keep that many sockets hot.
function keepDbWarm() {
  const ping = () => sb.from("clubs").select("id").limit(1).then(() => undefined, () => undefined);
  const tick = () => void Promise.all([ping(), ping(), ping()]);
  tick();
  setInterval(tick, 20_000).unref();
}
keepDbWarm();

type Club = {
  club_id: string;
  club_name: string;
  bot_token: string;
  currency_suffix: string;
  timezone: string;
  bot_welcome_photo_url: string | null;
};

const clubCache = new Map<string, { value: any; expiresAt: number }>();
async function clubBySecret(sb: SupabaseClient, secret: string) {
  const cached = clubCache.get(secret);
  if (cached && cached.expiresAt > Date.now()) return cached.value;
  const { data } = await sb.rpc("bot_club_by_secret", { p_secret: secret });
  if (data?.ok) clubCache.set(secret, { value: data, expiresAt: Date.now() + 5 * 60_000 });
  return data;
}

// Language, role and terms acceptance are read on every single update but
// almost never change -- remembering them skips a whole Sydney round trip
// per tap. Short TTL so an admin revoked elsewhere loses access quickly.
type UserCtx = { lang: Lang; role: string; termsAccepted: boolean; expiresAt: number };
const userCache = new Map<string, UserCtx>();
const USER_TTL = 3 * 60_000;
const userKey = (clubId: string, tgId: number) => `${clubId}:${tgId}`;
function patchUserCache(clubId: string, tgId: number, patch: Partial<UserCtx>) {
  const key = userKey(clubId, tgId);
  const current = userCache.get(key);
  if (current) userCache.set(key, { ...current, ...patch });
}

// Mirrors the Mini App's own gate (client-webapp bootstrap checks the same
// cash_shifts row) so a client can't start a booking through the bot's text
// menu during a window the site already refuses -- not cached, a shift that
// just closed must stop bookings immediately, not up to a minute later.
async function isClubOpen(sb: SupabaseClient, clubId: string): Promise<boolean> {
  const { data } = await sb.from("cash_shifts").select("id").eq("club_id", clubId).eq("status", "OPEN").limit(1).maybeSingle();
  return Boolean(data);
}

type Lang = "ru" | "uz";
const L = (lang: Lang, ru: string, uz: string) => (lang === "uz" ? uz : ru);

const money = (n: number) => new Intl.NumberFormat("ru-RU").format(Math.round(n));

const DIVIDER = "┄┄┄┄┄┄┄┄┄┄┄┄";

const medal = (i: number) => (i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : `${i + 1}.`);

function hhmm(iso: string, timeZone: string) {
  return new Intl.DateTimeFormat("ru-RU", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .format(new Date(iso));
}

function fmtDateTimeRu(iso: string, timeZone: string) {
  return new Intl.DateTimeFormat("ru-RU", {
    timeZone, day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).format(new Date(iso));
}

function dayLabel(iso: string, timeZone: string) {
  const d = new Intl.DateTimeFormat("ru-RU", { timeZone, day: "2-digit", month: "2-digit" }).format(new Date(iso));
  return `${d} ${hhmm(iso, timeZone)}`;
}

const MONTHS_RU = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
const MONTHS_UZ = ["yanvar", "fevral", "mart", "aprel", "may", "iyun", "iyul", "avgust", "sentabr", "oktabr", "noyabr", "dekabr"];
const WEEKDAYS_RU = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"];
const WEEKDAYS_UZ = ["yakshanba", "dushanba", "seshanba", "chorshanba", "payshanba", "juma", "shanba"];

function ticketDateLabel(iso: string, timeZone: string, lang: Lang): string {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, day: "numeric", month: "numeric", weekday: "short" })
    .formatToParts(new Date(iso));
  const day = Number(parts.find((p) => p.type === "day")?.value ?? "1");
  const month = Number(parts.find((p) => p.type === "month")?.value ?? "1") - 1;
  const weekdayShort = parts.find((p) => p.type === "weekday")?.value ?? "Sun";
  const shortToIndex: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const wd = shortToIndex[weekdayShort] ?? 0;
  return lang === "uz"
    ? `${day}-${MONTHS_UZ[month]}, ${WEEKDAYS_UZ[wd]}`
    : `${day} ${MONTHS_RU[month]}, ${WEEKDAYS_RU[wd]}`;
}

function zonedTimeToUtc(y: number, mo: number, d: number, hh: number, mm: number, timeZone: string): Date {
  const guess = Date.UTC(y, mo - 1, d, hh, mm, 0);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(guess));
  const map = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  const readBack = Date.UTC(+map.year, +map.month - 1, +map.day, +map.hour, +map.minute, +map.second);
  return new Date(guess - (readBack - guess));
}

function todayInZone(timeZone: string): { y: number; mo: number; d: number } {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date());
  const map = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  return { y: +map.year, mo: +map.month, d: +map.day };
}

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

function upcomingSlots(timeZone: string, count = 6): string[] {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(new Date());
  const map = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  const h = Number(map.hour);
  const start = Number(map.minute) === 0 ? h : h + 1;
  return Array.from({ length: count }, (_, i) => `${String((start + i) % 24).padStart(2, "0")}:00`);
}

function elapsedLabel(startedAtIso: string, lang: Lang = "ru"): string {
  const totalMin = Math.max(0, Math.floor((Date.now() - new Date(startedAtIso).getTime()) / 60_000));
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h === 0) return L(lang, `играют ${m} мин`, `${m} min o'ynashmoqda`);
  return m === 0
    ? L(lang, `играют ${h} ч`, `${h} soat o'ynashmoqda`)
    : L(lang, `играют ${h} ч ${m} мин`, `${h} soat ${m} min o'ynashmoqda`);
}

const pad = (n: number) => String(n).padStart(2, "0");
const isoDate = (y: number, mo: number, d: number) => `${y}-${pad(mo)}-${pad(d)}`;
const fmtDateRu = (y: number, mo: number, d: number) => `${pad(d)}.${pad(mo)}.${y}`;

function dayBoundsUtc(y: number, mo: number, d: number, timeZone: string): { from: string; to: string } {
  const from = zonedTimeToUtc(y, mo, d, 0, 0, timeZone);
  const next = new Date(Date.UTC(y, mo - 1, d + 1));
  const to = zonedTimeToUtc(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), 0, 0, timeZone);
  return { from: from.toISOString(), to: to.toISOString() };
}

const MONTH_NAMES = [
  "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
  "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
];

function buildCalendar(y: number, mo: number) {
  const daysInMonth = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  const firstWeekday = (new Date(Date.UTC(y, mo - 1, 1)).getUTCDay() + 6) % 7;
  const blank = { text: " ", callback_data: "noop" };

  const rows: Array<Array<{ text: string; callback_data: string }>> = [
    [{ text: `${MONTH_NAMES[mo - 1]} ${y}`, callback_data: "noop" }],
    ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"].map((d) => ({ text: d, callback_data: "noop" })),
  ];
  let week = new Array(firstWeekday).fill(blank);
  for (let d = 1; d <= daysInMonth; d++) {
    week.push({ text: String(d), callback_data: `calday:${isoDate(y, mo, d)}` });
    if (week.length === 7) {
      rows.push(week);
      week = [];
    }
  }
  if (week.length) rows.push([...week, ...new Array(7 - week.length).fill(blank)]);

  const prev = mo === 1 ? { y: y - 1, mo: 12 } : { y, mo: mo - 1 };
  const next = mo === 12 ? { y: y + 1, mo: 1 } : { y, mo: mo + 1 };
  rows.push([
    { text: "◂", callback_data: `calnav:${prev.y}-${pad(prev.mo)}` },
    { text: "Назад", callback_data: "rep:menu" },
    { text: "▸", callback_data: `calnav:${next.y}-${pad(next.mo)}` },
  ]);
  return { inline_keyboard: rows };
}

const ADMIN = {
  hall: "🎮 Карта зала",
  bookings: "📅 Брони",
  top: "🏆 Клиенты",
  stats: "📊 Статистика",
} as const;

const CLIENT_LABELS = {
  tables: { ru: "🎮 Свободные столы", uz: "🎮 Bo'sh joylar" },
  book: { ru: "📅 Забронировать", uz: "📅 Band qilish" },
  bonus: { ru: "🎁 Мои бонусы", uz: "🎁 Bonuslarim" },
  me: { ru: "👤 Мои данные", uz: "👤 Ma'lumotlarim" },
  invite: { ru: "🤝 Пригласить друга", uz: "🤝 Do'stni taklif qilish" },
  lang: { ru: "🌐 Язык", uz: "🌐 Til" },
} as const;
type ClientAction = keyof typeof CLIENT_LABELS;

const clientLabel = (action: ClientAction, lang: Lang) => CLIENT_LABELS[action][lang];

function clientActionFor(text: string): ClientAction | null {
  for (const key of Object.keys(CLIENT_LABELS) as ClientAction[]) {
    if (CLIENT_LABELS[key].ru === text || CLIENT_LABELS[key].uz === text) return key;
  }
  return null;
}

const adminKeyboard = {
  keyboard: [
    [{ text: ADMIN.hall }, { text: ADMIN.bookings }],
    [{ text: ADMIN.top }, { text: ADMIN.stats }],
  ],
  resize_keyboard: true,
  is_persistent: true,
};

const MINI_APP_URL = "https://velora-club-miniapp-production.up.railway.app/";
// A wholly separate Mini App (its own edge function, its own auth check by
// ADMIN role) — never the client one, so a bug in the client app can't leak
// into admin tooling and vice versa.
const ADMIN_APP_URL = "https://velora-club-miniapp-production.up.railway.app/admin";

const clientKeyboardFor = (lang: Lang, clubId?: string) => ({
  // The "✨ Открыть приложение" reply-keyboard web_app button was removed:
  // it intermittently launched the Mini App as an unauthenticated guest
  // (initData not delivered), unlike the persistent Menu Button set in
  // showMenu() via setChatMenuButton, which opens the account correctly.
  keyboard: [
    [{ text: clientLabel("tables", lang) }, { text: clientLabel("book", lang) }],
    [{ text: clientLabel("bonus", lang) }, { text: clientLabel("me", lang) }],
    [{ text: clientLabel("invite", lang) }, { text: clientLabel("lang", lang) }],
  ],
  resize_keyboard: true,
  is_persistent: true,
});

const contactKeyboardFor = (lang: Lang) => ({
  keyboard: [[{ text: L(lang, "📱 Отправить номер", "📱 Raqamni yuborish"), request_contact: true }]],
  resize_keyboard: true,
  one_time_keyboard: true,
});

const menuFor = (role: string, lang: Lang) =>
  role === "ADMIN" ? adminKeyboard : clientKeyboardFor(lang);

async function tg(token: string, method: string, body: unknown) {
  const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) console.error(method, await res.text());
  return res;
}

const send = (token: string, chat_id: number, text: string, extra: Record<string, unknown> = {}) =>
  tg(token, "sendMessage", { chat_id, text, parse_mode: "HTML", ...extra });

// Mandatory before anything else works: a fresh chat_id/telegram_id gets no
// menu, no booking, nothing -- just this prompt -- until they tap "Roziman".
// Declining re-shows the same prompt instead of letting them through, since
// there is no partial-use state for the bot.
const TERMS_TEXT = (lang: Lang) => L(
  lang,
  "📋 <b>Пользовательское соглашение</b>\n\nПрежде чем пользоваться ботом, ознакомьтесь с условиями:\n\n" +
    "• Для брони, карты клиента и бонусов сохраняются ваше имя, номер телефона и Telegram ID.\n" +
    "• Эти данные используются только для обслуживания в этом клубе и не передаются третьим лицам.\n" +
    "• Продолжая пользоваться ботом, вы соглашаетесь с этими условиями.\n\n" +
    "Согласны продолжить?",
  "📋 <b>Foydalanuvchi shartnomasi</b>\n\nBotdan foydalanishdan oldin shartlarga tanishib chiqing:\n\n" +
    "• Bron qilish, mijoz kartasi va bonuslar uchun ismingiz, telefon raqamingiz va Telegram ID'ingiz saqlanadi.\n" +
    "• Bu ma'lumotlar faqat shu klub ichida xizmat ko'rsatish uchun ishlatiladi va uchinchi shaxslarga berilmaydi.\n" +
    "• Botdan foydalanishni davom ettirish shartlarga roziligingizni bildiradi.\n\n" +
    "Davom etish uchun shartlarga rozimisiz?",
);
async function sendTermsPrompt(token: string, chatId: number, lang: Lang, declined: boolean) {
  const text = declined
    ? L(lang,
        "❗ Чтобы пользоваться ботом, нужно согласиться с условиями. Без согласия бот работать не будет.\n\n",
        "❗ Botdan foydalanish uchun shartlarga rozi bo'lishingiz shart. Rozi bo'lmasangiz, botdan foydalana olmaysiz.\n\n")
      + TERMS_TEXT(lang)
    : TERMS_TEXT(lang);
  await send(token, chatId, text, {
    reply_markup: {
      inline_keyboard: [[
        { text: L(lang, "✅ Согласен", "✅ Roziman"), callback_data: "terms:accept" },
        { text: L(lang, "❌ Не согласен", "❌ Rozi emasman"), callback_data: "terms:decline" },
      ]],
    },
  });
}

async function sendDocument(token: string, chat_id: number, filename: string, csv: string, caption: string) {
  const form = new FormData();
  form.append("chat_id", String(chat_id));
  form.append("caption", caption);
  form.append("parse_mode", "HTML");
  form.append("document", new Blob(["﻿" + csv], { type: "text/csv; charset=utf-8" }), filename);
  const res = await fetch(`https://api.telegram.org/bot${token}/sendDocument`, { method: "POST", body: form });
  if (!res.ok) console.error("sendDocument", await res.text());
}

async function sendPhotoBytes(
  token: string, chat_id: number, bytes: Uint8Array,
  opts: { caption?: string; reply_markup?: unknown } = {},
) {
  const form = new FormData();
  form.append("chat_id", String(chat_id));
  if (opts.caption) {
    form.append("caption", opts.caption);
    form.append("parse_mode", "HTML");
  }
  if (opts.reply_markup) form.append("reply_markup", JSON.stringify(opts.reply_markup));
  form.append("photo", new Blob([Buffer.from(bytes)], { type: "image/png" }), "image.png");
  const res = await fetch(`https://api.telegram.org/bot${token}/sendPhoto`, { method: "POST", body: form });
  if (!res.ok) console.error("sendPhoto", await res.text());
}

async function sendWelcomePoster(club: Club, token: string, chatId: number, lang: Lang) {
  if (club.bot_welcome_photo_url) return;
  const png = await (await imaging()).renderPoster(club.club_name, lang);
  await sendPhotoBytes(token, chatId, png);
}


const csvCell = (v: unknown) => {
  const s = String(v ?? "");
  return /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const csvRows = (rows: unknown[][]) => rows.map((r) => r.map(csvCell).join(";")).join("\r\n");

async function setPending(sb: SupabaseClient, clubId: string, tgId: number, action: string | null, payload: unknown = {}) {
  await sb.from("bot_state").upsert({
    telegram_id: Number(`${tgId}`),
    pending_action: action === null ? null : `${clubId}:${action}`,
    payload: payload ?? {},
    updated_at: new Date().toISOString(),
  });
}

async function getPending(sb: SupabaseClient, clubId: string, tgId: number) {
  const { data } = await sb.from("bot_state")
    .select("pending_action, payload").eq("telegram_id", tgId).maybeSingle();
  if (!data?.pending_action) return null;
  const prefix = `${clubId}:`;
  if (!String(data.pending_action).startsWith(prefix)) return null;
  return {
    action: String(data.pending_action).slice(prefix.length),
    payload: (data.payload ?? {}) as Record<string, any>,
  };
}

async function getLang(sb: SupabaseClient, tgId: number): Promise<Lang> {
  const { data } = await sb.from("bot_state").select("language").eq("telegram_id", tgId).maybeSingle();
  return data?.language === "ru" ? "ru" : "uz";
}

async function setLang(sb: SupabaseClient, tgId: number, lang: Lang) {
  await sb.from("bot_state").upsert(
    { telegram_id: tgId, language: lang, updated_at: new Date().toISOString() },
    { onConflict: "telegram_id" },
  );
}

async function showLangPicker(token: string, chatId: number, lang: Lang) {
  await send(token, chatId, L(lang, "🌐 <b>Выберите язык</b>", "🌐 <b>Tilni tanlang</b>"), {
    reply_markup: {
      inline_keyboard: [[
        { text: "🇷🇺 Русский", callback_data: "setlang:ru" },
        { text: "🇺🇿 O'zbekcha", callback_data: "setlang:uz" },
      ]],
    },
  });
}

async function adminHall(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const { data, error } = await sb.rpc("bot_resource_board", { p_club_id: club.club_id });
  if (error) return void send(token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: adminKeyboard });
  const list = (data ?? []) as Array<Record<string, unknown>>;
  if (list.length === 0) {
    return void send(token, chatId, "🎮 Мест пока нет — добавьте их в программе.", { reply_markup: adminKeyboard });
  }

  const free = list.filter((r) => r.is_free).length;
  const rows = list
    .map((r) => {
      const busyLabel = r.is_free ? "свободен" : (r.started_at ? elapsedLabel(String(r.started_at)) : "занят");
      return `${r.is_free ? "🟢" : "🔴"} <b>${r.name}</b> — ${busyLabel}`;
    })
    .join("\n");
  await send(
    token, chatId,
    `🎮 <b>Карта зала</b>\n${DIVIDER}\nСвободно <b>${free}</b> из ${list.length}\n\n${rows}`,
    { reply_markup: adminKeyboard },
  );
}

async function adminBookings(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const { data } = await sb.rpc("bot_admin_snapshot", { p_club_id: club.club_id });
  const list = (data?.upcoming ?? []) as Array<Record<string, unknown>>;
  if (list.length === 0) {
    return void send(token, chatId, "📅 Ближайших броней нет.", { reply_markup: adminKeyboard });
  }
  // A tap picks one booking (bpick:<id>, handled below) instead of dumping
  // every booking as plain text with no way to act on any single one --
  // picking shows that booking's own confirm/cancel/message buttons.
  await send(
    token, chatId,
    `📅 <b>Брони</b>\n${DIVIDER}\n\nВыберите бронь:`,
    {
      reply_markup: {
        inline_keyboard: list.map((r) => [{
          text: `🕒 ${hhmm(String(r.starts_at), club.timezone)} · ${r.resource_name} · ${r.customer_name ?? "Гость"}`,
          callback_data: `bpick:${r.id}`,
        }]),
      },
    },
  );
}

async function adminBookingDetail(sb: SupabaseClient, club: Club, token: string, chatId: number, reservationId: string) {
  const ctx = await reservationContext(sb, club.club_id, reservationId);
  if (!ctx) {
    return void send(token, chatId, "Эта бронь не найдена.", { reply_markup: adminKeyboard });
  }
  await send(
    token, chatId,
    `📅 <b>${ctx.resourceName}</b>\n${dayLabel(ctx.startsAt, club.timezone)}\n👤 ${ctx.customerName ?? "Гость"}`,
    {
      reply_markup: {
        inline_keyboard: [
          [{ text: "✅ Подтвердить", callback_data: `rconf:${ctx.id}` }],
          [{ text: "❌ Отменить", callback_data: `cancelres:${ctx.id}` }],
          [{ text: "✉ Написать клиенту", callback_data: `rcli:${ctx.id}` }],
        ],
      },
    },
  );
}

async function adminTop(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const { data, error } = await sb
    .from("customers")
    .select("full_name, phone, total_spent, visits_count, bonus_points")
    .eq("club_id", club.club_id)
    .order("total_spent", { ascending: false })
    .limit(10);
  if (error) return void send(token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: adminKeyboard });
  const list = data ?? [];
  if (list.length === 0) return void send(token, chatId, "🏆 Клиентов пока нет.", { reply_markup: adminKeyboard });

  const text = list
    .map((c: Record<string, unknown>, i: number) =>
      `${medal(i)} <b>${c.full_name ?? "Без имени"}</b>\n` +
      `   ${money(Number(c.total_spent ?? 0))} ${club.currency_suffix} · ${c.visits_count ?? 0} визитов`
    )
    .join("\n");
  await send(token, chatId, `🏆 <b>Топ клиентов</b>\n${DIVIDER}\n\n${text}`, { reply_markup: adminKeyboard });
}

async function adminStats(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  // club_bot_users gets a row for every distinct tg_id that has ever
  // messaged this club's bot (see bot_role_for) -- CLIENT rows are the
  // "subscribed" count the admin actually cares about, ADMIN/staff rows
  // excluded. customers.telegram_id is only set once someone shares their
  // contact through the bot (bot_link_player), i.e. opened their own card
  // rather than a cashier creating it at the register.
  const [{ count: subscribers }, { count: cardHolders }] = await Promise.all([
    sb.from("club_bot_users").select("*", { count: "exact", head: true })
      .eq("club_id", club.club_id).eq("role", "CLIENT"),
    sb.from("customers").select("*", { count: "exact", head: true })
      .eq("club_id", club.club_id).not("telegram_id", "is", null),
  ]);
  const subs = subscribers ?? 0;
  const cards = cardHolders ?? 0;
  const rate = subs > 0 ? Math.round((cards / subs) * 100) : 0;
  await send(
    token, chatId,
    `📊 <b>Статистика бота</b>\n${DIVIDER}\n\n` +
      `👥 Подписались на бота: <b>${subs}</b>\n` +
      `💳 Открыли себе карту: <b>${cards}</b>\n\n` +
      `📈 Конверсия в карту: <b>${rate}%</b>`,
    { reply_markup: adminKeyboard },
  );
}

async function showReportMenu(token: string, chatId: number) {
  await send(token, chatId, "📈 <b>Отчёты</b>\n\nОтчёт считается за смену — от открытия до закрытия кассы.", {
    reply_markup: {
      inline_keyboard: [
        [{ text: "Текущая смена", callback_data: "rep:cur" }, { text: "Прошлая смена", callback_data: "rep:prev" }],
        [{ text: "📋 Последние смены", callback_data: "rep:list" }],
        [{ text: "🗓 Выбрать день", callback_data: "rep:cal" }],
        [{ text: "Топ товаров", callback_data: "rep:topprod" }],
      ],
    },
  });
}

type ShiftRow = {
  id: string;
  status: string;
  opened_at: string;
  closed_at: string | null;
  opener: { full_name: string | null } | null;
  closer: { full_name: string | null } | null;
};

const SHIFT_SELECT =
  "id,status,opened_at,closed_at," +
  "opener:profiles!cash_shifts_opened_by_fkey(full_name),closer:profiles!cash_shifts_closed_by_fkey(full_name)";

function durationLabel(fromIso: string, toIso: string): string {
  const totalMin = Math.max(0, Math.floor((new Date(toIso).getTime() - new Date(fromIso).getTime()) / 60_000));
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  return h === 0 ? `${m} мин` : m === 0 ? `${h} ч` : `${h} ч ${m} мин`;
}

// Short "24.09 18:00 – 25.09 06:00" label for shift picker buttons.
function shiftButtonLabel(s: ShiftRow, timeZone: string): string {
  const end = s.closed_at ? dayLabel(s.closed_at, timeZone) : "сейчас";
  return `${s.status === "OPEN" ? "🟢 " : ""}${dayLabel(s.opened_at, timeZone)} – ${end}`;
}

async function shiftById(sb: SupabaseClient, clubId: string, id: string): Promise<ShiftRow | null> {
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT).eq("club_id", clubId).eq("id", id).maybeSingle();
  return (data as unknown as ShiftRow) ?? null;
}

async function recentShifts(sb: SupabaseClient, clubId: string, limit: number): Promise<ShiftRow[]> {
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT)
    .eq("club_id", clubId).order("opened_at", { ascending: false }).limit(limit);
  return (data ?? []) as unknown as ShiftRow[];
}

// A shift runs from its opening to its closing (or to now while it's still
// open) -- e.g. opened on the 24th in the evening, closed on the 25th in the
// morning -- so the owner sees the whole shift, not a calendar day cut at 00:00.
function shiftBounds(s: ShiftRow): { from: string; to: string } {
  return { from: s.opened_at, to: s.closed_at ?? new Date().toISOString() };
}

function shiftHeader(s: ShiftRow, timeZone: string): string {
  const { to } = shiftBounds(s);
  const opener = s.opener?.full_name ? ` · ${s.opener.full_name}` : "";
  const closer = s.closer?.full_name ? ` · ${s.closer.full_name}` : "";
  const closedLine = s.closed_at
    ? `🔴 Закрыта: <b>${fmtDateTimeRu(s.closed_at, timeZone)}</b>${closer}`
    : `🟢 Смена открыта — идёт сейчас`;
  return (
    `🕘 Открыта: <b>${fmtDateTimeRu(s.opened_at, timeZone)}</b>${opener}\n` +
    `${closedLine}\n` +
    `⏱ Длительность: ${durationLabel(s.opened_at, to)}`
  );
}

function reportBody(data: Record<string, any> | null, cur: string): string {
  const byMethod = Object.entries((data?.by_payment_method ?? {}) as Record<string, number>)
    .map(([name, amount]) => `${name} — ${money(amount)} ${cur}`)
    .join("\n");

  const discountByReason = Object.entries((data?.discount_by_reason ?? {}) as Record<string, number>)
    .map(([reason, amount]) => `  · ${reason} — ${money(amount)} ${cur}`)
    .join("\n");

  return (
    `Выручка: <b>${money(Number(data?.revenue ?? 0))} ${cur}</b> · ${data?.orders_count ?? 0} чеков\n\n` +
    `PlayStation: ${money(Number(data?.time_playstation ?? 0))} ${cur}\n` +
    `Бильярд: ${money(Number(data?.time_billiard ?? 0))} ${cur}\n` +
    `Товары: ${money(Number(data?.products ?? 0))} ${cur}\n` +
    `Прибыль бара: <b>${money(Number(data?.bar_profit ?? 0))} ${cur}</b>\n` +
    (byMethod ? `\n${byMethod}\n` : "\n") +
    `\nРасходы: ${money(Number(data?.expenses ?? 0))} ${cur}\n` +
    (Number(data?.discount_total ?? 0) > 0
      ? `Скидки: ${money(Number(data?.discount_total))} ${cur}\n${discountByReason}\n`
      : "") +
    `\nЧистая прибыль: <b>${money(Number(data?.net_profit ?? 0))} ${cur}</b>`
  );
}

function reportRows(report: Record<string, any> | null, top: Array<Record<string, unknown>> | null): unknown[][] {
  return [
    ["Выручка", report?.revenue ?? 0],
    ["Чеков", report?.orders_count ?? 0],
    ["PlayStation", report?.time_playstation ?? 0],
    ["Бильярд", report?.time_billiard ?? 0],
    ["Товары", report?.products ?? 0],
    ["Себестоимость товаров", report?.products_cost ?? 0],
    ["Прибыль бара", report?.bar_profit ?? 0],
    ["Расходы", report?.expenses ?? 0],
    ["Скидки всего", report?.discount_total ?? 0],
    ["Чистая прибыль", report?.net_profit ?? 0],
    [],
    ["Способ оплаты", "Сумма"],
    ...Object.entries((report?.by_payment_method ?? {}) as Record<string, number>),
    [],
    ["Причина скидки", "Сумма"],
    ...Object.entries((report?.discount_by_reason ?? {}) as Record<string, number>),
    [],
    ["Товар", "Категория", "Кол-во", "Выручка"],
    ...(top ?? []).map((p) => [p.product_name, p.category_name ?? "", p.quantity, p.revenue]),
  ];
}

async function showShiftReport(
  sb: SupabaseClient, club: Club, token: string, chatId: number, shift: ShiftRow, note = "",
) {
  const { from, to } = shiftBounds(shift);
  const { data, error } = await sb.rpc("bot_period_report", { p_club_id: club.club_id, p_from: from, p_to: to });
  if (error) return void send(token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: adminKeyboard });

  const text =
    `📈 <b>Отчёт за смену</b>\n` +
    (note ? `<i>${note}</i>\n` : "") +
    `\n${shiftHeader(shift, club.timezone)}\n${DIVIDER}\n\n` +
    reportBody(data, club.currency_suffix);

  await send(token, chatId, text, {
    reply_markup: {
      inline_keyboard: [
        [{ text: "📥 Скачать Excel", callback_data: `shxls:${shift.id}` }],
        [{ text: "📋 Другие смены", callback_data: "rep:list" }],
      ],
    },
  });
}

async function showCurrentShiftReport(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const [latest] = await recentShifts(sb, club.club_id, 1);
  if (!latest) return void send(token, chatId, "Смен пока не было.", { reply_markup: adminKeyboard });
  const note = latest.status === "OPEN" ? "" : "Сейчас смена не открыта — показана последняя закрытая.";
  await showShiftReport(sb, club, token, chatId, latest, note);
}

async function showPreviousShiftReport(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT)
    .eq("club_id", club.club_id).neq("status", "OPEN")
    .order("opened_at", { ascending: false }).limit(1).maybeSingle();
  if (!data) return void send(token, chatId, "Закрытых смен пока нет.", { reply_markup: adminKeyboard });
  await showShiftReport(sb, club, token, chatId, data as unknown as ShiftRow);
}

async function sendShiftPicker(token: string, chatId: number, title: string, shifts: ShiftRow[], timeZone: string) {
  await send(token, chatId, title, {
    reply_markup: {
      inline_keyboard: [
        ...shifts.map((s) => [{ text: shiftButtonLabel(s, timeZone), callback_data: `shift:${s.id}` }]),
        [{ text: "Назад", callback_data: "rep:menu" }],
      ],
    },
  });
}

async function showShiftList(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const shifts = await recentShifts(sb, club.club_id, 10);
  if (shifts.length === 0) return void send(token, chatId, "Смен пока не было.", { reply_markup: adminKeyboard });
  await sendShiftPicker(token, chatId, "📋 <b>Последние смены</b>\n\nВыберите смену:", shifts, club.timezone);
}

// Calendar pick: the shifts opened on that day (a shift opened on the 24th
// and closed on the 25th belongs to the 24th).
async function showShiftsForDay(
  sb: SupabaseClient, club: Club, token: string, chatId: number, y: number, mo: number, d: number,
) {
  const { from, to } = dayBoundsUtc(y, mo, d, club.timezone);
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT)
    .eq("club_id", club.club_id).gte("opened_at", from).lt("opened_at", to)
    .order("opened_at", { ascending: true });
  const shifts = (data ?? []) as unknown as ShiftRow[];
  if (shifts.length === 1) return showShiftReport(sb, club, token, chatId, shifts[0]);
  if (shifts.length === 0) {
    return void send(token, chatId, `${fmtDateRu(y, mo, d)} смена не открывалась.`, {
      reply_markup: {
        inline_keyboard: [[
          { text: "🗓 Другой день", callback_data: `calnav:${y}-${pad(mo)}` },
          { text: "Назад", callback_data: "rep:menu" },
        ]],
      },
    });
  }
  await sendShiftPicker(token, chatId, `Смены за ${fmtDateRu(y, mo, d)}:`, shifts, club.timezone);
}

async function sendShiftReportExcel(sb: SupabaseClient, club: Club, token: string, chatId: number, shift: ShiftRow) {
  const { from, to } = shiftBounds(shift);
  const [{ data: report }, { data: top }] = await Promise.all([
    sb.rpc("bot_period_report", { p_club_id: club.club_id, p_from: from, p_to: to }),
    sb.rpc("bot_top_products", { p_club_id: club.club_id, p_from: from, p_to: to, p_limit: 100 }),
  ]);
  const opened = fmtDateTimeRu(shift.opened_at, club.timezone);
  const closed = shift.closed_at ? fmtDateTimeRu(shift.closed_at, club.timezone) : "смена открыта";
  const rows: unknown[][] = [
    ["Отчёт за смену"],
    ["Открыта", opened, shift.opener?.full_name ?? ""],
    ["Закрыта", closed, shift.closer?.full_name ?? ""],
    ["Длительность", durationLabel(from, to)],
    [],
    ...reportRows(report, top as Array<Record<string, unknown>> | null),
  ];
  const openedDay = new Intl.DateTimeFormat("en-CA", { timeZone: club.timezone }).format(new Date(shift.opened_at));
  await sendDocument(
    token, chatId, `shift_${openedDay}.csv`, csvRows(rows),
    `📈 Отчёт за смену ${opened} – ${closed}`,
  );
}

// Kept for "📥 Скачать Excel" buttons on day reports already sent before
// reports switched to shifts.
async function sendDayReportExcel(
  sb: SupabaseClient, club: Club, token: string, chatId: number, y: number, mo: number, d: number,
) {
  const { from, to } = dayBoundsUtc(y, mo, d, club.timezone);
  const [{ data: report }, { data: top }] = await Promise.all([
    sb.rpc("bot_period_report", { p_club_id: club.club_id, p_from: from, p_to: to }),
    sb.rpc("bot_top_products", { p_club_id: club.club_id, p_from: from, p_to: to, p_limit: 100 }),
  ]);
  const rows: unknown[][] = [
    ["Отчёт", fmtDateRu(y, mo, d)],
    [],
    ...reportRows(report, top as Array<Record<string, unknown>> | null),
  ];
  await sendDocument(
    token, chatId, `report_${isoDate(y, mo, d)}.csv`, csvRows(rows),
    `📈 Отчёт за ${fmtDateRu(y, mo, d)}`,
  );
}

async function showTopProducts(sb: SupabaseClient, club: Club, token: string, chatId: number) {
  const to = new Date();
  const from = new Date(to.getTime() - 30 * 24 * 3600 * 1000);
  const { data, error } = await sb.rpc("bot_top_products", {
    p_club_id: club.club_id, p_from: from.toISOString(), p_to: to.toISOString(), p_limit: 15,
  });
  if (error) return void send(token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: adminKeyboard });
  const list = (data ?? []) as Array<Record<string, unknown>>;
  if (list.length === 0) {
    return void send(token, chatId, "За последние 30 дней продаж не было.", { reply_markup: adminKeyboard });
  }
  const text = list
    .map((p, i) => `${medal(i)} <b>${p.product_name}</b> — ${p.quantity} шт · ${money(Number(p.revenue))} ${club.currency_suffix}`)
    .join("\n");
  await send(token, chatId, `🏆 <b>Топ товаров за 30 дней</b>\n\n${text}`, { reply_markup: adminKeyboard });
}

async function clientTables(sb: SupabaseClient, club: Club, token: string, chatId: number, lang: Lang) {
  const { data } = await sb.rpc("bot_resource_board", { p_club_id: club.club_id });
  const all = (data ?? []) as Array<Record<string, unknown>>;
  if (all.length === 0) {
    return void send(token, chatId, L(lang, "Мест пока нет 🙁", "Hozircha joy yo'q 🙁"), {
      reply_markup: clientKeyboardFor(lang, club.club_id),
    });
  }
  const freeCount = all.filter((r) => r.is_free).length;
  const text = all.map((r) => {
    const icon = r.family === "BILLIARD" ? "🎱" : "🎮";
    if (r.is_free) {
      return `🟢 ${icon} <b>${r.name}</b> — ${money(Number(r.price_per_hour ?? 0))} ${club.currency_suffix}/${L(lang, "час", "soat")}`;
    }
    const played = r.started_at
      ? elapsedLabel(String(r.started_at), lang)
      : L(lang, "занят", "band");
    return `🔴 ${icon} <b>${r.name}</b> — ${played}`;
  }).join("\n");

  await send(
    token, chatId,
    `🎮 <b>${L(lang, "Столы клуба", "Klub joylari")}</b> · ${L(lang, "свободно", "bo'sh")} ${freeCount}/${all.length}\n${DIVIDER}\n${text}`,
    { reply_markup: clientKeyboardFor(lang, club.club_id) },
  );
}

async function clientBonus(sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number, lang: Lang) {
  const [{ data }, { data: tiers }] = await Promise.all([
    sb.rpc("bot_player_card", { p_club_id: club.club_id, p_tg_id: tgId }),
    sb.from("loyalty_tiers")
      .select("name,min_total_spent,earn_percent,discount_percent")
      .eq("club_id", club.club_id).eq("active", true).order("sort_order"),
  ]);
  if (!data?.ok) {
    return void send(
      token, chatId,
      L(lang,
        "Чтобы копить бонусы, отправьте свой номер — так кассир узнает вас на кассе.",
        "Bonus to'plash uchun raqamingizni yuboring — shunda kassir sizni kassada taniydi."),
      { reply_markup: contactKeyboardFor(lang) },
    );
  }
  const cur = club.currency_suffix;
  const discountPart = Number(data.discount_percent ?? 0) > 0
    ? ` · ${L(lang, "скидка", "chegirma")} ${data.discount_percent}%`
    : "";
  const lines = [
    `🎁 <b>${data.name}</b>`,
    DIVIDER,
    "",
    `🏅 ${L(lang, "Статус", "Holat")}: <b>${data.tier}</b>`,
    `   ${L(lang, "кешбэк", "keshbek")} ${data.earn_percent}%${discountPart}`,
    "",
    `🪙 ${L(lang, "Бонусов", "Bonuslar")}: <b>${money(Number(data.bonus_points ?? 0))}</b>`,
  ];
  if (Number(data.balance ?? 0) > 0) lines.push(`💰 ${L(lang, "На счету", "Hisobda")}: ${money(Number(data.balance))} ${cur}`);
  if (Number(data.debt ?? 0) > 0) lines.push(`📄 ${L(lang, "Долг", "Qarz")}: ${money(Number(data.debt))} ${cur}`);
  lines.push(`📅 ${L(lang, "Визитов", "Tashriflar")}: ${data.visits}`);
  if (data.next_tier) {
    lines.push("", `✨ ${L(lang, "До уровня", "Darajagacha")} «${data.next_tier}»: <b>${money(Number(data.to_next ?? 0))} ${cur}</b>`);
  }

  if (tiers?.length) {
    lines.push("", DIVIDER, "", `📊 <b>${L(lang, "Уровни клуба", "Klub darajalari")}</b>`);
    // Medal-style rank icons instead of a flat "·" bullet, and each tier gets
    // its own two-line block (name, then the numbers indented underneath)
    // instead of one cramped em-dash-separated line -- easier to scan, and
    // the current tier is called out with an arrow instead of blending in.
    const rankIcons = ["🥉", "🥈", "🥇", "💎", "👑"];
    tiers.forEach((t, i) => {
      const icon = rankIcons[i] ?? "⭐";
      const isCurrent = t.name === data.tier;
      const tierDiscount = Number(t.discount_percent ?? 0) > 0
        ? ` · ${L(lang, "скидка", "chegirma")} ${t.discount_percent}%`
        : "";
      lines.push(
        "",
        `${icon} <b>${t.name}</b>${isCurrent ? `  ⬅️ ${L(lang, "ваш уровень", "sizning darajangiz")}` : ""}`,
        `   ${L(lang, "от", "dan")} ${money(Number(t.min_total_spent ?? 0))} ${cur} · ${L(lang, "кешбэк", "keshbek")} ${t.earn_percent}%${tierDiscount}`,
      );
    });
  }

  await send(token, chatId, lines.join("\n"), { reply_markup: clientKeyboardFor(lang, club.club_id) });
}

async function clientReferral(sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number, lang: Lang) {
  const [{ data: card }, { data: bot }, { data: rows }] = await Promise.all([
    sb.rpc("bot_player_card", { p_club_id: club.club_id, p_tg_id: tgId }),
    sb.from("club_bots").select("bot_username").eq("club_id", club.club_id).eq("active", true).limit(1).maybeSingle(),
    sb.from("customer_referrals").select("status,reward_amount,referrer_customer_id").eq("club_id", club.club_id),
  ]);
  if (!card?.ok) {
    return void send(
      token, chatId,
      L(lang, "Сначала отправьте номер, чтобы создать клубную карту.", "Avval klub kartasini yaratish uchun raqamingizni yuboring."),
      { reply_markup: contactKeyboardFor(lang) },
    );
  }
  const username = String(bot?.bot_username ?? "");
  if (!username) return void send(token, chatId, "Бот клуба ещё не настроен.", { reply_markup: clientKeyboardFor(lang, club.club_id) });
  const own = (rows ?? []).filter((row: any) => row.referrer_customer_id === card.id);
  const rewarded = own.filter((row: any) => row.status === "REWARDED");
  const total = rewarded.reduce((sum: number, row: any) => sum + Number(row.reward_amount ?? 0), 0);
  const link = `https://t.me/${username}?start=ref_${card.card_token}`;
  const share = `https://t.me/share/url?url=${encodeURIComponent(link)}&text=${encodeURIComponent(L(lang,
    "Приходи играть со мной! Открой бота клуба и получи клубную карту.",
    "Men bilan o'ynashga kel! Klub botini ochib klub kartasini ol."))}`;
  const text = L(lang,
    `🤝 <b>Пригласите друга — получите 10%</b>\n${DIVIDER}\nДруг переходит по вашей ссылке, приходит в клуб и показывает свою карту на кассе. После оплаты его первого чека вам один раз начислится 10%.\n\nПриглашено: <b>${own.length}</b> · начислено: <b>${money(total)}</b> бонусов\n\n${link}`,
    `🤝 <b>Do'stingizni taklif qiling — 10% oling</b>\n${DIVIDER}\nDo'stingiz havola orqali botga kiradi, klubga keladi va kassada kartasini ko'rsatadi. Birinchi chek to'langach sizga bir marta 10% yoziladi.\n\nTakliflar: <b>${own.length}</b> · bonus: <b>${money(total)}</b>\n\n${link}`);
  await send(token, chatId, text, {
    reply_markup: { inline_keyboard: [[{ text: L(lang, "📨 Отправить другу", "📨 Do'stga yuborish"), url: share }]] },
  });
}

async function clientStartBooking(sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number, lang: Lang) {
  // Neither check depends on the other's result -- run together and branch
  // after, instead of paying for two round trips back to back.
  const [open, { data: card }] = await Promise.all([
    isClubOpen(sb, club.club_id),
    sb.rpc("bot_player_card", { p_club_id: club.club_id, p_tg_id: tgId }),
  ]);
  if (!open) {
    return void send(
      token, chatId,
      L(lang, "🌙 Клуб сейчас закрыт — бронирование недоступно.", "🌙 Klub hozir yopiq — band qilish mavjud emas."),
      { reply_markup: clientKeyboardFor(lang, club.club_id) },
    );
  }

  if (!card?.ok) {
    await setPending(sb, club.club_id, tgId, "await_contact", { next: "book" });
    return void send(
      token,
      chatId,
      L(lang,
        "Для брони нужен ваш номер телефона — отправьте его кнопкой ниже.",
        "Band qilish uchun telefon raqamingiz kerak — quyidagi tugma orqali yuboring."),
      { reply_markup: contactKeyboardFor(lang) },
    );
  }

  const { data } = await sb.rpc("bot_resource_board", { p_club_id: club.club_id });
  const list = (data ?? []) as Array<Record<string, unknown>>;
  if (list.length === 0) {
    return void send(token, chatId, L(lang, "Мест пока нет 🙁", "Hozircha joy yo'q 🙁"), { reply_markup: clientKeyboardFor(lang) });
  }

  await send(
    token, chatId,
    L(lang,
      "🎮 <b>Какой стол забронируем?</b>\nЗанятые можно не ждать вслепую — сразу вставайте в очередь, места свободны для брони на другое время.",
      "🎮 <b>Qaysi joyni band qilamiz?</b>\nBand joyni kutib turmang — darhol navbatga turing, bo'sh joylarni esa boshqa vaqtga band qilsa bo'ladi."),
    {
      reply_markup: {
        inline_keyboard: list.map((r) => [{
          text: `${r.is_free ? "🟢" : "🔴"} ${r.name}` +
            (r.is_free
              ? ` · ${money(Number(r.price_per_hour ?? 0))} ${club.currency_suffix}/${L(lang, "ч", "soat")}`
              : ` · ${r.started_at ? elapsedLabel(String(r.started_at), lang) : L(lang, "занят", "band")}`),
          callback_data: r.is_free ? `bk:${r.id}` : `wait:${r.family}`,
        }]),
      },
    },
  );
}

async function joinWaitlist(
  sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number, family: string, lang: Lang,
) {
  const [open, { data: card }] = await Promise.all([
    isClubOpen(sb, club.club_id),
    sb.rpc("bot_player_card", { p_club_id: club.club_id, p_tg_id: tgId }),
  ]);
  if (!open) {
    return void send(
      token, chatId,
      L(lang, "🌙 Клуб сейчас закрыт — очередь недоступна.", "🌙 Klub hozir yopiq — navbat mavjud emas."),
      { reply_markup: clientKeyboardFor(lang, club.club_id) },
    );
  }

  if (!card?.ok || !card?.id) {
    return void send(
      token, chatId,
      L(lang,
        "Не нашли вашу карточку — отправьте номер телефона кнопкой ниже.",
        "Kartangiz topilmadi — quyidagi tugma orqali telefon raqamingizni yuboring."),
      { reply_markup: contactKeyboardFor(lang) },
    );
  }
  const { error } = await sb.rpc("waitlist_join", { p_club_id: club.club_id, p_customer_id: card.id, p_resource_family: family });
  if (error) {
    const already = error.message?.includes("ALREADY_WAITING");
    return void send(
      token, chatId,
      already
        ? L(lang,
            "Вы уже в очереди ⏳ — админ посадит вас, как только место освободится.",
            "Siz allaqachon navbatdasiz ⏳ — joy bo'shashi bilan sizni o'tqazishadi.")
        : `⚠️ ${error.message}`,
      { reply_markup: clientKeyboardFor(lang) },
    );
  }
  await send(
    token, chatId,
    L(lang,
      "⏳ <b>Вы в очереди!</b>\n\nКак только освободится стол — вас посадят. За каждые 10 минут ожидания копится <b>скидка 1000 сум</b>.",
      "⏳ <b>Siz navbatdasiz!</b>\n\nJoy bo'shashi bilan sizni o'tqazishadi. Har 10 daqiqa kutish uchun <b>1000 so'm chegirma</b> to'planadi."),
    { reply_markup: clientKeyboardFor(lang) },
  );
}

async function askBookingTime(
  sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number, resourceId: string, lang: Lang,
) {
  await setPending(sb, club.club_id, tgId, "book_time", { resource_id: resourceId });
  const slots = upcomingSlots(club.timezone);
  await send(token, chatId, `<b>${L(lang, "На какое время?", "Qaysi vaqtga?")}</b>`, {
    reply_markup: {
      inline_keyboard: [
        ...chunk(slots.map((s) => ({ text: s, callback_data: `bt:${s}` })), 3),
        [{ text: L(lang, "Другое время", "Boshqa vaqt"), callback_data: "bt:custom" }],
      ],
    },
  });
}

async function reservationContext(sb: SupabaseClient, clubId: string, reservationId: string) {
  const { data: r } = await sb
    .from("reservations")
    .select("id, resource_id, starts_at, customer_id, customer_name")
    .eq("id", reservationId)
    .eq("club_id", clubId)
    .maybeSingle();
  if (!r) return null;

  // Independent once we have resource_id/customer_id -- run together instead
  // of as two sequential round trips.
  const [{ data: res }, { data: cust }] = await Promise.all([
    sb.from("resources").select("name").eq("id", r.resource_id).maybeSingle(),
    r.customer_id
      ? sb.from("customers").select("telegram_id").eq("id", r.customer_id).maybeSingle()
      : Promise.resolve({ data: null as { telegram_id: number | null } | null }),
  ]);
  const customerTgId = (cust?.telegram_id as number | null) ?? null;
  return {
    id: r.id as string,
    startsAt: r.starts_at as string,
    customerName: r.customer_name as string | null,
    resourceName: (res?.name as string | undefined) ?? "Стол",
    customerTgId,
  };
}

async function finishBooking(
  sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number,
  resourceId: string, hh: number, mm: number, lang: Lang,
) {
  const today = todayInZone(club.timezone);
  let when = zonedTimeToUtc(today.y, today.mo, today.d, hh, mm, club.timezone);
  if (when.getTime() < Date.now() - 60_000) {
    const tomorrow = new Date(Date.UTC(today.y, today.mo - 1, today.d + 1));
    when = zonedTimeToUtc(tomorrow.getUTCFullYear(), tomorrow.getUTCMonth() + 1, tomorrow.getUTCDate(), hh, mm, club.timezone);
  }

  // bot_create_reservation already looks up the customer by tg_id internally
  // and falls back to their stored name/phone when these are null -- the
  // separate bot_player_card call that used to feed them in was a redundant
  // round trip fetching the same row this RPC fetches itself.
  const { data, error } = await sb.rpc("bot_create_reservation", {
    p_club_id: club.club_id,
    p_tg_id: tgId,
    p_resource_id: resourceId,
    p_starts_at: when.toISOString(),
    p_minutes: 60,
    p_name: null,
    p_phone: null,
  });
  await setPending(sb, club.club_id, tgId, null);

  if (error || !data?.ok) {
    const why = data?.reason === "BUSY"
      ? L(lang, "На это время стол уже занят. Выберите другое время.", "Bu vaqtga joy allaqachon band. Boshqa vaqtni tanlang.")
      : data?.reason === "IN_THE_PAST"
      ? L(lang, "Это время уже прошло.", "Bu vaqt allaqachon o'tib ketgan.")
      : L(lang, "Не получилось забронировать.", "Band qilib bo'lmadi.");
    await send(token, chatId, why, { reply_markup: clientKeyboardFor(lang) });
    return;
  }

  const ticketPng = await (await imaging()).renderTicket({
    clubName: club.club_name,
    tableName: String(data.resource_name ?? ""),
    dateLabel: ticketDateLabel(String(data.starts_at), club.timezone, lang),
    timeLabel: hhmm(String(data.starts_at), club.timezone),
    durationLabel: L(lang, "1 час", "1 soat"),
    lang,
  });
  await sendPhotoBytes(token, chatId, ticketPng, {
    caption: L(lang, "✅ <b>Бронирование подтверждено!</b>", "✅ <b>Band qilish tasdiqlandi!</b>"),
    reply_markup: {
      inline_keyboard: [
        [{
          text: L(lang, "✉ Написать администратору", "✉ Administratorga yozish"),
          callback_data: `radm:${data.reservation_id}`,
        }],
        [{
          text: L(lang, "❌ Отменить бронь", "❌ Bronni bekor qilish"),
          callback_data: `cancelres:${data.reservation_id}`,
        }],
      ],
    },
  });

  const { data: chats } = await sb.rpc("bot_admin_chats", { p_club_id: club.club_id });
  // Fire all admin notifications together -- they're independent Telegram
  // API calls, no reason to wait for admin N before starting admin N+1.
  await Promise.all(((chats ?? []) as number[]).map((admin) =>
    send(
      token, admin,
      `<b>Новая бронь из бота</b>\n\n${data.resource_name} · ${dayLabel(String(data.starts_at), club.timezone)}\n` +
        `${data.customer_name ?? "Гость"}${data.customer_phone ? ` · ${data.customer_phone}` : ""}`,
      {
        reply_markup: {
          inline_keyboard: [
            [{ text: "✅ Подтвердить", callback_data: `rconf:${data.reservation_id}` }],
            [{ text: "❌ Отменить", callback_data: `cancelres:${data.reservation_id}` }],
            [{ text: "✉ Написать клиенту", callback_data: `rcli:${data.reservation_id}` }],
          ],
        },
      },
    )
  ));
}

async function showMenu(
  sb: SupabaseClient, club: Club, token: string, chatId: number, role: string, lang: Lang, firstName: string,
) {
  // Fire-and-forget: this is cosmetic (updates the chat's menu button) and
  // must never delay the actual reply below it -- the process stays alive
  // regardless, so there's no need for an EdgeRuntime.waitUntil equivalent.
  void tg(token, "setChatMenuButton", {
    chat_id: chatId,
    menu_button: role === "ADMIN"
      ? { type: "web_app", text: "Админ-панель", web_app: { url: `${ADMIN_APP_URL}?c=${encodeURIComponent(club.club_id)}` } }
      : { type: "web_app", text: L(lang, "Открыть клуб", "Klubni ochish"), web_app: { url: `${MINI_APP_URL}?c=${encodeURIComponent(club.club_id)}&v=20260922-7` } },
  }).catch((error) => console.error("setChatMenuButton", error));
  if (role === "ADMIN") {
    await send(token, chatId, `⚙️ <b>${club.club_name}</b>\n${DIVIDER}\nПанель администратора — выбирай раздел 👇`, { reply_markup: adminKeyboard });
    await send(token, chatId, "🛠 Акции, фото, чат с клиентами и подтверждение броней — в отдельной админ-панели.", {
      reply_markup: { inline_keyboard: [[{ text: "🛠 Открыть админ-панель", web_app: { url: `${ADMIN_APP_URL}?c=${encodeURIComponent(club.club_id)}` } }]] },
    });
    return;
  }

  const text = L(lang,
    `✨ <b>${club.club_name}</b>\n${DIVIDER}\n` +
      `👋 Привет, ${firstName}!\n\n` +
      `🎮  Смотреть свободные столы\n` +
      `📅  Забронировать стол\n` +
      `🎁  Проверить бонусы\n` +
      `👤  Открыть свою карточку\n\n` +
      `Выбирай на клавиатуре ниже 👇`,
    `✨ <b>${club.club_name}</b>\n${DIVIDER}\n` +
      `👋 Salom, ${firstName}!\n\n` +
      `🎮  Bo'sh joylarni ko'rish\n` +
      `📅  Joy band qilish\n` +
      `🎁  Bonuslarni tekshirish\n` +
      `👤  Kartangizni ochish\n\n` +
      `Quyidagi tugmalardan birini tanlang 👇`);
  const keyboard = clientKeyboardFor(lang, club.club_id);
  await send(token, chatId, text, { reply_markup: keyboard });
}

async function handleText(
  sb: SupabaseClient, club: Club, token: string, chatId: number, tgId: number, role: string, text: string,
  lang: Lang, firstName: string,
) {
  if (text.startsWith("/start") || text === "/menu") {
    // Clearing pending state doesn't affect the menu reply -- run it
    // alongside instead of making the user wait an extra round trip.
    const cleared = setPending(sb, club.club_id, tgId, null);
    const referral = text.match(/^\/start(?:@\w+)?\s+ref_([0-9a-f-]{36})$/i);
    if (referral && role !== "ADMIN") {
      const { data: claimed } = await sb.rpc("bot_claim_referral", {
        p_club_id: club.club_id,
        p_tg_id: tgId,
        p_referrer_card: referral[1],
      });
      if (claimed?.ok) {
        await send(token, chatId, L(lang,
          "✅ Приглашение принято. Создайте клубную карту и покажите её на кассе после игры.",
          "✅ Taklif qabul qilindi. Klub kartasini yarating va o'yindan so'ng kassada ko'rsating."));
      }
    }
    await Promise.all([cleared, showMenu(sb, club, token, chatId, role, lang, firstName)]);
    return;
  }

  if (role === "ADMIN") {
    switch (text) {
      case ADMIN.hall: return void adminHall(sb, club, token, chatId);
      case ADMIN.bookings: return void adminBookings(sb, club, token, chatId);
      case ADMIN.top: return void adminTop(sb, club, token, chatId);
      case ADMIN.stats: return void adminStats(sb, club, token, chatId);
    }
  }

  const clientAction = clientActionFor(text);
  if (clientAction) {
    switch (clientAction) {
      case "tables": return void clientTables(sb, club, token, chatId, lang);
      case "bonus": return void clientBonus(sb, club, token, chatId, tgId, lang);
      case "book": return void clientStartBooking(sb, club, token, chatId, tgId, lang);
      case "invite": return void clientReferral(sb, club, token, chatId, tgId, lang);
      case "lang": return void showLangPicker(token, chatId, lang);
      case "me": {
        const { data } = await sb.rpc("bot_player_card", { p_club_id: club.club_id, p_tg_id: tgId });
        if (!data?.ok) {
          return void send(
            token, chatId,
            L(lang, "Отправьте номер, чтобы завести карточку.", "Karta ochish uchun raqamingizni yuboring."),
            { reply_markup: contactKeyboardFor(lang) },
          );
        }
        const caption =
          `👤 <b>${data.name}</b>\n${DIVIDER}\n` +
          `📞 ${L(lang, "Телефон", "Telefon")}: ${data.phone ?? "—"}\n` +
          `🏅 ${L(lang, "Статус", "Holat")}: <b>${data.tier}</b>\n` +
          `📅 ${L(lang, "Визитов", "Tashriflar")}: ${data.visits ?? 0}`;
        if (data.id) {
          const png = await (await imaging()).renderPlayerCard({
            clubName: club.club_name,
            customerName: String(data.name ?? ""),
            levelLabel: String(data.tier ?? ""),
            balance: Number(data.bonus_points ?? 0),
            discountPct: Number(data.discount_percent ?? 0) > 0 ? Number(data.discount_percent) : null,
            qrValue: `CARD:${data.card_token}`,
            lang,
          });
          await sendPhotoBytes(token, chatId, png, { caption, reply_markup: clientKeyboardFor(lang) });
          return;
        }
        await send(token, chatId, caption, { reply_markup: clientKeyboardFor(lang) });
        return;
      }
    }
  }

  const pending = await getPending(sb, club.club_id, tgId);

  if (pending?.action === "rate_comment") {
    await setPending(sb, club.club_id, tgId, null);
    await sb.rpc("bot_rate_comment", {
      p_club_id: club.club_id, p_tg_id: tgId, p_order_id: String(pending.payload?.order_id ?? ""), p_comment: text,
    });
    await send(token, chatId, L(lang, "Спасибо! Передали владельцу клуба 🙏", "Rahmat! Klub egasiga yetkazdik 🙏"), {
      reply_markup: clientKeyboardFor(lang, club.club_id),
    });
    return;
  }

  if (pending?.action === "book_time") {
    const m = text.match(/^(\d{1,2})[:. ](\d{2})$/);
    if (!m) {
      return void send(token, chatId, L(lang, "Напишите время в формате 18:30", "Vaqtni 18:30 formatida yozing"), {
        reply_markup: clientKeyboardFor(lang),
      });
    }
    await finishBooking(sb, club, token, chatId, tgId, pending.payload.resource_id, Number(m[1]), Number(m[2]), lang);
    return;
  }

  if (pending?.action === "relay_admin") {
    const ctx = await reservationContext(sb, club.club_id, pending.payload.reservation_id);
    await setPending(sb, club.club_id, tgId, null);
    if (!ctx) {
      await send(token, chatId, L(lang, "Эта бронь не найдена.", "Bu bron topilmadi."), { reply_markup: clientKeyboardFor(lang) });
      return;
    }
    const { data: chats } = await sb.rpc("bot_admin_chats", { p_club_id: club.club_id });
    await Promise.all(((chats ?? []) as number[]).map((admin) =>
      send(
        token, admin,
        `<b>Сообщение от клиента</b>\n${ctx.customerName ?? "Гость"} · ${ctx.resourceName} · ${dayLabel(ctx.startsAt, club.timezone)}\n\n${text}`,
        { reply_markup: { inline_keyboard: [[{ text: "✉ Ответить", callback_data: `rcli:${ctx.id}` }]] } },
      )
    ));
    await send(token, chatId, L(lang, "Отправлено администратору.", "Administratorga yuborildi."), { reply_markup: clientKeyboardFor(lang) });
    return;
  }

  if (pending?.action === "relay_client") {
    const ctx = await reservationContext(sb, club.club_id, pending.payload.reservation_id);
    await setPending(sb, club.club_id, tgId, null);
    if (!ctx?.customerTgId) {
      await send(token, chatId, "У клиента нет чата с этим ботом.", { reply_markup: adminKeyboard });
      return;
    }
    await send(
      token, ctx.customerTgId,
      `<b>Сообщение от клуба</b>\n${ctx.resourceName} · ${dayLabel(ctx.startsAt, club.timezone)}\n\n${text}`,
        { reply_markup: { inline_keyboard: [[{ text: "✉ Ответить", callback_data: `radm:${ctx.id}` }]] } },
      );
      await send(token, chatId, "Отправлено клиенту.", { reply_markup: adminKeyboard });
      return;
    }

  if (pending?.action === "chat_reply") {
    await setPending(sb, club.club_id, tgId, null);
    const customerId = String(pending.payload?.customer_id ?? "");
    const { data: customer } = await sb.from("customers").select("telegram_id, full_name")
      .eq("id", customerId).eq("club_id", club.club_id).maybeSingle();
    if (!customer) {
      await send(token, chatId, "Клиент не найден.", { reply_markup: adminKeyboard });
      return;
    }
    const { error } = await sb.from("customer_chat_messages").insert({
      club_id: club.club_id, customer_id: customerId, sender_type: "ADMIN",
      sender_telegram_id: tgId, body: text,
    });
    if (error) {
      await send(token, chatId, `Не удалось отправить: ${error.message}`, { reply_markup: adminKeyboard });
      return;
    }
    if (customer.telegram_id) {
      await send(token, Number(customer.telegram_id), `💬 <b>Ответ клуба</b>\n\n${text}`);
    }
    await send(
      token, chatId,
      `Отправлено${customer.full_name ? ` — ${customer.full_name}` : ""}.`,
      { reply_markup: adminKeyboard },
    );
    return;
  }

  if (/^[A-Z0-9]{8}$/i.test(text)) {
    const { data: ok } = await sb.rpc("bot_redeem_staff_invite", {
      p_club_id: club.club_id,
      p_tg_id: tgId,
      p_chat_id: chatId,
      p_code: text,
    });
    if (ok === true) {
      userCache.delete(userKey(club.club_id, tgId));
      return void send(token, chatId, "✅ Доступ администратора открыт.", { reply_markup: adminKeyboard });
    }
  }

  await showMenu(sb, club, token, chatId, role, lang, firstName);
}

// --- HTTP wiring -------------------------------------------------------------
// Replaces Deno.serve: a persistent Express server instead of a per-request
// serverless invocation. Route shape mirrors the old Edge Function URL
// (/club-bot?s=<secret>) so existing per-club webhook_secret values and the
// Windows app's webhook-registration code don't need to change -- only the
// base URL Telegram's setWebhook points at changes on cutover.

const app = express();
app.use(express.json({ limit: "2mb" }));
// A malformed body must fall back to "bad request", same as the old
// req.json().catch(...) -- without this handler express.json's parse
// failure would reach Express's default error page instead.
app.use((err: any, _req: express.Request, res: express.Response, next: express.NextFunction) => {
  if (err?.type === "entity.parse.failed") return res.status(400).send("bad request");
  next(err);
});

app.use((req, res, next) => {
  if (req.method !== "POST") return next();
  const started = Date.now();
  res.on("finish", () => console.log(`[timing] ${req.path} ${Date.now() - started}ms`));
  next();
});

app.get("/club-bot", (_req, res) => res.send("ok"));
app.get("/", (_req, res) => res.send("ok"));

app.post("/club-bot", async (req, res) => {
  const secret = String(req.query.s ?? "");
  if (!secret) return res.status(403).send("forbidden");

  const club = await clubBySecret(sb, secret);
  if (!club?.ok) return res.status(403).send("forbidden");
  const c = club as Club;
  const token = c.bot_token;
  const update: Record<string, any> = req.body ?? {};

  try {
    const msg = update.message ?? update.edited_message;
    const cb = update.callback_query;
    const tgId: number | undefined = msg?.from?.id ?? cb?.from?.id;
    const chatId: number | undefined = msg?.chat?.id ?? cb?.message?.chat?.id;
    if (!tgId || !chatId) return res.send("ok");

    const name = [msg?.from?.first_name, msg?.from?.last_name].filter(Boolean).join(" ");
    // Stops the button's loading spinner right away instead of after the
    // DB work below.
    if (cb) void tg(token, "answerCallbackQuery", { callback_query_id: cb.id }).catch(() => undefined);

    const cacheKey = userKey(c.club_id, tgId);
    let ctx = userCache.get(cacheKey);
    if (!ctx || ctx.expiresAt <= Date.now()) {
      const [lang, roleRpc, termsRow] = await Promise.all([
        getLang(sb, tgId),
        sb.rpc("bot_role_for", {
          p_club_id: c.club_id,
          p_tg_id: tgId,
          p_chat_id: chatId,
          p_name: name || null,
          p_username: msg?.from?.username ?? null,
        }),
        sb.from("club_bot_users").select("terms_accepted_at")
          .eq("club_id", c.club_id).eq("telegram_id", tgId).maybeSingle(),
      ]);
      ctx = {
        lang,
        role: String(roleRpc.data ?? "CLIENT"),
        termsAccepted: Boolean((termsRow as any)?.data?.terms_accepted_at),
        expiresAt: Date.now() + USER_TTL,
      };
      // Not-yet-accepted clients are never cached: they may accept in the
      // Mini App, and the bot must notice that on their very next tap.
      if (ctx.role !== "CLIENT" || ctx.termsAccepted) userCache.set(cacheKey, ctx);
      else userCache.delete(cacheKey);
    }
    const lang = ctx.lang;
    const firstName = (msg?.from?.first_name ?? cb?.from?.first_name ?? "").trim() || L(lang, "друг", "do'stim");
    const userRole = ctx.role;

    // Mandatory for clients (the consumer-facing side); staff opening their
    // own admin bot never see a customer terms prompt.
    if (userRole === "CLIENT") {
      const cbData = cb ? String(cb.data ?? "") : "";
      if (!ctx.termsAccepted) {
        if (cbData === "terms:accept") {
          await sb.from("club_bot_users").update({ terms_accepted_at: new Date().toISOString() })
            .eq("club_id", c.club_id).eq("telegram_id", tgId);
          userCache.set(cacheKey, { ...ctx, termsAccepted: true, expiresAt: Date.now() + USER_TTL });
          if (cb?.message?.message_id) {
            void tg(token, "deleteMessage", { chat_id: chatId, message_id: cb.message.message_id });
          }
          await showMenu(sb, c, token, chatId, userRole, lang, firstName);
          return res.send("ok");
        }
        await sendTermsPrompt(token, chatId, lang, cbData === "terms:decline");
        return res.send("ok");
      }
    }

    if (msg?.contact) {
      await sb.rpc("bot_link_player", {
        p_club_id: c.club_id,
        p_tg_id: tgId,
        p_name: [msg.contact.first_name, msg.contact.last_name].filter(Boolean).join(" ") || name,
        p_phone: msg.contact.phone_number,
        p_username: msg?.from?.username ?? null,
      });
      const pending = await getPending(sb, c.club_id, tgId);
      await setPending(sb, c.club_id, tgId, null);
      await send(
        token, chatId,
        L(lang,
          "✅ Спасибо! Карточка создана — бонусы копятся с каждого визита.",
          "✅ Rahmat! Karta ochildi — har tashrifda bonus to'planadi."),
        { reply_markup: menuFor(userRole, lang) },
      );
      if (pending?.payload?.next === "book") {
        await clientStartBooking(sb, c, token, chatId, tgId, lang);
      }
      return res.send("ok");
    }

    if (cb) {
      const data = String(cb.data ?? "");

      if (data === "noop") return res.send("ok");

      if (data.startsWith("rate:")) {
        const [, orderId, value] = data.split(":");
        const rating = Number(value);
        const { data: rated } = await sb.rpc("bot_rate_order", {
          p_club_id: c.club_id, p_tg_id: tgId, p_order_id: orderId, p_rating: rating,
        });
        if (!rated?.ok) return res.send("ok");
        if (cb.message?.message_id) {
          void tg(token, "editMessageReplyMarkup", {
            chat_id: chatId,
            message_id: cb.message.message_id,
            reply_markup: { inline_keyboard: [[{ text: "⭐".repeat(rating), callback_data: "noop" }]] },
          }).catch(() => undefined);
        }
        if (rating <= 3) {
          await setPending(sb, c.club_id, tgId, "rate_comment", { order_id: orderId });
          await send(token, chatId, L(lang,
            "Спасибо за оценку. Что нам улучшить? Напишите одним сообщением — владелец клуба прочитает лично.",
            "Baho uchun rahmat. Nimani yaxshilashimiz kerak? Bitta xabar bilan yozing — klub egasi shaxsan o'qiydi."));
        } else {
          await send(token, chatId, L(lang, "Спасибо за оценку! Ждём вас снова 🎱", "Baho uchun rahmat! Sizni yana kutamiz 🎱"));
        }
        return res.send("ok");
      }

      if (data === "wb:tables") {
        await clientTables(sb, c, token, chatId, lang);
        return res.send("ok");
      }
      if (data === "wb:book") {
        await clientStartBooking(sb, c, token, chatId, tgId, lang);
        return res.send("ok");
      }

      if (data === "setlang:ru" || data === "setlang:uz") {
        const newLang = data.slice(8) as Lang;
        await setLang(sb, tgId, newLang);
        patchUserCache(c.club_id, tgId, { lang: newLang });
        await showMenu(sb, c, token, chatId, userRole, newLang, firstName);
        return res.send("ok");
      }

      if (data.startsWith("bk:")) {
        await askBookingTime(sb, c, token, chatId, tgId, data.slice(3), lang);
        return res.send("ok");
      }
      if (data.startsWith("wait:")) {
        await joinWaitlist(sb, c, token, chatId, tgId, data.slice(5), lang);
        return res.send("ok");
      }
      if (data.startsWith("bt:")) {
        const val = data.slice(3);
        if (val === "custom") {
          await send(token, chatId, L(lang, "Напишите время в формате 18:30", "Vaqtni 18:30 formatida yozing"));
          return res.send("ok");
        }
        const [hh, mm] = val.split(":").map(Number);
        const pending = await getPending(sb, c.club_id, tgId);
        const resourceId = (pending?.payload as Record<string, string>)?.resource_id;
        if (!resourceId) {
          await send(token, chatId, L(lang, "Начните заново — выберите стол.", "Qaytadan boshlang — joyni tanlang."), {
            reply_markup: clientKeyboardFor(lang),
          });
          return res.send("ok");
        }
        await finishBooking(sb, c, token, chatId, tgId, resourceId, hh, mm, lang);
        return res.send("ok");
      }

      if (userRole === "ADMIN" && data.startsWith("bpick:")) {
        await adminBookingDetail(sb, c, token, chatId, data.slice(6));
        return res.send("ok");
      }

      if (userRole === "ADMIN" && data.startsWith("rep:")) {
        const action = data.slice(4);
        const t = todayInZone(c.timezone);
        // "today"/"yesterday" are the pre-shift buttons still sitting in old chats.
        if (action === "cur" || action === "today") await showCurrentShiftReport(sb, c, token, chatId);
        else if (action === "prev" || action === "yesterday") await showPreviousShiftReport(sb, c, token, chatId);
        else if (action === "list") await showShiftList(sb, c, token, chatId);
        else if (action === "cal") {
          await send(token, chatId, "Выберите день:", { reply_markup: buildCalendar(t.y, t.mo) });
        } else if (action === "topprod") await showTopProducts(sb, c, token, chatId);
        else if (action === "menu") await showReportMenu(token, chatId);
        return res.send("ok");
      }
      if (userRole === "ADMIN" && data.startsWith("calnav:")) {
        const [y, mo] = data.slice(7).split("-").map(Number);
        await send(token, chatId, "Выберите день:", { reply_markup: buildCalendar(y, mo) });
        return res.send("ok");
      }
      if (userRole === "ADMIN" && data.startsWith("calday:")) {
        const [y, mo, d] = data.slice(7).split("-").map(Number);
        await showShiftsForDay(sb, c, token, chatId, y, mo, d);
        return res.send("ok");
      }
      if (userRole === "ADMIN" && (data.startsWith("shift:") || data.startsWith("shxls:"))) {
        const shift = await shiftById(sb, c.club_id, data.slice(6));
        if (!shift) {
          await send(token, chatId, "Смена не найдена.", { reply_markup: adminKeyboard });
        } else if (data.startsWith("shift:")) {
          await showShiftReport(sb, c, token, chatId, shift);
        } else {
          await sendShiftReportExcel(sb, c, token, chatId, shift);
        }
        return res.send("ok");
      }
      if (userRole === "ADMIN" && data.startsWith("repxls:")) {
        const [y, mo, d] = data.slice(7).split("-").map(Number);
        await sendDayReportExcel(sb, c, token, chatId, y, mo, d);
        return res.send("ok");
      }

      if (userRole === "ADMIN" && data.startsWith("rconf:")) {
        const id = data.slice(6);
        const ctx = await reservationContext(sb, c.club_id, id);
        if (!ctx) {
          await send(token, chatId, "Эта бронь не найдена.", { reply_markup: adminKeyboard });
          return res.send("ok");
        }
        await sb.from("reservations").update({ status: "confirmed" }).eq("id", id).eq("club_id", c.club_id);
        await send(
          token, chatId,
          `✅ Подтверждено: ${ctx.resourceName} · ${dayLabel(ctx.startsAt, c.timezone)}`,
          { reply_markup: adminKeyboard },
        );
        if (ctx.customerTgId) {
          await send(
            token, ctx.customerTgId,
            `<b>Бронь подтверждена</b>\n\n${ctx.resourceName} · ${dayLabel(ctx.startsAt, c.timezone)}\n\nЖдём вас!`,
          );
        }
        return res.send("ok");
      }
      if (data.startsWith("radm:")) {
        const ctx = await reservationContext(sb, c.club_id, data.slice(5));
        if (!ctx) {
          await send(token, chatId, L(lang, "Эта бронь не найдена.", "Bu bron topilmadi."), { reply_markup: clientKeyboardFor(lang) });
          return res.send("ok");
        }
        await setPending(sb, c.club_id, tgId, "relay_admin", { reservation_id: ctx.id });
        await send(token, chatId, L(lang, "Напишите сообщение — отправим администратору клуба.", "Xabar yozing — klub administratoriga yuboramiz."));
        return res.send("ok");
      }
      if (data.startsWith("cancelres:")) {
        const id = data.slice(10);
        const { data: r } = await sb
          .from("reservations")
          .select("id, resource_id, customer_id, customer_name, starts_at, status")
          .eq("id", id)
          .eq("club_id", c.club_id)
          .maybeSingle();
        if (!r) {
          await send(token, chatId, L(lang, "Эта бронь не найдена.", "Bu bron topilmadi."), { reply_markup: clientKeyboardFor(lang) });
          return res.send("ok");
        }
        let ownsIt = userRole === "ADMIN";
        if (!ownsIt && r.customer_id) {
          const { data: cust } = await sb.from("customers").select("telegram_id").eq("id", r.customer_id).maybeSingle();
          ownsIt = Number(cust?.telegram_id) === tgId;
        }
        if (!ownsIt) {
          await send(token, chatId, L(lang, "Это не ваша бронь.", "Bu sizning bronangiz emas."), { reply_markup: clientKeyboardFor(lang) });
          return res.send("ok");
        }
        if (r.status === "cancelled") {
          await send(token, chatId, L(lang, "Бронь уже отменена.", "Bron allaqachon bekor qilingan."), { reply_markup: clientKeyboardFor(lang) });
          return res.send("ok");
        }
        // Cancelling, telling the client, looking up the table name and the
        // admin chat list are all independent of each other -- run together.
        const [, , { data: resRow }, { data: chats }] = await Promise.all([
          sb.from("reservations").update({ status: "cancelled" }).eq("id", id),
          send(token, chatId, L(lang, "❌ Бронь отменена.", "❌ Bron bekor qilindi."), { reply_markup: clientKeyboardFor(lang) }),
          sb.from("resources").select("name").eq("id", r.resource_id).maybeSingle(),
          sb.rpc("bot_admin_chats", { p_club_id: c.club_id }),
        ]);
        await Promise.all(((chats ?? []) as number[]).map((admin) =>
          send(
            token, admin,
            `❌ <b>Клиент отменил бронь</b>\n${resRow?.name ?? "Стол"} · ${dayLabel(String(r.starts_at), c.timezone)}\n${r.customer_name ?? "Гость"}`,
          )
        ));
        return res.send("ok");
      }

      if (userRole === "ADMIN" && data.startsWith("chatreply:")) {
        const customerId = data.slice(10);
        await setPending(sb, c.club_id, tgId, "chat_reply", { customer_id: customerId });
        await send(token, chatId, "Напишите ответ клиенту.", { reply_markup: adminKeyboard });
        return res.send("ok");
      }

      if (userRole === "ADMIN" && data.startsWith("rcli:")) {
        const ctx = await reservationContext(sb, c.club_id, data.slice(5));
        if (!ctx) {
          await send(token, chatId, "Эта бронь не найдена.", { reply_markup: adminKeyboard });
          return res.send("ok");
        }
        if (!ctx.customerTgId) {
          await send(token, chatId, "У клиента нет чата с этим ботом.", { reply_markup: adminKeyboard });
          return res.send("ok");
        }
        await setPending(sb, c.club_id, tgId, "relay_client", { reservation_id: ctx.id });
        await send(token, chatId, "Напишите сообщение — отправим клиенту.", { reply_markup: adminKeyboard });
        return res.send("ok");
      }

      return res.send("ok");
    }

    const text = String(msg?.text ?? "").trim();
    if (text) await handleText(sb, c, token, chatId, tgId, userRole, text, lang, firstName);
  } catch (e) {
    console.error(e);
  }

  return res.send("ok");
});

const PORT = Number(process.env.PORT ?? 8787);
app.listen(PORT, () => {
  console.log(`club-bot-service слушает порт ${PORT}`);
});
