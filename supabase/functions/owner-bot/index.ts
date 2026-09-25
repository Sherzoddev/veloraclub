// The owner's own Telegram bot — full reports, stock and finance, kept
// entirely separate from the cashier+client bot (club-bot) so a cashier
// logging into that one never sees numbers meant for the owner.
//
// Provisioned by the vendor, not self-service: the owner creates a bot via
// BotFather and sends the token over; the vendor bot (telegram-bot) pastes it
// in and registers the webhook here automatically (`owner_bot_register`).
// The first person to /start this bot becomes its owner; anyone else needs
// an invite code the owner generates from the "Доступ" menu.
//
// The webhook URL carries forceFunctionRegion=ap-southeast-2 so this runs
// next to the database (Sydney) instead of next to Telegram (Frankfurt):
// every report is several DB round trips but only one or two Telegram calls.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = (): SupabaseClient =>
  createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// Reused across requests while the isolate stays warm, together with its
// open connections.
const sharedDb = db();
const cfgCache = new Map<string, { value: OwnerBotConfig; expiresAt: number }>();
// Only confirmed OWNER/VIEWER roles are cached — someone without access must
// be re-checked on every message so a freshly redeemed invite works at once.
const roleCache = new Map<string, { role: string; expiresAt: number }>();
const waitUntil = (p: Promise<unknown>) => {
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p);
};

type OwnerBotConfig = {
  owner_bot_id: string;
  club_id: string;
  club_name: string;
  bot_token: string;
  owner_chat_id: number | null;
  timezone: string;
  currency_suffix: string;
  has_playstation: boolean;
  has_billiard: boolean;
};

const money = (n: number) => new Intl.NumberFormat("ru-RU").format(Math.round(n));
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const DIVIDER = "┊┊┊┊┊┊┊┊┊┊┊┊";
const medal = (i: number) => (i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : `${i + 1}.`);

function todayInZone(timeZone: string): { y: number; mo: number; d: number } {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date());
  const map = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  return { y: +map.year, mo: +map.month, d: +map.day };
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

// Reports cover a working day: 07:00 → 07:00 the next morning, in the club's
// zone, whatever shifts were opened or closed in between. Shifts here open at
// any hour (and sometimes twice for a few seconds), so "the shift opened that
// day" split a night in odd places; a fixed 07:00 cut never does.
const DAY_START_HOUR = 7;

function workDayBounds(y: number, mo: number, d: number, timeZone: string): { from: string; to: string } {
  const from = zonedTimeToUtc(y, mo, d, DAY_START_HOUR, 0, timeZone);
  const next = new Date(Date.UTC(y, mo - 1, d + 1));
  const to = zonedTimeToUtc(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), DAY_START_HOUR, 0, timeZone);
  return { from: from.toISOString(), to: to.toISOString() };
}

/// The working day "now" belongs to: before 07:00 that's still yesterday's.
function currentWorkDay(timeZone: string): { y: number; mo: number; d: number } {
  const t = todayInZone(timeZone);
  const hour = Number(new Intl.DateTimeFormat("en-US", { timeZone, hour: "2-digit", hourCycle: "h23" }).format(new Date()));
  if (hour >= DAY_START_HOUR) return t;
  const prev = new Date(Date.UTC(t.y, t.mo - 1, t.d - 1));
  return { y: prev.getUTCFullYear(), mo: prev.getUTCMonth() + 1, d: prev.getUTCDate() };
}

const pad = (n: number) => String(n).padStart(2, "0");
const isoDate = (y: number, mo: number, d: number) => `${y}-${pad(mo)}-${pad(d)}`;
const fmtDateRu = (y: number, mo: number, d: number) => `${pad(d)}.${pad(mo)}.${y}`;

function fmtDateTimeRu(iso: string, timeZone: string) {
  return new Intl.DateTimeFormat("ru-RU", {
    timeZone, day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).format(new Date(iso));
}

const MONTH_NAMES = [
  "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
  "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
];

/// `dayPrefix` is what tells the three calendar uses in this bot apart (a
/// single day for the day report, "from", then "to" for a custom range) —
/// the month-nav arrows re-render the same mode by checking pending state,
/// not by carrying it in their own callback data.
/// Days after `last` (the newest day that can have a report) are left blank,
/// and so is the "next month" arrow once that month is still ahead.
function buildCalendar(y: number, mo: number, dayPrefix = "calday:", last?: { y: number; mo: number; d: number }) {
  const daysInMonth = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  const firstWeekday = (new Date(Date.UTC(y, mo - 1, 1)).getUTCDay() + 6) % 7;
  const blank = { text: " ", callback_data: "noop" };

  const rows: Array<Array<{ text: string; callback_data: string }>> = [
    [{ text: `${MONTH_NAMES[mo - 1]} ${y}`, callback_data: "noop" }],
    ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"].map((d) => ({ text: d, callback_data: "noop" })),
  ];
  let week = new Array(firstWeekday).fill(blank);
  for (let d = 1; d <= daysInMonth; d++) {
    const future = last && isoDate(y, mo, d) > isoDate(last.y, last.mo, last.d);
    week.push(future ? blank : { text: String(d), callback_data: `${dayPrefix}${isoDate(y, mo, d)}` });
    if (week.length === 7) {
      rows.push(week);
      week = [];
    }
  }
  if (week.length) rows.push([...week, ...new Array(7 - week.length).fill(blank)]);

  const prev = mo === 1 ? { y: y - 1, mo: 12 } : { y, mo: mo - 1 };
  const next = mo === 12 ? { y: y + 1, mo: 1 } : { y, mo: mo + 1 };
  const nextIsFuture = last && isoDate(next.y, next.mo, 1) > isoDate(last.y, last.mo, last.d);
  rows.push([
    { text: "◂", callback_data: `calnav:${prev.y}-${pad(prev.mo)}` },
    { text: "Назад", callback_data: "menu" },
    nextIsFuture ? blank : { text: "▸", callback_data: `calnav:${next.y}-${pad(next.mo)}` },
  ]);
  return { inline_keyboard: rows };
}

const MENU = {
  today: "📊 Сегодня",
  period: "🗓 Отчёт за день",
  chart: "📈 График",
  top: "🏆 Топ товаров",
  stock: "📦 Остатки",
  staff: "➕ Сотрудники",
  ratings: "⭐ Оценки",
  photo: "🖼 Фото приветствия",
} as const;

const mainKeyboard = {
  keyboard: [
    [{ text: MENU.today }, { text: MENU.period }],
    [{ text: MENU.chart }, { text: MENU.top }],
    [{ text: MENU.stock }, { text: MENU.staff }],
    [{ text: MENU.ratings }, { text: MENU.photo }],
  ],
  resize_keyboard: true,
  is_persistent: true,
};

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

// Namespaced by owner_bot_id so this never collides with the same person's
// pending state in the cashier+client bot (club-bot) — both share `bot_state`.
async function setPending(sb: SupabaseClient, ownerBotId: string, tgId: number, action: string | null, payload: unknown = {}) {
  await sb.from("bot_state").upsert({
    telegram_id: tgId,
    pending_action: action === null ? null : `ownerbot:${ownerBotId}:${action}`,
    payload: payload ?? {},
    updated_at: new Date().toISOString(),
  });
}

async function getPending(sb: SupabaseClient, ownerBotId: string, tgId: number) {
  const { data } = await sb.from("bot_state").select("pending_action, payload").eq("telegram_id", tgId).maybeSingle();
  if (!data?.pending_action) return null;
  const prefix = `ownerbot:${ownerBotId}:`;
  if (!String(data.pending_action).startsWith(prefix)) return null;
  return { action: String(data.pending_action).slice(prefix.length), payload: (data.payload ?? {}) as Record<string, any> };
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

/// A smooth filled line via QuickChart's URL API — no charting library
/// needed, same "hand a URL to sendPhoto" trick as the QR codes elsewhere in
/// this app. A bar-per-day read as noisy once there were more than a
/// handful; a trend line is what actually answers "is this going up".
async function sendChart(
  token: string, chatId: number, labels: string[], values: number[], title: string, caption: string,
) {
  const config = {
    type: "line",
    data: {
      labels,
      datasets: [{
        label: title,
        data: values,
        fill: true,
        backgroundColor: "rgba(16, 185, 129, 0.15)",
        borderColor: "#10B981",
        borderWidth: 3,
        pointRadius: labels.length > 14 ? 0 : 4,
        pointBackgroundColor: "#10B981",
        tension: 0.35,
      }],
    },
    options: {
      plugins: {
        legend: { display: false },
        title: { display: true, text: title, font: { size: 16, weight: "bold" } },
      },
      scales: {
        y: { beginAtZero: true, grid: { color: "#e5e7eb" } },
        x: { grid: { display: false } },
      },
    },
  };
  const url = `https://quickchart.io/chart?width=700&height=380&backgroundColor=white&c=${encodeURIComponent(JSON.stringify(config))}`;
  await tg(token, "sendPhoto", { chat_id: chatId, photo: url, caption });
}

const csvCell = (v: unknown) => {
  const s = String(v ?? "");
  return /[";\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const csvRows = (rows: unknown[][]) => rows.map((r) => r.map(csvCell).join(";")).join("\r\n");

function reportBody(data: any, cfg: OwnerBotConfig) {
  const cur = cfg.currency_suffix;
  const byMethod = Object.entries((data?.by_payment_method ?? {}) as Record<string, number>)
    .map(([name, amount]) => `${name} — ${money(amount)} ${cur}`)
    .join("\n");

  // time_playstation / time_billiard are already net of time-only discounts
  // (e.g. the 50% "cashier plays with a client" discount) — the bar lines
  // below are never touched by those.
  const timeDiscount = Number(data?.time_discount ?? 0);
  const familyLines =
    (timeDiscount > 0 ? "⏱ <b>Время (после скидок)</b>\n" : "") +
    (cfg.has_playstation ? `PlayStation: ${money(Number(data?.time_playstation ?? 0))} ${cur}\n` : "") +
    (cfg.has_billiard ? `Бильярд: ${money(Number(data?.time_billiard ?? 0))} ${cur}\n` : "");

  const discountByReason = Object.entries((data?.discount_by_reason ?? {}) as Record<string, number>)
    .map(([reason, amount]) => `  · ${reason} — ${money(amount)} ${cur}`)
    .join("\n");

  return (
    `Выручка: <b>${money(Number(data?.revenue ?? 0))} ${cur}</b> · ${data?.orders_count ?? 0} чеков\n\n` +
    familyLines +
    (timeDiscount > 0 ? "\n🍹 <b>Бар (без скидок на время)</b>\n" : "") +
    `Товары: ${money(Number(data?.products ?? 0))} ${cur}\n` +
    `Прибыль бара: <b>${money(Number(data?.bar_profit ?? 0))} ${cur}</b>\n` +
    (byMethod ? `\n${byMethod}\n` : "\n") +
    `\nРасходы: ${money(Number(data?.expenses ?? 0))} ${cur}\n` +
    (Number(data?.discount_total ?? 0) > 0
      ? `Скидки: ${money(Number(data.discount_total))} ${cur}\n${discountByReason}\n` +
        (timeDiscount > 0 ? `  из них на время: ${money(timeDiscount)} ${cur}\n` : "")
      : "") +
    `\nЧистая прибыль: <b>${money(Number(data?.net_profit ?? 0))} ${cur}</b>`
  );
}

function reportExcelRows(report: any, top: any[], cfg: OwnerBotConfig): unknown[][] {
  return [
    ["Выручка", report?.revenue ?? 0],
    ["Чеков", report?.orders_count ?? 0],
    ...(cfg.has_playstation ? [["PlayStation (после скидок)", report?.time_playstation ?? 0]] : []),
    ...(cfg.has_billiard ? [["Бильярд (после скидок)", report?.time_billiard ?? 0]] : []),
    ["Время до скидок", Number(report?.time_playstation_gross ?? 0) + Number(report?.time_billiard_gross ?? 0)],
    ["Скидки на время", report?.time_discount ?? 0],
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
    ...((top ?? []) as Array<Record<string, unknown>>).map((p) => [p.product_name, p.category_name ?? "", p.quantity, p.revenue]),
  ];
}

const dayCalendar = (y: number, mo: number, timeZone: string) =>
  buildCalendar(y, mo, "calday:", currentWorkDay(timeZone));

async function sendDayPicker(cfg: OwnerBotConfig, chatId: number, y: number, mo: number) {
  await send(cfg.bot_token, chatId, "🗓 Выберите день:", {
    reply_markup: dayCalendar(y, mo, cfg.timezone),
  });
}

// Shifts that ran during a working day: opened before it ended and not
// closed before it began. Test open/close clicks under a minute are skipped.
async function shiftsInDay(sb: SupabaseClient, clubId: string, from: string, to: string): Promise<ShiftRow[]> {
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT)
    .eq("club_id", clubId).lt("opened_at", to).or(`closed_at.is.null,closed_at.gt."${from}"`)
    .order("opened_at", { ascending: true });
  const shifts = ((data ?? []) as unknown as ShiftRow[]).filter((s) =>
    !s.closed_at || new Date(s.closed_at).getTime() - new Date(s.opened_at).getTime() >= 60_000);
  // A closed shift has its expected cash saved; an open one is counted now.
  await Promise.all(shifts.filter((s) => !s.closed_at).map(async (s) => {
    const { data: cash } = await sb.rpc("bot_shift_expected_cash", { p_shift_id: s.id });
    if (cash != null) s.expected_cash = Number(cash);
  }));
  return shifts;
}

const signedMoney = (n: number) => (n > 0 ? "+" : n < 0 ? "−" : "") + money(Math.abs(n));

function shiftCashLines(s: ShiftRow, cur: string) {
  if (s.expected_cash == null) return "";
  let text = `\n💰 В кассе должно быть: <b>${money(s.expected_cash)} ${cur}</b>`;
  if (s.closed_at && s.actual_cash != null) {
    const diff = Number(s.difference ?? s.actual_cash - s.expected_cash);
    text += `\n💵 Сдано: ${money(s.actual_cash)} ${cur}` +
      (diff === 0 ? " ✅" : ` · ${diff > 0 ? "излишек" : "недостача"} <b>${signedMoney(diff)} ${cur}</b> ⚠️`);
  }
  return text;
}

function shiftLines(shifts: ShiftRow[], cfg: OwnerBotConfig) {
  if (shifts.length === 0) return "Смена не открывалась.";
  return shifts.map((s) => {
    const opener = s.opener?.full_name ? ` · ${esc(s.opener.full_name)}` : "";
    const closer = s.closer?.full_name ? ` · ${esc(s.closer.full_name)}` : "";
    return `🟢 Открыта: <b>${shortDateTime(s.opened_at, cfg.timezone)}</b>${opener}\n` +
      (s.closed_at
        ? `🔴 Закрыта: <b>${shortDateTime(s.closed_at, cfg.timezone)}</b>${closer}`
        : "⏳ Смена ещё не закрыта") +
      shiftCashLines(s, cfg.currency_suffix);
  }).join("\n\n");
}

async function showDayReport(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, y: number, mo: number, d: number) {
  const { from, to } = workDayBounds(y, mo, d, cfg.timezone);
  const now = new Date().toISOString();
  const again = { inline_keyboard: [[{ text: "🗓 Другой день", callback_data: `calnav:${y}-${pad(mo)}` }]] };
  if (from > now) return void send(cfg.bot_token, chatId, `${fmtDateRu(y, mo, d)} ещё не наступил.`, { reply_markup: again });

  const [{ data, error }, shifts] = await Promise.all([
    sb.rpc("bot_period_report", { p_club_id: cfg.club_id, p_from: from, p_to: to > now ? now : to }),
    shiftsInDay(sb, cfg.club_id, from, to),
  ]);
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });

  const text =
    `📊 <b>Отчёт за ${fmtDateRu(y, mo, d)}</b>\n\n` +
    `${shiftLines(shifts, cfg)}\n${DIVIDER}\n\n` +
    reportBody(data, cfg);

  await send(cfg.bot_token, chatId, text, {
    reply_markup: {
      inline_keyboard: [
        [{ text: "📥 Скачать Excel", callback_data: `xls:${isoDate(y, mo, d)}` }],
        [{ text: "🗓 Другой день", callback_data: `calnav:${y}-${pad(mo)}` }],
      ],
    },
  });
}

// Cash shifts: listed at the top of each day report. Separate per-shift
// reports are only reached from buttons on older messages.
type ShiftRow = {
  id: string;
  status: string;
  opened_at: string;
  closed_at: string | null;
  opening_cash: number | null;
  expected_cash: number | null;
  actual_cash: number | null;
  difference: number | null;
  opener: { full_name: string | null } | null;
  closer: { full_name: string | null } | null;
};

const SHIFT_SELECT =
  "id,status,opened_at,closed_at,opening_cash,expected_cash,actual_cash,difference," +
  "opener:profiles!cash_shifts_opened_by_fkey(full_name),closer:profiles!cash_shifts_closed_by_fkey(full_name)";

async function shiftById(sb: SupabaseClient, clubId: string, id: string): Promise<ShiftRow | null> {
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT).eq("club_id", clubId).eq("id", id).maybeSingle();
  return (data as unknown as ShiftRow) ?? null;
}

async function latestShift(sb: SupabaseClient, clubId: string): Promise<ShiftRow | null> {
  const { data } = await sb.from("cash_shifts").select(SHIFT_SELECT)
    .eq("club_id", clubId).order("opened_at", { ascending: false }).limit(1).maybeSingle();
  return (data as unknown as ShiftRow) ?? null;
}

const shiftBounds = (s: ShiftRow) => ({ from: s.opened_at, to: s.closed_at ?? new Date().toISOString() });

function durationLabel(fromIso: string, toIso: string): string {
  const totalMin = Math.max(0, Math.floor((new Date(toIso).getTime() - new Date(fromIso).getTime()) / 60_000));
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  return h === 0 ? `${m} мин` : m === 0 ? `${h} ч` : `${h} ч ${m} мин`;
}

function shortDateTime(iso: string, timeZone: string) {
  return new Intl.DateTimeFormat("ru-RU", {
    timeZone, day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).format(new Date(iso));
}

function shiftHeader(s: ShiftRow, timeZone: string) {
  const { from, to } = shiftBounds(s);
  const opener = s.opener?.full_name ? ` · ${esc(s.opener.full_name)}` : "";
  const closer = s.closer?.full_name ? ` · ${esc(s.closer.full_name)}` : "";
  const closedLine = s.closed_at
    ? `🔴 Закрыта: <b>${fmtDateTimeRu(s.closed_at, timeZone)}</b>${closer}`
    : `🟢 Смена идёт · сейчас ${fmtDateTimeRu(to, timeZone)}`;
  return (
    `🕘 Открыта: <b>${fmtDateTimeRu(s.opened_at, timeZone)}</b>${opener}\n` +
    `${closedLine}\n` +
    `⏱ Длительность: ${durationLabel(from, to)}`
  );
}

async function showShiftReport(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, shift: ShiftRow, note = "") {
  const { from, to } = shiftBounds(shift);
  const { data, error } = await sb.rpc("bot_period_report", { p_club_id: cfg.club_id, p_from: from, p_to: to });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });

  const text =
    `📊 <b>Отчёт по смене</b>\n` +
    (note ? `<i>${note}</i>\n` : "") +
    `\n${shiftHeader(shift, cfg.timezone)}\n${DIVIDER}\n\n` +
    reportBody(data, cfg);

  await send(cfg.bot_token, chatId, text, {
    reply_markup: {
      inline_keyboard: [
        [{ text: "📥 Скачать Excel", callback_data: `xlsshift:${shift.id}` }],
        [{ text: "🗓 Другой день", callback_data: "shiftcal" }],
      ],
    },
  });
}

async function sendShiftReportExcel(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, shift: ShiftRow) {
  const { from, to } = shiftBounds(shift);
  const [{ data: report, error }, { data: top }] = await Promise.all([
    sb.rpc("bot_period_report", { p_club_id: cfg.club_id, p_from: from, p_to: to }),
    sb.rpc("bot_top_products", { p_club_id: cfg.club_id, p_from: from, p_to: to, p_limit: 100 }),
  ]);
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });

  const opened = fmtDateTimeRu(shift.opened_at, cfg.timezone);
  const closed = shift.closed_at ? fmtDateTimeRu(shift.closed_at, cfg.timezone) : "смена идёт";
  const rows: unknown[][] = [
    ["Отчёт", "Смена"],
    ["Открыта", opened, shift.opener?.full_name ?? ""],
    ["Закрыта", closed, shift.closer?.full_name ?? ""],
    ["Длительность", durationLabel(from, to)],
    ["Сформирован", fmtDateTimeRu(new Date().toISOString(), cfg.timezone)],
    [],
    ...reportExcelRows(report, top ?? [], cfg),
  ];
  const openedDay = new Intl.DateTimeFormat("en-CA", { timeZone: cfg.timezone }).format(new Date(shift.opened_at));
  await sendDocument(
    cfg.bot_token, chatId, `report_shift_${openedDay}.csv`, csvRows(rows),
    `📈 Отчёт по смене ${opened} — ${closed}`,
  );
}

async function sendDayReportExcel(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, y: number, mo: number, d: number) {
  const bounds = workDayBounds(y, mo, d, cfg.timezone);
  const now = new Date().toISOString();
  const to = bounds.to > now ? now : bounds.to;
  const from = bounds.from;
  const [{ data: report }, { data: top }, shifts] = await Promise.all([
    sb.rpc("bot_period_report", { p_club_id: cfg.club_id, p_from: from, p_to: to }),
    sb.rpc("bot_top_products", { p_club_id: cfg.club_id, p_from: from, p_to: to, p_limit: 100 }),
    shiftsInDay(sb, cfg.club_id, from, bounds.to),
  ]);

  const rows: unknown[][] = [
    ["Отчёт", fmtDateRu(y, mo, d)],
    ...shifts.flatMap((s) => [
      ["Смена открыта", fmtDateTimeRu(s.opened_at, cfg.timezone), s.opener?.full_name ?? ""],
      s.closed_at
        ? ["Смена закрыта", fmtDateTimeRu(s.closed_at, cfg.timezone), s.closer?.full_name ?? ""]
        : ["Смена закрыта", "ещё не закрыта"],
      ["В кассе должно быть", s.expected_cash ?? ""],
      ...(s.closed_at && s.actual_cash != null
        ? [["Сдано", s.actual_cash], ["Разница", s.difference ?? s.actual_cash - (s.expected_cash ?? 0)]]
        : []),
    ]),
    [],
    ...reportExcelRows(report, top ?? [], cfg),
  ];
  await sendDocument(cfg.bot_token, chatId, `report_${isoDate(y, mo, d)}.csv`, csvRows(rows), `📈 Отчёт за ${fmtDateRu(y, mo, d)}`);
}

async function showTopProducts(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number) {
  const to = new Date();
  const from = new Date(to.getTime() - 30 * 24 * 3600 * 1000);
  const { data, error } = await sb.rpc("bot_top_products", {
    p_club_id: cfg.club_id, p_from: from.toISOString(), p_to: to.toISOString(), p_limit: 15,
  });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });
  const list = (data ?? []) as Array<Record<string, unknown>>;
  if (list.length === 0) {
    return void send(cfg.bot_token, chatId, "За последние 30 дней продаж не было.", { reply_markup: mainKeyboard });
  }
  const text = list
    .map((p, i) => `${medal(i)} <b>${p.product_name}</b> — ${p.quantity} шт · ${money(Number(p.revenue))} ${cfg.currency_suffix}`)
    .join("\n");
  await send(cfg.bot_token, chatId, `🏆 <b>Топ товаров за 30 дней</b>\n\n${text}`, { reply_markup: mainKeyboard });
}

const ratingWord = (n: number) => {
  const d10 = n % 10, d100 = n % 100;
  if (d10 === 1 && d100 !== 11) return "оценка";
  if (d10 >= 2 && d10 <= 4 && (d100 < 12 || d100 > 14)) return "оценки";
  return "оценок";
};
const stars = (n: number) => "⭐".repeat(Math.max(0, Math.min(5, n)));

/// Client visit ratings (1-5 stars from the receipt the client bot sends
/// after payment): average, spread, per-cashier average and the latest
/// ratings with comments. Period switches edit the same message in place.
async function showRatings(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, days: number, editMessageId?: number) {
  const { data, error } = await sb.rpc("bot_ratings_report", { p_club_id: cfg.club_id, p_days: days });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });

  const period = days === 7 ? "7 дней" : days === 30 ? "30 дней" : "всё время";
  const count = Number(data?.summary?.count ?? 0);
  let text = `⭐ <b>Оценки клиентов · ${period}</b>\n${DIVIDER}\n\n`;
  if (count === 0) {
    text += "Пока нет оценок за этот период.\n\nКлиенты оценивают визит от 1 до 5 ⭐ в чеке, который приходит им в бот после оплаты.";
  } else {
    text += `Средняя: <b>${data.summary.avg}</b> из 5 · ${count} ${ratingWord(count)}\n\n`;
    for (let s = 5; s >= 1; s--) text += `${stars(s)} — ${data.distribution?.[String(s)] ?? 0}\n`;

    const cashiers = (data.cashiers ?? []) as Array<Record<string, unknown>>;
    if (cashiers.length) {
      text += `\n👤 <b>По кассирам</b>\n` +
        cashiers.map((c) => `• ${esc(c.name)} — ${c.avg} ⭐ (${c.count})`).join("\n") + "\n";
    }

    const recent = (data.recent ?? []) as Array<Record<string, any>>;
    if (recent.length) {
      text += `\n🕗 <b>Последние</b>\n` + recent.map((r) => {
        const comment = r.comment ? String(r.comment) : "";
        const shortComment = comment.length > 200 ? comment.slice(0, 200) + "…" : comment;
        return `${stars(Number(r.rating))} ${r.at} · ${esc(r.customer)} · чек №${r.order_number ?? "—"}` +
          (r.cashier ? ` · ${esc(r.cashier)}` : "") +
          (shortComment ? `\n   💬 «${esc(shortComment)}»` : "");
      }).join("\n");
    }
  }

  const keyboard = {
    inline_keyboard: [[
      { text: days === 7 ? "• 7 дней" : "7 дней", callback_data: "ratings:7" },
      { text: days === 30 ? "• 30 дней" : "30 дней", callback_data: "ratings:30" },
      { text: days === 0 ? "• Всё время" : "Всё время", callback_data: "ratings:0" },
    ]],
  };
  if (editMessageId) {
    await tg(cfg.bot_token, "editMessageText", {
      chat_id: chatId, message_id: editMessageId, text, parse_mode: "HTML", reply_markup: keyboard,
    });
  } else {
    await send(cfg.bot_token, chatId, text, { reply_markup: keyboard });
  }
}

const STOCK_PAGE_SIZE = 10;

function buildStockReport(list: Array<Record<string, unknown>>, page: number) {
  const total = list.length;
  const lowCount = list.filter((p) => p.low).length;

  if (total === 0) {
    return {
      text: `📦 <b>Товары и остатки</b>\n\nНет товаров с учётом остатков.`,
      keyboard: undefined as { inline_keyboard: Array<Array<{ text: string; callback_data: string }>> } | undefined,
    };
  }

  const pages = Math.max(1, Math.ceil(total / STOCK_PAGE_SIZE));
  const safePage = Math.min(Math.max(1, page), pages);
  const slice = list.slice((safePage - 1) * STOCK_PAGE_SIZE, safePage * STOCK_PAGE_SIZE);

  const rows = slice
    .map((p, i) => {
      const n = (safePage - 1) * STOCK_PAGE_SIZE + i + 1;
      const warn = p.low ? "⚠️ " : "";
      const cat = p.category_name ? ` (${p.category_name})` : "";
      return `${n}. ${warn}<b>${p.name}</b>${cat} — ${p.stock_quantity} ${p.unit ?? "шт"}`;
    })
    .join("\n");

  const nav: Array<{ text: string; callback_data: string }> = [];
  if (safePage > 1) nav.push({ text: "◂", callback_data: `stock:${safePage - 1}` });
  nav.push({ text: `${safePage}/${pages}`, callback_data: "noop" });
  if (safePage < pages) nav.push({ text: "▸", callback_data: `stock:${safePage + 1}` });

  return {
    text:
      `📦 <b>Товары и остатки</b>\n` +
      `📌 Всего: ${total} · ⚠️ Мало: ${lowCount}\n` +
      `📄 Страница: ${safePage}/${pages}\n\n${rows}`,
    keyboard: { inline_keyboard: [nav] },
  };
}

async function showStockReport(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number) {
  const { data, error } = await sb.rpc("bot_stock_report", { p_club_id: cfg.club_id });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });
  const report = buildStockReport((data ?? []) as Array<Record<string, unknown>>, 1);
  await send(cfg.bot_token, chatId, report.text, { reply_markup: report.keyboard ?? mainKeyboard });
}

async function showChartMenu(token: string, chatId: number) {
  await send(token, chatId, "📈 <b>График выручки</b>\n\nЗа какой период?", {
    reply_markup: {
      inline_keyboard: [
        [{ text: "Сегодня (по часам)", callback_data: "chart:day" }],
        [{ text: "7 дней", callback_data: "chart:7" }, { text: "30 дней", callback_data: "chart:30" }],
        [{ text: "🕗 Свой период", callback_data: "chart:range" }],
      ],
    },
  });
}

async function showHourlyChart(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number) {
  const t = todayInZone(cfg.timezone);
  const { data, error } = await sb.rpc("bot_revenue_hourly", { p_club_id: cfg.club_id, p_date: isoDate(t.y, t.mo, t.d) });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });
  const rows = (data ?? []) as Array<{ hour: number; revenue: number }>;
  const labels = rows.map((r) => `${pad(r.hour)}:00`);
  const values = rows.map((r) => Number(r.revenue));
  const total = values.reduce((a, b) => a + b, 0);
  await sendChart(
    cfg.bot_token, chatId, labels, values, `Выручка за ${fmtDateRu(t.y, t.mo, t.d)}`,
    `📈 Сегодня: <b>${money(total)} ${cfg.currency_suffix}</b>`,
  );
}

async function showRangeChart(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, from: string, to: string, label: string) {
  const { data, error } = await sb.rpc("bot_revenue_range", { p_club_id: cfg.club_id, p_from: from, p_to: to });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });
  const rows = (data ?? []) as Array<{ day: string; revenue: number }>;
  const labels = rows.map((r) => {
    const [, mo, d] = r.day.split("-");
    return `${d}.${mo}`;
  });
  const values = rows.map((r) => Number(r.revenue));
  const total = values.reduce((a, b) => a + b, 0);
  await sendChart(cfg.bot_token, chatId, labels, values, `Выручка ${label}`, `📈 ${label}: <b>${money(total)} ${cfg.currency_suffix}</b>`);
}

// "Добавить сотрудника" branches into two different invite systems: a
// cashier only ever needs club-bot (the floor + bookings), a co-owner needs
// this bot itself (full reports) — so each gets its own code and its own
// redemption flow, never mixed.
async function showStaffMenu(cfg: OwnerBotConfig, chatId: number, isOwner: boolean) {
  if (!isOwner) {
    return void send(cfg.bot_token, chatId, "Добавлять сотрудников может только владелец.", { reply_markup: mainKeyboard });
  }
  await send(
    cfg.bot_token, chatId,
    `➕ <b>Добавить сотрудника</b>\n${DIVIDER}\n\nКого добавляем?`,
    {
      reply_markup: {
        inline_keyboard: [
          [{ text: "🧾 Кассира — вход в кассу", callback_data: "staff:cashier" }],
          [{ text: "👑 Совладельца — вход в этот бот", callback_data: "staff:owner" }],
        ],
      },
    },
  );
}

async function askWelcomePhoto(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, fromId: number) {
  await setPending(sb, cfg.owner_bot_id, fromId, "await_welcome_photo");
  await send(
    cfg.bot_token, chatId,
    "🖼 <b>Фото приветствия</b>\n\n" +
      "Пришлите фото одним сообщением — оно будет показываться клиентам при первом /start в вашем клиентском боте.",
  );
}

/// A Telegram file_id is only valid for the bot that received it — this owner
/// bot and the club-bot are different bots with different tokens, so a photo
/// sent here can't just be handed to club-bot by id. Re-hosting it in
/// Supabase Storage as a plain public URL sidesteps that: any bot's
/// `sendPhoto` can fetch a URL regardless of which bot uploaded it.
async function uploadTelegramPhotoToStorage(
  sb: SupabaseClient, botToken: string, fileId: string, clubId: string,
): Promise<string> {
  const fileInfo = await (await fetch(`https://api.telegram.org/bot${botToken}/getFile?file_id=${fileId}`)).json();
  const filePath = fileInfo?.result?.file_path;
  if (!filePath) throw new Error("getFile failed");
  const bytes = new Uint8Array(
    await (await fetch(`https://api.telegram.org/file/bot${botToken}/${filePath}`)).arrayBuffer(),
  );
  const ext = (filePath.split(".").pop() || "jpg").toLowerCase();
  const storagePath = `${clubId}/welcome.${ext}`;
  const { error } = await sb.storage.from("club-assets").upload(storagePath, bytes, {
    contentType: `image/${ext === "jpg" ? "jpeg" : ext}`,
    upsert: true,
  });
  if (error) throw error;
  return sb.storage.from("club-assets").getPublicUrl(storagePath).data.publicUrl;
}

async function sendCashierInvite(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number, fromId: number) {
  const { data, error } = await sb.rpc("bot_create_staff_invite", { p_club_id: cfg.club_id, p_tg_id: fromId });
  if (error) return void send(cfg.bot_token, chatId, `⚠️ Ошибка: ${error.message}`, { reply_markup: mainKeyboard });
  await send(
    cfg.bot_token, chatId,
    `🧾 <b>Код для кассира</b>\n${DIVIDER}\n\n<code>${data.code}</code>\n\n` +
      `Пусть кассир откроет бота кассы и клиентов клуба и пришлёт этот код сообщением — получит доступ к карте зала и броням.\n` +
      `⏳ Код действует сутки и срабатывает один раз.`,
    { reply_markup: mainKeyboard },
  );
}

async function showOwnerAccessList(sb: SupabaseClient, cfg: OwnerBotConfig, chatId: number) {
  const { data: viewers } = await sb
    .from("owner_bot_access")
    .select("name, chat_id, created_at")
    .eq("owner_bot_id", cfg.owner_bot_id)
    .order("created_at");
  const list = (viewers ?? []) as Array<Record<string, unknown>>;
  const text = list.length
    ? list.map((v) => `• ${v.name ?? v.chat_id}`).join("\n")
    : "Пока никто не добавлен.";
  await send(
    cfg.bot_token, chatId,
    `👑 <b>Совладельцы этого бота</b>\n${DIVIDER}\n\n${text}`,
    { reply_markup: { inline_keyboard: [[{ text: "➕ Код для совладельца", callback_data: "invite" }]] } },
  );
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");

  const url = new URL(req.url);
  const secret = url.searchParams.get("s") ?? "";
  if (!secret) return new Response("forbidden", { status: 403 });

  const sb = sharedDb;
  let cfg: OwnerBotConfig;
  const cachedCfg = cfgCache.get(secret);
  if (cachedCfg && cachedCfg.expiresAt > Date.now()) {
    cfg = cachedCfg.value;
  } else {
    const { data: cfgData } = await sb.rpc("owner_bot_by_secret", { p_secret: secret });
    if (!cfgData?.ok) return new Response("forbidden", { status: 403 });
    cfg = cfgData as OwnerBotConfig;
    cfgCache.set(secret, { value: cfg, expiresAt: Date.now() + 5 * 60_000 });
  }
  const token = cfg.bot_token;

  let update: Record<string, any>;
  try {
    update = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  try {
    const msg = update.message;
    const cb = update.callback_query;
    const chatId: number | undefined = msg?.chat?.id ?? cb?.message?.chat?.id;
    const fromId: number | undefined = msg?.from?.id ?? cb?.from?.id;
    if (!chatId || !fromId) return new Response("ok");

    // Stops the button spinner right away, in parallel with the work below.
    if (cb) waitUntil(tg(token, "answerCallbackQuery", { callback_query_id: cb.id }).catch(() => undefined));

    const name = [msg?.from?.first_name ?? cb?.from?.first_name, msg?.from?.last_name ?? cb?.from?.last_name]
      .filter(Boolean).join(" ");
    const roleKey = `${cfg.owner_bot_id}:${fromId}`;
    let roleName: string;
    const cachedRole = roleCache.get(roleKey);
    if (cachedRole && cachedRole.expiresAt > Date.now()) {
      roleName = cachedRole.role;
    } else {
      const role = await sb.rpc("owner_bot_claim", { p_owner_bot_id: cfg.owner_bot_id, p_chat_id: fromId, p_name: name || null });
      roleName = String(role.data ?? "");
      if (roleName === "OWNER" || roleName === "VIEWER") {
        roleCache.set(roleKey, { role: roleName, expiresAt: Date.now() + 3 * 60_000 });
      }
    }
    const isOwner = roleName === "OWNER";
    const hasAccess = roleName === "OWNER" || roleName === "VIEWER";

    if (cb) {
      const data = String(cb.data ?? "");
      if (!hasAccess) return new Response("ok");

      if (data === "noop") return new Response("ok");
      if (data === "menu") {
        await setPending(sb, cfg.owner_bot_id, fromId, null);
        await send(token, chatId, `🏢 <b>${cfg.club_name}</b>`, { reply_markup: mainKeyboard });
        return new Response("ok");
      }
      // "📋 Другие смены" / "🗓 Выбрать день" on older shift reports.
      if (data === "shifts" || data === "shiftcal") {
        const t = currentWorkDay(cfg.timezone);
        await setPending(sb, cfg.owner_bot_id, fromId, "report_day");
        await sendDayPicker(cfg, chatId, t.y, t.mo);
        return new Response("ok");
      }
      if (data.startsWith("shift:")) {
        const shift = await shiftById(sb, cfg.club_id, data.slice(6));
        if (!shift) await send(token, chatId, "Смена не найдена.", { reply_markup: mainKeyboard });
        else await showShiftReport(sb, cfg, chatId, shift);
        return new Response("ok");
      }
      // Bare "xlsshift" is the button on reports sent before shifts had ids.
      if (data === "xlsshift" || data.startsWith("xlsshift:")) {
        const shift = data === "xlsshift"
          ? await latestShift(sb, cfg.club_id)
          : await shiftById(sb, cfg.club_id, data.slice(9));
        if (!shift) await send(token, chatId, "Смена не найдена.", { reply_markup: mainKeyboard });
        else await sendShiftReportExcel(sb, cfg, chatId, shift);
        return new Response("ok");
      }
      if (data.startsWith("ratings:")) {
        const days = Number(data.slice(8)) || 0;
        await showRatings(sb, cfg, chatId, days, cb.message?.message_id);
        return new Response("ok");
      }
      if (data.startsWith("calnav:")) {
        const [y, mo] = data.slice(7).split("-").map(Number);
        const pending = await getPending(sb, cfg.owner_bot_id, fromId);
        if (pending?.action === "range_from" || pending?.action === "range_to") {
          const dayPrefix = pending.action === "range_from" ? "rfrom:" : "rto:";
          await send(token, chatId, "Выберите день:", { reply_markup: buildCalendar(y, mo, dayPrefix, todayInZone(cfg.timezone)) });
        } else {
          await sendDayPicker(cfg, chatId, y, mo);
        }
        return new Response("ok");
      }
      if (data.startsWith("calday:")) {
        const [y, mo, d] = data.slice(7).split("-").map(Number);
        await showDayReport(sb, cfg, chatId, y, mo, d);
        return new Response("ok");
      }
      if (data.startsWith("xls:")) {
        const [y, mo, d] = data.slice(4).split("-").map(Number);
        await sendDayReportExcel(sb, cfg, chatId, y, mo, d);
        return new Response("ok");
      }
      if (data === "chart:day") {
        await showHourlyChart(sb, cfg, chatId);
        return new Response("ok");
      }
      if (data === "chart:7" || data === "chart:30") {
        const days = data === "chart:7" ? 7 : 30;
        const t = todayInZone(cfg.timezone);
        const toIso = isoDate(t.y, t.mo, t.d);
        const fromDate = new Date(Date.UTC(t.y, t.mo - 1, t.d - (days - 1)));
        const fromIso = isoDate(fromDate.getUTCFullYear(), fromDate.getUTCMonth() + 1, fromDate.getUTCDate());
        await showRangeChart(sb, cfg, chatId, fromIso, toIso, `за ${days} дней`);
        return new Response("ok");
      }
      if (data === "chart:range") {
        const t = todayInZone(cfg.timezone);
        await setPending(sb, cfg.owner_bot_id, fromId, "range_from");
        await send(token, chatId, "Начало периода — выберите день:", { reply_markup: buildCalendar(t.y, t.mo, "rfrom:", todayInZone(cfg.timezone)) });
        return new Response("ok");
      }
      if (data.startsWith("rfrom:")) {
        const [y, mo, d] = data.slice(6).split("-").map(Number);
        await setPending(sb, cfg.owner_bot_id, fromId, "range_to", { from: isoDate(y, mo, d) });
        await send(token, chatId, `Начало: ${fmtDateRu(y, mo, d)}\nКонец периода — выберите день:`, {
          reply_markup: buildCalendar(y, mo, "rto:", todayInZone(cfg.timezone)),
        });
        return new Response("ok");
      }
      if (data.startsWith("rto:")) {
        const [y, mo, d] = data.slice(4).split("-").map(Number);
        const pending = await getPending(sb, cfg.owner_bot_id, fromId);
        const from = (pending?.payload as Record<string, string>)?.from;
        await setPending(sb, cfg.owner_bot_id, fromId, null);
        if (!from) {
          await send(token, chatId, "↩️ Начните заново — «📈 График» → «Свой период».", { reply_markup: mainKeyboard });
          return new Response("ok");
        }
        const to = isoDate(y, mo, d);
        const [fy, fmo, fd] = from.split("-").map(Number);
        const label = from <= to
          ? `${fmtDateRu(fy, fmo, fd)} — ${fmtDateRu(y, mo, d)}`
          : `${fmtDateRu(y, mo, d)} — ${fmtDateRu(fy, fmo, fd)}`;
        await showRangeChart(sb, cfg, chatId, from <= to ? from : to, from <= to ? to : from, label);
        return new Response("ok");
      }
      if (data.startsWith("stock:")) {
        const page = Number(data.slice(6)) || 1;
        const { data: stockData } = await sb.rpc("bot_stock_report", { p_club_id: cfg.club_id });
        const report = buildStockReport((stockData ?? []) as Array<Record<string, unknown>>, page);
        if (report.keyboard) {
          await tg(token, "editMessageText", {
            chat_id: chatId,
            message_id: cb.message.message_id,
            text: report.text,
            parse_mode: "HTML",
            reply_markup: report.keyboard,
          });
        }
        return new Response("ok");
      }
      if (data === "staff:cashier") {
        if (!isOwner) return new Response("ok");
        await sendCashierInvite(sb, cfg, chatId, fromId);
        return new Response("ok");
      }
      if (data === "staff:owner") {
        if (!isOwner) return new Response("ok");
        await showOwnerAccessList(sb, cfg, chatId);
        return new Response("ok");
      }
      if (data === "invite") {
        if (!isOwner) return new Response("ok");
        const { data: code } = await sb.rpc("owner_bot_create_invite", { p_owner_bot_id: cfg.owner_bot_id, p_chat_id: fromId });
        await send(
          token, chatId,
          `👥 <b>Код для доступа</b>\n${DIVIDER}\n\n<code>${code}</code>\n\n` +
            `Пусть откроет этот бот и пришлёт этот код сообщением.`,
        );
        return new Response("ok");
      }
      return new Response("ok");
    }

    if (msg?.photo && isOwner) {
      const pending = await getPending(sb, cfg.owner_bot_id, fromId);
      if (pending?.action === "await_welcome_photo") {
        await setPending(sb, cfg.owner_bot_id, fromId, null);
        try {
          const largest = msg.photo[msg.photo.length - 1];
          const url = await uploadTelegramPhotoToStorage(sb, token, largest.file_id, cfg.club_id);
          await sb.from("clubs").update({ bot_welcome_photo_url: url }).eq("id", cfg.club_id);
          await send(token, chatId, "✅ Фото приветствия обновлено — клиенты увидят его в /start.", { reply_markup: mainKeyboard });
        } catch (e) {
          await send(token, chatId, `⚠️ Не получилось сохранить фото: ${e}`, { reply_markup: mainKeyboard });
        }
        return new Response("ok");
      }
    }

    const text = String(msg?.text ?? "").trim();
    if (!text) return new Response("ok");

    if (!hasAccess) {
      if (/^[A-Z0-9]{8}$/i.test(text)) {
        const { data: ok } = await sb.rpc("owner_bot_redeem_invite", {
          p_owner_bot_id: cfg.owner_bot_id, p_code: text, p_chat_id: fromId, p_name: name || null,
        });
        if (ok === true) {
          await send(token, chatId, `✅ Доступ открыт.\n\n🏢 <b>${cfg.club_name}</b>`, { reply_markup: mainKeyboard });
          return new Response("ok");
        }
      }
      await send(
        token, chatId,
        "У вас нет доступа к этому боту. Если у вас есть код приглашения — отправьте его.",
      );
      return new Response("ok");
    }

    if (text.startsWith("/start") || text === "/menu") {
      await Promise.all([
        setPending(sb, cfg.owner_bot_id, fromId, null),
        send(token, chatId, `🏢 <b>${cfg.club_name}</b>\n\nПолные отчёты, склад и финансы клуба.`, { reply_markup: mainKeyboard }),
      ]);
      return new Response("ok");
    }

    switch (text) {
      case MENU.today: {
        const t = currentWorkDay(cfg.timezone);
        await showDayReport(sb, cfg, chatId, t.y, t.mo, t.d);
        return new Response("ok");
      }
      case MENU.period:
      case "🕗 За период": { // label on keyboards sent before the rename
        const t = currentWorkDay(cfg.timezone);
        await Promise.all([
          setPending(sb, cfg.owner_bot_id, fromId, "report_day"),
          sendDayPicker(cfg, chatId, t.y, t.mo),
        ]);
        return new Response("ok");
      }
      case MENU.chart:
        await showChartMenu(token, chatId);
        return new Response("ok");
      case MENU.top:
        await showTopProducts(sb, cfg, chatId);
        return new Response("ok");
      case MENU.stock:
        await showStockReport(sb, cfg, chatId);
        return new Response("ok");
      case MENU.staff:
        await showStaffMenu(cfg, chatId, isOwner);
        return new Response("ok");
      case MENU.ratings:
        await showRatings(sb, cfg, chatId, 30);
        return new Response("ok");
      case MENU.photo:
        if (!isOwner) return new Response("ok");
        await askWelcomePhoto(sb, cfg, chatId, fromId);
        return new Response("ok");
    }

    await send(token, chatId, `🏢 <b>${cfg.club_name}</b>`, { reply_markup: mainKeyboard });
  } catch (e) {
    console.error(e);
  }

  return new Response("ok");
});
