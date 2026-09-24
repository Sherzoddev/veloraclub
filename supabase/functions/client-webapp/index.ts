import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// GET is unused by real traffic (the Mini App is served from Railway, which
// calls this function only for POST actions) — a static redirect avoids
// depending on a bundled HTML file, whose absence would crash the whole
// module at cold start and take POST down with it.
const MINI_APP_URL = "https://velora-club-miniapp-production.up.railway.app/";
const db = (): SupabaseClient => createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
const client = db();
const clubCache = new Map<string, { value: any; expiresAt: number }>();
async function getClubConfig(clubId: string) {
  const cached = clubCache.get(clubId);
  if (cached && cached.expiresAt > Date.now()) return cached.value;
  const { data, error } = await client.rpc("bot_club_by_id", { p_club_id: clubId });
  if (!error && data?.ok) clubCache.set(clubId, { value: data, expiresAt: Date.now() + 60_000 });
  return error ? null : data;
}
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
};
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...CORS },
});

async function hmacSha256(key: Uint8Array, data: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(data)));
}
const toHex = (bytes: Uint8Array) => Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");

// TEMP diagnostics: pinpointing why real Mini App sessions verify as guest.
// Logs only shape/length, never the initData/hash/user content itself.
async function verifyInitData(initData: string, botToken: string): Promise<{ tgId: number; firstName: string } | null> {
  if (!initData) { console.log("[authdiag] empty initData"); return null; }
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) { console.log("[authdiag] no hash param, len=", initData.length); return null; }
  params.delete("hash");
  const authDate = Number(params.get("auth_date") ?? "0");
  if (!authDate || Date.now() / 1000 - authDate > 86400) {
    console.log("[authdiag] stale/missing auth_date", authDate, Date.now() / 1000);
    return null;
  }
  const dataCheckString = [...params.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  const secretKey = await hmacSha256(new TextEncoder().encode("WebAppData"), botToken);
  const computed = toHex(await hmacSha256(secretKey, dataCheckString));
  if (computed.length !== hash.length) {
    console.log("[authdiag] hash length mismatch", computed.length, hash.length);
    return null;
  }
  let different = 0;
  for (let i = 0; i < computed.length; i++) different |= computed.charCodeAt(i) ^ hash.charCodeAt(i);
  if (different !== 0) {
    console.log("[authdiag] hash mismatch, tokenLen=", botToken.length, "paramKeys=", [...params.keys()].join(","));
    return null;
  }
  try {
    const user = JSON.parse(params.get("user") ?? "{}");
    if (!Number.isSafeInteger(Number(user.id))) { console.log("[authdiag] bad user.id"); return null; }
    console.log("[authdiag] verified ok, tgId=", user.id);
    return { tgId: Number(user.id), firstName: String(user.first_name ?? "") };
  } catch {
    console.log("[authdiag] user JSON parse failed");
    return null;
  }
}

function zonedTimeToUtc(y: number, mo: number, d: number, hh: number, mm: number, zone: string): Date {
  const guess = Date.UTC(y, mo - 1, d, hh, mm, 0);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(guess));
  const map = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const readBack = Date.UTC(+map.year, +map.month - 1, +map.day, +map.hour, +map.minute, +map.second);
  return new Date(guess - (readBack - guess));
}

function localDay(zone: string, offset = 0) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date());
  const map = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const noon = new Date(Date.UTC(+map.year, +map.month - 1, +map.day + offset, 12));
  return { y: noon.getUTCFullYear(), mo: noon.getUTCMonth() + 1, d: noon.getUTCDate() };
}

function formatWhen(value: string, zone: string) {
  return new Intl.DateTimeFormat("ru-RU", {
    timeZone: zone, day: "numeric", month: "long", hour: "2-digit", minute: "2-digit",
  }).format(new Date(value));
}

async function sendTelegram(token: string, chatId: number, text: string, extra: Record<string, unknown> = {}) {
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, ...extra }),
    });
  } catch (_) { /* notification failure must not roll back a booking */ }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method === "GET") {
    const url = new URL(req.url);
    const club = url.searchParams.get("c");
    return Response.redirect(MINI_APP_URL + (club ? `?c=${encodeURIComponent(club)}` : ""), 302);
  }
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const body = await req.json();
    const action = String(body.action ?? "");
    const clubId = String(body.c ?? "");
    const initData = String(body.initData ?? "");
    const payload = body.payload && typeof body.payload === "object" ? body.payload : {};
    if (!/^[0-9a-f-]{36}$/i.test(clubId)) return json({ error: "BAD_CLUB" }, 400);

    const clubConfig = await getClubConfig(clubId);
    if (!clubConfig?.ok) return json({ error: "CLUB_NOT_FOUND" }, 404);
    const verified = await verifyInitData(initData, clubConfig.bot_token);
    const publicActions = new Set(["bootstrap", "resources", "availability"]);
    if (!verified && !publicActions.has(action)) return json({ error: "UNAUTHORIZED" }, 401);
    const tgId = verified?.tgId ?? 0;
    const firstName = verified?.firstName ?? "Гость";
    const zone = String(clubConfig.timezone ?? "Asia/Tashkent");

    const playerCard = async () => {
      if (!verified) return null;
      const { data, error } = await client.rpc("bot_player_card", { p_club_id: clubId, p_tg_id: tgId });
      if (error) throw error;
      return data?.ok ? data : null;
    };

    if (action === "bootstrap" || action === "me") {
      const [card, clubResult, botResult, shiftResult, tiersResult, termsResult] = await Promise.all([
        playerCard(),
        client.from("clubs").select("id,name,phone,address,bot_welcome_photo_url,timezone").eq("id", clubId).single(),
        client.from("club_bots").select("bot_username").eq("club_id", clubId).eq("active", true).limit(1).maybeSingle(),
        // Not cached alongside clubConfig — a closed shift must stop showing
        // the club as open right away, not up to 60s later.
        client.from("cash_shifts").select("id").eq("club_id", clubId).eq("status", "OPEN").limit(1).maybeSingle(),
        client.from("loyalty_tiers").select("name,min_total_spent,earn_percent,discount_percent,color")
          .eq("club_id", clubId).eq("active", true).order("sort_order"),
        // Same acceptance flag the bot itself gates on -- a client reaching
        // the Mini App straight from an old cached "Open app" button (never
        // touching the bot's own message handler) must still be blocked.
        verified
          ? client.from("club_bot_users").select("terms_accepted_at")
              .eq("club_id", clubId).eq("telegram_id", verified.tgId).maybeSingle()
          : Promise.resolve({ data: null }),
      ]);
      const lateUntilActive = clubConfig.late_until && new Date(clubConfig.late_until).getTime() > Date.now();
      // bot_player_card now returns the active reservation inline (see
      // bot_perf_and_referral_notify migration) — this used to be a second,
      // sequential round trip, which is expensive given the project's
      // DB region is far from its users.
      const activeReservation = card?.active_reservation ?? null;
      const levelUp = Boolean(card?.tier_id && card?.level_seen_tier_id && card.tier_id !== card.level_seen_tier_id);
      return json({
        authenticated: Boolean(verified),
        telegramName: firstName,
        club: {
          name: clubResult.data?.name ?? clubConfig.club_name,
          phone: clubResult.data?.phone,
          address: clubResult.data?.address,
          photo: clubResult.data?.bot_welcome_photo_url,
          hours: clubConfig.work_hours_text || "10:00 — 02:00",
          botUsername: botResult.data?.bot_username,
          hasPlaystation: clubConfig.has_playstation !== false,
          hasBilliard: clubConfig.has_billiard !== false,
          isOpen: Boolean(shiftResult.data),
          lateNote: lateUntilActive ? clubConfig.late_note : null,
          loyaltyTiers: tiersResult.data ?? [],
        },
        me: card ? { ...card, hasCard: true } : { hasCard: false, name: firstName },
        activeReservation,
        levelUp,
        termsAccepted: Boolean(termsResult.data?.terms_accepted_at),
      });
    }

    if (action === "accept_terms") {
      if (!verified) return json({ error: "UNAUTHORIZED" }, 401);
      const { data: updated, error } = await client.from("club_bot_users")
        .update({ terms_accepted_at: new Date().toISOString() })
        .eq("club_id", clubId).eq("telegram_id", verified.tgId)
        .select("telegram_id").maybeSingle();
      if (error) throw error;
      // No row yet means this tgId reached the Mini App without ever
      // messaging the bot -- insert one instead of leaving them stuck
      // accepting forever with nothing to record it against.
      if (!updated) {
        const { error: insertError } = await client.from("club_bot_users").insert({
          club_id: clubId, telegram_id: verified.tgId, role: "CLIENT",
          full_name: firstName || null, terms_accepted_at: new Date().toISOString(),
        });
        if (insertError) throw insertError;
      }
      return json({ ok: true });
    }

    if (action === "resources") {
      // One RPC instead of a resources query + a follow-up sessions query —
      // each round trip to the DB is costly given the project's region.
      const { data, error } = await client.rpc("bot_resources_with_status", { p_club_id: clubId });
      if (error) throw error;
      const now = Date.now();
      return json({ resources: ((data ?? []) as any[]).map((row: any) => {
        const hasSession = Boolean(row.session_status);
        const available = row.session_planned_end_at ? Math.max(1, Math.ceil((new Date(row.session_planned_end_at).getTime() - now) / 60000)) : null;
        const playingMinutes = row.session_started_at ? Math.max(0, Math.floor((now - new Date(row.session_started_at).getTime()) / 60000)) : null;
        const isVip = /(^|\s)vip($|\s)/i.test([row.name, row.type_name, row.zone, row.notes].filter(Boolean).join(" "));
        return {
          id: row.id, name: row.name, number: row.number, photo_url: row.photo_url,
          status: hasSession ? "BUSY" : row.status, is_free: !hasSession && row.status === "FREE", type_name: row.type_name,
          family: row.family ?? "BILLIARD", family_label: row.type_name,
          price_per_hour: row.price_per_hour ?? 0, available_in_minutes: available,
          playing_minutes: playingMinutes, is_vip: isVip,
        };
      }) });
    }

    if (action === "availability") {
      const resourceId = String(payload.resourceId ?? "");
      const dayOffset = Math.max(0, Math.min(14, Number(payload.dayOffset ?? 0)));
      const duration = Math.max(30, Math.min(600, Math.round(Number(payload.minutes ?? 60) / 30) * 30));
      const day = localDay(zone, dayOffset);
      const from = zonedTimeToUtc(day.y, day.mo, day.d, 0, 0, zone);
      const next = localDay(zone, dayOffset + 1);
      const until = zonedTimeToUtc(next.y, next.mo, next.d, 2, 0, zone);
      // Resource-exists guard + reservations + live sessions used to be three
      // sequential round trips; now it's one RPC.
      const { data: busy, error } = await client.rpc("bot_resource_busy_ranges", {
        p_club_id: clubId, p_resource_id: resourceId, p_from: from.toISOString(), p_until: until.toISOString(),
      });
      if (error) throw error;
      if (!busy?.ok) return json({ error: "NO_RESOURCE" }, 404);
      const ranges = ((busy.ranges ?? []) as any[]).map((row: any) => [new Date(row.starts_at).getTime(), new Date(row.ends_at).getTime()]);
      const slots = [];
      for (let startMinute = 10 * 60; startMinute <= 23 * 60; startMinute += 60) {
        if (startMinute + duration > 26 * 60) continue;
        const hour = Math.floor(startMinute / 60);
        const minute = startMinute % 60;
        const start = zonedTimeToUtc(day.y, day.mo, day.d, hour, minute, zone);
        const end = new Date(start.getTime() + duration * 60_000);
        const available = start.getTime() >= Date.now() + 5 * 60000 && !ranges.some(([a, b]) => start.getTime() < b && end.getTime() > a);
        slots.push({ time: `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`, available });
      }
      return json({ slots });
    }

    if (action === "book") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED", reason: "CONTACT_REQUIRED" }, 409);
      const dayOffset = Math.max(0, Math.min(14, Number(payload.dayOffset ?? 0)));
      const hour = Number(payload.hh);
      const minute = Number(payload.mm ?? 0);
      const duration = Math.max(30, Math.min(600, Math.round(Number(payload.minutes ?? 60) / 30) * 30));
      if (!Number.isInteger(hour) || hour < 0 || hour > 23 || !Number.isInteger(minute) || minute < 0 || minute > 59) {
        return json({ error: "BAD_TIME" }, 400);
      }
      const day = localDay(zone, dayOffset);
      const startsAt = zonedTimeToUtc(day.y, day.mo, day.d, hour, minute, zone).toISOString();
      const { data, error } = await client.rpc("bot_create_reservation", {
        p_club_id: clubId, p_tg_id: tgId, p_resource_id: String(payload.resourceId ?? ""),
        p_starts_at: startsAt, p_minutes: duration, p_name: card.name ?? firstName, p_phone: card.phone ?? null,
      });
      if (error) throw error;
      if (!data?.ok) return json({ error: "BOOK_FAILED", reason: data?.reason ?? "UNKNOWN" }, 409);
      // Same admin-side reach and buttons as a bot-made booking (club-bot's
      // finishBooking) -- this used to be a single plain-text ping to just
      // the owner, with no way to confirm/cancel/message the client without
      // leaving the chat.
      const { data: admins } = await client.rpc("bot_admin_chats", { p_club_id: clubId });
      for (const admin of (admins ?? []) as number[]) {
        EdgeRuntime.waitUntil(sendTelegram(clubConfig.bot_token, admin,
          `<b>Новая бронь из Mini App</b>\n\n${data.resource_name} · ${formatWhen(data.starts_at, zone)}\n` +
            `${data.customer_name ?? firstName}${data.customer_phone ? ` · ${data.customer_phone}` : ""}`,
          {
            parse_mode: "HTML",
            reply_markup: {
              inline_keyboard: [
                [{ text: "✅ Подтвердить", callback_data: `rconf:${data.reservation_id}` }],
                [{ text: "❌ Отменить", callback_data: `cancelres:${data.reservation_id}` }],
                [{ text: "✉ Написать клиенту", callback_data: `rcli:${data.reservation_id}` }],
              ],
            },
          }));
      }
      return json({ ok: true, id: data.reservation_id, resourceName: data.resource_name, when: formatWhen(data.starts_at, zone) });
    }

    if (action === "reservations") {
      const card = await playerCard();
      if (!card) return json({ reservations: [] });
      const { data, error } = await client.from("reservations")
        .select("id,starts_at,ends_at,status,created_at,resources!reservations_resource_id_fkey(name)")
        .eq("club_id", clubId).eq("customer_id", card.id).order("starts_at", { ascending: false }).limit(50);
      if (error) throw error;
      return json({ reservations: (data ?? []).map((row: any) => ({ ...row, resource_name: row.resources?.name ?? "Стол", resources: undefined })) });
    }

    if (action === "referrals") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED" }, 409);
      const { data, error } = await client.from("customer_referrals")
        .select("status,reward_amount")
        .eq("club_id", clubId).eq("referrer_customer_id", card.id);
      if (error) throw error;
      const rows = data ?? [];
      return json({
        invited: rows.length,
        rewarded: rows.filter((row: any) => row.status === "REWARDED").length,
        totalBonus: rows.reduce((sum: number, row: any) => sum + Number(row.reward_amount ?? 0), 0),
      });
    }

    if (action === "chat_messages") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED" }, 409);
      const { data, error } = await client.from("customer_chat_messages")
        .select("id,sender_type,body,read_at,created_at")
        .eq("club_id", clubId).eq("customer_id", card.id)
        .order("created_at", { ascending: true }).limit(100);
      if (error) throw error;
      await client.from("customer_chat_messages").update({ read_at: new Date().toISOString() })
        .eq("club_id", clubId).eq("customer_id", card.id)
        .eq("sender_type", "ADMIN").is("read_at", null);
      return json({ messages: data ?? [] });
    }

    if (action === "send_chat_message") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED" }, 409);
      const message = String(payload.message ?? "").trim();
      if (!message || message.length > 1000) return json({ error: "BAD_MESSAGE" }, 400);
      const { data: created, error } = await client.from("customer_chat_messages").insert({
        club_id: clubId, customer_id: card.id, sender_type: "CLIENT",
        sender_telegram_id: tgId, body: message,
      }).select("id,sender_type,body,read_at,created_at").single();
      if (error) throw error;
      const { data: admins } = await client.rpc("bot_admin_chats", { p_club_id: clubId });
      for (const admin of (admins ?? []) as number[]) {
        EdgeRuntime.waitUntil(sendTelegram(
          clubConfig.bot_token, admin,
          `💬 Сообщение из Mini App\n${card.name ?? firstName}\n\n${message}`,
          { reply_markup: { inline_keyboard: [[{ text: "✉ Ответить", callback_data: `chatreply:${card.id}` }]] } },
        ));
      }
      return json({ ok: true, message: created });
    }

    if (action === "cancel_reservation") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED" }, 409);
      const id = String(payload.id ?? "");
      const { data: reservation } = await client.from("reservations")
        .select("id,starts_at,status").eq("id", id).eq("club_id", clubId).eq("customer_id", card.id).maybeSingle();
      if (!reservation || !["pending", "confirmed"].includes(reservation.status)) return json({ error: "NOT_CANCELLABLE" }, 409);
      if (new Date(reservation.starts_at).getTime() - Date.now() < 30 * 60000) return json({ error: "TOO_LATE" }, 409);
      const { error } = await client.from("reservations").update({ status: "cancelled" }).eq("id", id)
        .eq("club_id", clubId).eq("customer_id", card.id).in("status", ["pending", "confirmed"]);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "history") {
      const card = await playerCard();
      if (!card) return json({ history: [] });
      const { data, error } = await client.from("orders")
        .select("id,total_amount,closed_at,created_at,game_sessions!orders_session_id_fkey(started_at,resources!game_sessions_resource_id_fkey(name))")
        .eq("club_id", clubId).eq("customer_id", card.id).eq("status", "COMPLETED")
        .order("closed_at", { ascending: false }).limit(50);
      if (error) throw error;
      return json({ history: (data ?? []).map((row: any) => ({
        id: row.id, amount: row.total_amount, created_at: row.closed_at ?? row.created_at,
        started_at: row.game_sessions?.started_at, resource_name: row.game_sessions?.resources?.name ?? "Посещение",
      })) });
    }

    if (action === "notifications") {
      const card = await playerCard();
      if (!card) return json({ notifications: [] });
      const notifications: any[] = [];
      const { data: upcoming } = await client.from("reservations")
        .select("starts_at,status,resources!reservations_resource_id_fkey(name)")
        .eq("club_id", clubId).eq("customer_id", card.id).in("status", ["pending", "confirmed"])
        .gte("starts_at", new Date().toISOString()).order("starts_at").limit(10);
      for (const row of upcoming ?? []) notifications.push({
        icon: row.status === "confirmed" ? "circle-check" : "bell", title: row.status === "confirmed" ? "Бронь подтверждена" : "Бронь ожидает подтверждения",
        body: `${row.resources?.name ?? "Стол"}, ${formatWhen(row.starts_at, zone)}`,
      });
      const { data: logs } = await client.from("audit_logs").select("action,metadata,created_at")
        .eq("club_id", clubId).eq("entity_type", "customer").eq("entity_id", card.id)
        .in("action", ["customer.points_earned", "customer.tier_changed", "customer.referral_reward"]).order("created_at", { ascending: false }).limit(10);
      for (const row of logs ?? []) notifications.push({
        icon: row.action.includes("referral") ? "user-plus" : row.action.includes("points") ? "coins" : "trophy",
        title: row.action.includes("referral") ? "Бонус за друга" : row.action.includes("points") ? "Начислены бонусы" : "Новый уровень",
        body: row.action.includes("referral") ? `+${row.metadata?.points ?? 0} бонусов за первый чек друга` : row.action.includes("points") ? `+${row.metadata?.points ?? row.metadata?.bonus_points ?? 0} бонусов` : String(row.metadata?.tier_name ?? card.tier),
        time: new Intl.DateTimeFormat("ru-RU", { timeZone: zone, day: "2-digit", month: "2-digit" }).format(new Date(row.created_at)),
      });
      return json({ notifications });
    }

    if (action === "ack_level") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED" }, 409);
      const { error } = await client.from("customers").update({ level_seen_tier_id: card.tier_id })
        .eq("id", card.id).eq("club_id", clubId).eq("telegram_id", tgId);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "waitlist") {
      const card = await playerCard();
      if (!card) return json({ error: "CONTACT_REQUIRED" }, 409);
      const family = ["BILLIARD", "PLAYSTATION"].includes(String(payload.family)) ? String(payload.family) : "BILLIARD";
      const { data: current } = await client.from("waitlist_entries").select("id")
        .eq("club_id", clubId).eq("customer_id", card.id).eq("resource_family", family).eq("status", "WAITING").maybeSingle();
      if (current) return json({ ok: true, id: current.id, existing: true });
      const { data, error } = await client.from("waitlist_entries").insert({
        club_id: clubId, customer_id: card.id, customer_name: card.name, phone: card.phone,
        resource_family: family, status: "WAITING",
      }).select("id").single();
      if (error) throw error;
      return json({ ok: true, id: data.id });
    }

    if (action === "setlang") return json({ ok: true, language: "ru" });
    return json({ error: "UNKNOWN_ACTION" }, 404);
  } catch (error) {
    console.error("client-webapp", error);
    return json({ error: "INTERNAL_ERROR" }, 500);
  }
});
