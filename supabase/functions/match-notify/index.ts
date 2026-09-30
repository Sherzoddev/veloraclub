// "Найти соперника": every Telegram side effect of a match request, fired by
// the match_requests / match_messages triggers via pg_net (see the
// find_opponent migration). The bot and the client Mini App only change rows
// through the match_* RPCs; this is the one place that talks to Telegram, so
// both channels behave the same.
//
//   created   → broadcast to every client of the club (message ids kept in
//               match_broadcasts), confirmation to the creator
//   matched   → broadcasts edited to "соперник найден", both players told
//   reopened  → broadcasts back to open, creator + the one who left told
//   cancelled / expired → broadcasts closed, the other player told
//   message   → relayed to the other player with reply buttons
//
// Protected by a shared key in the query string, like reservation-sweeper.
// Answers at once and does the work in the background: pg_net only waits a
// few seconds, a broadcast to every client takes longer.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const NOTIFY_KEY = "p7oc8zbhdskjopwb4n6ntxkbvgsu64y0at3w";
const MINI_APP_URL = "https://velora-club-miniapp-production.up.railway.app/";

const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

type Lang = "ru" | "uz";
const L = (lang: Lang, ru: string, uz: string) => (lang === "uz" ? uz : ru);
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Match = {
  id: string; club_id: string; creator_customer_id: string; opponent_customer_id: string | null;
  play_at: string; level: string; comment: string | null; status: string;
};
type Person = { id: string; name: string; visits: number; tgId: number | null };
type Ctx = { token: string; zone: string; clubId: string; langs: Map<number, Lang> };

async function tg(token: string, method: string, body: unknown): Promise<any> {
  // Telegram allows ~30 messages/s per bot; one retry after a 429 keeps a
  // large broadcast from silently dropping recipients.
  for (let attempt = 0; attempt < 2; attempt++) {
    const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (res.status === 429 && attempt === 0) {
      await sleep(((data?.parameters?.retry_after as number) ?? 1) * 1000 + 100);
      continue;
    }
    if (!res.ok && !String(data?.description ?? "").includes("message is not modified")) {
      console.error(method, res.status, data?.description);
    }
    return data;
  }
}

const LEVELS: Record<string, [string, string]> = {
  NOVICE: ["🟢 новичок", "🟢 boshlovchi"],
  MIDDLE: ["🟡 средний", "🟡 o'rta"],
  PRO: ["🔴 профи", "🔴 professional"],
};
const levelLabel = (level: string, lang: Lang) => (LEVELS[level] ?? LEVELS.MIDDLE)[lang === "uz" ? 1 : 0];

function visitsLabel(n: number, lang: Lang) {
  if (lang === "uz") return `${n} ta tashrif`;
  const d10 = n % 10, d100 = n % 100;
  const word = d10 === 1 && d100 !== 11 ? "визит" : d10 >= 2 && d10 <= 4 && (d100 < 12 || d100 > 14) ? "визита" : "визитов";
  return `${n} ${word}`;
}

function whenLabel(playAt: string, zone: string, lang: Lang) {
  const at = new Date(playAt);
  if (at.getTime() <= Date.now() + 5 * 60_000) return L(lang, "сейчас", "hozir");
  const day = (d: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: zone }).format(d);
  const time = new Intl.DateTimeFormat("ru-RU", { timeZone: zone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(at);
  if (day(at) === day(new Date())) return L(lang, `сегодня в ${time}`, `bugun ${time}`);
  return L(lang, `завтра в ${time}`, `ertaga ${time}`);
}

async function person(customerId: string | null): Promise<Person | null> {
  if (!customerId) return null;
  const { data } = await sb.from("customers").select("id, full_name, visits_count, telegram_id").eq("id", customerId).maybeSingle();
  if (!data) return null;
  return {
    id: data.id,
    name: String(data.full_name ?? "").trim().split(/\s+/)[0] || "Игрок",
    visits: Number(data.visits_count ?? 0),
    tgId: data.telegram_id ? Number(data.telegram_id) : null,
  };
}

async function langOf(ctx: Ctx, tgId: number): Promise<Lang> {
  if (!ctx.langs.has(tgId)) {
    const { data } = await sb.from("bot_state").select("language").eq("telegram_id", tgId).maybeSingle();
    ctx.langs.set(tgId, data?.language === "ru" ? "ru" : "uz");
  }
  return ctx.langs.get(tgId)!;
}

const appButton = (ctx: Ctx, lang: Lang) =>
  ({ text: L(lang, "📱 Открыть в приложении", "📱 Ilovada ochish"), web_app: { url: `${MINI_APP_URL}?c=${encodeURIComponent(ctx.clubId)}&match=1` } });

// The request card every client sees; `state` decides the header and whether
// the "Сыграю!" button is still there.
function card(m: Match, creator: Person, ctx: Ctx, lang: Lang, state: "open" | "matched" | "cancelled" | "expired") {
  const header = {
    open: L(lang, "⚪ <b>Ищу соперника на бильярд!</b>", "⚪ <b>Bilyardga raqib qidiryapman!</b>"),
    matched: L(lang, "✅ <b>Соперник уже найден</b>", "✅ <b>Raqib topildi</b>"),
    cancelled: L(lang, "❌ <b>Заявка отменена</b>", "❌ <b>So'rov bekor qilindi</b>"),
    expired: L(lang, "⌛ <b>Время игры прошло</b>", "⌛ <b>O'yin vaqti o'tdi</b>"),
  }[state];
  const lines = [
    header, "",
    `👤 <b>${esc(creator.name)}</b> · ${visitsLabel(creator.visits, lang)}`,
    `🎯 ${L(lang, "Уровень", "Daraja")}: ${levelLabel(m.level, lang)}`,
    `🕗 ${whenLabel(m.play_at, ctx.zone, lang)}`,
  ];
  if (m.comment) lines.push(`💬 «${esc(m.comment)}»`);
  if (state === "open") {
    lines.push("", L(lang, "Кто первым нажмёт «Сыграю!» — тот и играет 🔥", "Kim birinchi «O'ynayman!» ni bossa — o'sha o'ynaydi 🔥"));
  }
  const reply_markup = state === "open"
    ? { inline_keyboard: [[{ text: L(lang, "⚪ Сыграю!", "⚪ O'ynayman!"), callback_data: `mta:${m.id}` }], [appButton(ctx, lang)]] }
    : { inline_keyboard: [] };
  return { text: lines.join("\n"), reply_markup };
}

async function sendTo(ctx: Ctx, tgId: number | null, build: (lang: Lang) => { text: string; reply_markup?: unknown }) {
  if (!tgId) return;
  const lang = await langOf(ctx, tgId);
  const { text, reply_markup } = build(lang);
  await tg(ctx.token, "sendMessage", { chat_id: tgId, text, parse_mode: "HTML", reply_markup });
}

async function broadcast(m: Match, creator: Person, ctx: Ctx) {
  const { data: users } = await sb.from("club_bot_users").select("telegram_id, chat_id")
    .eq("club_id", m.club_id).eq("role", "CLIENT").not("terms_accepted_at", "is", null);
  const { data: states } = await sb.from("bot_state").select("telegram_id, language")
    .in("telegram_id", ((users ?? []) as any[]).map((u) => u.telegram_id));
  for (const s of (states ?? []) as any[]) ctx.langs.set(Number(s.telegram_id), s.language === "ru" ? "ru" : "uz");

  const rows: Array<{ match_id: string; chat_id: number; message_id: number; lang: Lang }> = [];
  const targets = ((users ?? []) as any[]).filter((u) => Number(u.chat_id ?? u.telegram_id) && Number(u.telegram_id) !== creator.tgId);
  await pool(targets, async (u) => {
    const chatId = Number(u.chat_id ?? u.telegram_id);
    const lang = ctx.langs.get(Number(u.telegram_id)) ?? "uz";
    const { text, reply_markup } = card(m, creator, ctx, lang, "open");
    const res = await tg(ctx.token, "sendMessage", { chat_id: chatId, text, parse_mode: "HTML", reply_markup });
    if (res?.ok) rows.push({ match_id: m.id, chat_id: chatId, message_id: res.result.message_id, lang });
  });
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await sb.from("match_broadcasts").upsert(rows.slice(i, i + 500));
    if (error) console.error("match_broadcasts", error);
  }
  // Someone may have accepted (or the creator cancelled) while this was
  // still sending -- those restyles ran before these rows existed.
  await restyleBroadcasts(m, creator, ctx, { onlyIfNot: "OPEN" });
  return rows.length;
}

const STATE_BY_STATUS: Record<string, "open" | "matched" | "cancelled" | "expired"> = {
  OPEN: "open", MATCHED: "matched", CANCELLED: "cancelled", EXPIRED: "expired",
};

// Always restyles to the request's status *now*, not the event's: events
// fired in quick succession (accepted, then backed out) run concurrently.
async function restyleBroadcasts(m: Match, creator: Person, ctx: Ctx, opts: { onlyIfNot?: string } = {}) {
  const { data: fresh } = await sb.from("match_requests").select("status").eq("id", m.id).maybeSingle();
  if (!fresh || fresh.status === opts.onlyIfNot) return;
  const state = STATE_BY_STATUS[fresh.status] ?? "cancelled";
  const { data } = await sb.from("match_broadcasts").select("chat_id, message_id, lang").eq("match_id", m.id);
  await pool((data ?? []) as any[], async (b) => {
    const { text, reply_markup } = card(m, creator, ctx, b.lang === "ru" ? "ru" : "uz", state);
    await tg(ctx.token, "editMessageText", {
      chat_id: b.chat_id, message_id: b.message_id, text, parse_mode: "HTML", reply_markup,
    });
  });
}

// A few requests in flight at a time, paced to stay under Telegram's ~30
// messages per second per bot.
async function pool<T>(items: T[], work: (item: T) => Promise<void>, concurrency = 6) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      try {
        await work(item);
      } catch (e) {
        console.error("match-notify send", e);
      }
      await sleep(200);
    }
  }));
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (url.searchParams.get("key") !== NOTIFY_KEY) return new Response("forbidden", { status: 403 });
  if (req.method !== "POST") return new Response("ok");

  let ev: MatchEvent;
  try {
    ev = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }
  EdgeRuntime.waitUntil(handle(ev).catch((e) => console.error("match-notify", e)));
  return new Response("accepted", { status: 202 });
});

type MatchEvent = { event?: string; match_id?: string; message_id?: string; prev_opponent?: string | null };

async function handle(ev: MatchEvent) {
  const { data: m } = await sb.from("match_requests").select("*").eq("id", ev.match_id ?? "").maybeSingle();
  if (!m) return;
  const match = m as Match;
  const [{ data: bot }, { data: club }] = await Promise.all([
    sb.from("club_bots").select("bot_token").eq("club_id", match.club_id).eq("active", true).limit(1).maybeSingle(),
    sb.from("clubs").select("timezone").eq("id", match.club_id).maybeSingle(),
  ]);
  if (!bot?.bot_token) return;
  const ctx: Ctx = { token: bot.bot_token, zone: club?.timezone ?? "Asia/Tashkent", clubId: match.club_id, langs: new Map() };
  const creator = await person(match.creator_customer_id);
  if (!creator) return;

  const writeBtn = (lang: Lang) => ({ text: L(lang, "💬 Написать сопернику", "💬 Raqibga yozish"), callback_data: `mtr:${match.id}` });

  switch (ev.event) {
    case "created": {
      const reached = await broadcast(match, creator, ctx);
      await sendTo(ctx, creator.tgId, (lang) => ({
        text: L(lang,
          `📣 <b>Заявка опубликована!</b>\n\n🕗 ${whenLabel(match.play_at, ctx.zone, lang)} · ${levelLabel(match.level, lang)}\n` +
            `Её увидели ${reached} игроков клуба. Как только кто-то нажмёт «Сыграю!», сразу сообщу.`,
          `📣 <b>So'rov e'lon qilindi!</b>\n\n🕗 ${whenLabel(match.play_at, ctx.zone, lang)} · ${levelLabel(match.level, lang)}\n` +
            `Uni klubning ${reached} o'yinchisi ko'rdi. Kimdir «O'ynayman!» ni bosishi bilan xabar beraman.`),
        reply_markup: { inline_keyboard: [[{ text: L(lang, "❌ Отменить заявку", "❌ So'rovni bekor qilish"), callback_data: `mtc:${match.id}` }], [appButton(ctx, lang)]] },
      }));
      break;
    }
    case "matched": {
      const opponent = await person(match.opponent_customer_id);
      if (!opponent) break;
      await sendTo(ctx, creator.tgId, (lang) => ({
        text: L(lang,
          `🎉 <b>Соперник найден!</b>\n\n👤 <b>${esc(opponent.name)}</b> · ${visitsLabel(opponent.visits, lang)}\n🕗 ${whenLabel(match.play_at, ctx.zone, lang)}\n\n` +
            `Договоритесь о деталях — переписка идёт через бота, ваш Telegram никто не видит.`,
          `🎉 <b>Raqib topildi!</b>\n\n👤 <b>${esc(opponent.name)}</b> · ${visitsLabel(opponent.visits, lang)}\n🕗 ${whenLabel(match.play_at, ctx.zone, lang)}\n\n` +
            `Tafsilotlarni kelishib oling — yozishmalar bot orqali, Telegramingiz hech kimga ko'rinmaydi.`),
        reply_markup: { inline_keyboard: [[writeBtn(lang)], [{ text: L(lang, "❌ Отменить игру", "❌ O'yinni bekor qilish"), callback_data: `mtc:${match.id}` }]] },
      }));
      await sendTo(ctx, opponent.tgId, (lang) => ({
        text: L(lang,
          `✅ <b>Вы играете!</b>\n\n👤 Соперник: <b>${esc(creator.name)}</b> · ${visitsLabel(creator.visits, lang)}\n🕗 ${whenLabel(match.play_at, ctx.zone, lang)}\n\n` +
            `Напишите сопернику — переписка идёт через бота.`,
          `✅ <b>Siz o'ynaysiz!</b>\n\n👤 Raqib: <b>${esc(creator.name)}</b> · ${visitsLabel(creator.visits, lang)}\n🕗 ${whenLabel(match.play_at, ctx.zone, lang)}\n\n` +
            `Raqibga yozing — yozishmalar bot orqali.`),
        reply_markup: { inline_keyboard: [[writeBtn(lang)], [{ text: L(lang, "↩️ Не смогу", "↩️ Kela olmayman"), callback_data: `mtl:${match.id}` }]] },
      }));
      await restyleBroadcasts(match, creator, ctx);
      break;
    }
    case "reopened": {
      const left = await person(ev.prev_opponent ?? null);
      await sendTo(ctx, creator.tgId, (lang) => ({
        text: L(lang,
          `😕 <b>${esc(left?.name ?? "Соперник")}</b> не сможет прийти.\n\nЗаявка снова активна — ищем другого соперника.`,
          `😕 <b>${esc(left?.name ?? "Raqib")}</b> kela olmaydi.\n\nSo'rov yana faol — boshqa raqib qidiryapmiz.`),
        reply_markup: { inline_keyboard: [[{ text: L(lang, "❌ Отменить заявку", "❌ So'rovni bekor qilish"), callback_data: `mtc:${match.id}` }]] },
      }));
      await sendTo(ctx, left?.tgId ?? null, (lang) => ({
        text: L(lang, "Вы отказались от игры. Заявка снова открыта для других.", "Siz o'yindan voz kechdingiz. So'rov boshqalar uchun yana ochiq."),
      }));
      await restyleBroadcasts(match, creator, ctx);
      break;
    }
    case "cancelled":
    case "expired": {
      const state = ev.event === "expired" ? "expired" : "cancelled";
      const prev = await person(ev.prev_opponent ?? null);
      if (state === "cancelled") {
        // Skipped when the request was closed because its creator just took
        // someone else's game (match_accept) -- they're told about that game.
        const { data: nowPlaying } = await sb.from("match_requests").select("id")
          .eq("club_id", match.club_id).eq("opponent_customer_id", match.creator_customer_id).eq("status", "MATCHED")
          .gte("matched_at", new Date(Date.now() - 60_000).toISOString()).limit(1).maybeSingle();
        if (!nowPlaying) {
          await sendTo(ctx, creator.tgId, (lang) => ({ text: L(lang, "❌ Заявка отменена.", "❌ So'rov bekor qilindi.") }));
        }
        await sendTo(ctx, prev?.tgId ?? null, (lang) => ({
          text: L(lang, `😕 <b>${esc(creator.name)}</b> отменил игру.`, `😕 <b>${esc(creator.name)}</b> o'yinni bekor qildi.`),
        }));
      }
      await restyleBroadcasts(match, creator, ctx);
      break;
    }
    case "message": {
      const { data: msg } = await sb.from("match_messages").select("sender_customer_id, recipient_customer_id, body")
        .eq("id", ev.message_id ?? "").maybeSingle();
      if (!msg) break;
      const [from, to] = await Promise.all([person(msg.sender_customer_id), person(msg.recipient_customer_id)]);
      await sendTo(ctx, to?.tgId ?? null, (lang) => ({
        text: `💬 <b>${esc(from?.name ?? "Соперник")}</b> ${L(lang, "(соперник)", "(raqib)")}\n\n${esc(msg.body)}`,
        reply_markup: { inline_keyboard: [[
          { text: L(lang, "↩️ Ответить", "↩️ Javob berish"), callback_data: `mtr:${match.id}` },
          { text: L(lang, "📱 Переписка", "📱 Yozishma"), web_app: { url: `${MINI_APP_URL}?c=${encodeURIComponent(ctx.clubId)}&match=1` } },
        ]] },
      }));
      break;
    }
  }
}
