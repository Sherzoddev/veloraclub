// "🎬 My shot" for the camera program in the club ("vision/" in the repo).
//
// A client names a table and a time in the club bot. The camera program asks
// here for open requests (clips_poll), cuts the moment out of the camera's own
// recording and hands the video back (clip_done); we send it to the client
// with the club bot. The video is never stored here. The owner's bot token,
// the one secret the program already has, tells which club is asking.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// 123456789:AA... as BotFather hands them out.
const TOKEN = /^\d{6,}:[A-Za-z0-9_-]{30,}$/;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

const norm = (s: string) => s.trim().replace(/\s+/g, " ").toLowerCase();

// "🎬 My shot": the camera program cuts a client's moment out of the camera's
// own recording and hands the video to us, we send it to the client with the
// club bot. The video is never stored here.
const CLIP_MAX_BYTES = 45 * 1024 * 1024; // Telegram's bot limit is 50 MB

const clipText = (lang: string, key: "fail" | "caption", table = "", time = "") => {
  if (key === "caption") {
    return lang === "uz" ? `🎬 Sizning zarbangiz\n🎱 ${table} · ${time}` : `🎬 Ваш удар\n🎱 ${table} · ${time}`;
  }
  return lang === "uz"
    ? "Videoni tayyorlab bo'lmadi 😔 Vaqtni tekshirib, qayta urinib ko'ring."
    : "Не получилось подготовить ролик 😔 Проверьте время и попробуйте ещё раз.";
};

async function clientLang(telegramId: number): Promise<string> {
  const { data } = await db.from("bot_state").select("language").eq("telegram_id", telegramId).maybeSingle();
  return data?.language === "uz" ? "uz" : "ru";
}

async function clubBotToken(clubId: string): Promise<string | null> {
  const { data } = await db.from("club_bots").select("bot_token").eq("club_id", clubId).eq("active", true).limit(1).maybeSingle();
  return (data?.bot_token as string | undefined) ?? null;
}

async function tgText(token: string, chatId: number, text: string) {
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  }).catch(() => {});
}

// Camera program asks for work: which tables it can cut, and gets the open
// requests for them (each handed out once).
async function clipsPoll(clubId: string, tables: string[], timezone: string) {
  const { data: resources } = await db.from("resources").select("id,name").eq("club_id", clubId).eq("active", true);
  const wanted = new Set(tables.map(norm));
  const mine = (resources ?? []).filter((r) => wanted.has(norm(String(r.name))));
  if (mine.length) {
    await db.from("club_clip_tables").upsert(
      mine.map((r) => ({ club_id: clubId, resource_id: r.id, seen_at: new Date().toISOString() })),
      { onConflict: "club_id,resource_id" },
    );
  }
  const ids = mine.map((r) => r.id as string);
  if (!ids.length) return json({ requests: [], timezone });
  const open = await db.from("clip_requests").select("id,resource_id,moment")
    .eq("club_id", clubId).eq("status", "PENDING").in("resource_id", ids)
    .order("created_at", { ascending: true }).limit(3);
  const rows = open.data ?? [];
  if (!rows.length) return json({ requests: [], timezone });
  const taken = await db.from("clip_requests")
    .update({ status: "PROCESSING", updated_at: new Date().toISOString() })
    .in("id", rows.map((r) => r.id as string)).eq("status", "PENDING")
    .select("id,resource_id,moment");
  const nameOf = new Map(mine.map((r) => [r.id as string, String(r.name)]));
  return json({
    timezone,
    requests: (taken.data ?? []).map((r) => ({
      id: r.id, table: nameOf.get(r.resource_id as string) ?? "", moment: r.moment,
    })),
  });
}

async function ownRequest(clubId: string, requestId: string) {
  const { data } = await db.from("clip_requests").select("id,club_id,telegram_id,resource_id,moment,status")
    .eq("id", requestId).eq("club_id", clubId).maybeSingle();
  return data && data.status === "PROCESSING" ? data : null;
}

async function clipFail(clubId: string, requestId: string, reason: string) {
  const r = await ownRequest(clubId, requestId);
  if (!r) return json({ ok: false, error: "NOT_FOUND" }, 404);
  await db.from("clip_requests").update({ status: "FAILED", reason: reason.slice(0, 200), updated_at: new Date().toISOString() }).eq("id", requestId);
  const token = await clubBotToken(clubId);
  if (token) await tgText(token, Number(r.telegram_id), clipText(await clientLang(Number(r.telegram_id)), "fail"));
  return json({ ok: true });
}

async function clipDone(clubId: string, requestId: string, file: File, timezone: string) {
  const r = await ownRequest(clubId, requestId);
  if (!r) return json({ ok: false, error: "NOT_FOUND" }, 404);
  if (file.size < 1000 || file.size > CLIP_MAX_BYTES) return clipFail(clubId, requestId, `BAD_SIZE_${file.size}`);
  const token = await clubBotToken(clubId);
  if (!token) return json({ ok: false, error: "NO_BOT" }, 500);
  const { data: res } = await db.from("resources").select("name").eq("id", r.resource_id).maybeSingle();
  const time = new Intl.DateTimeFormat("ru-RU", { timeZone: timezone, hour: "2-digit", minute: "2-digit" })
    .format(new Date(r.moment as string));
  const lang = await clientLang(Number(r.telegram_id));
  const form = new FormData();
  form.set("chat_id", String(r.telegram_id));
  form.set("caption", clipText(lang, "caption", String(res?.name ?? ""), time));
  form.set("supports_streaming", "true");
  form.set("video", file, "clip.mp4");
  const resp = await fetch(`https://api.telegram.org/bot${token}/sendVideo`, { method: "POST", body: form })
    .catch(() => null);
  const ok = !!resp && resp.status === 200;
  await db.from("clip_requests").update({
    status: ok ? "DONE" : "FAILED", reason: ok ? null : `TELEGRAM_${resp?.status ?? "NET"}`,
    updated_at: new Date().toISOString(),
  }).eq("id", requestId);
  return json({ ok });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  let token = "";
  let body: Record<string, unknown> = {};
  let upload: File | null = null;
  try {
    if ((req.headers.get("content-type") ?? "").includes("multipart/form-data")) {
      const form = await req.formData();
      for (const [k, v] of form.entries()) {
        if (v instanceof File) upload = v;
        else body[k] = v;
      }
    } else {
      body = (await req.json()) ?? {};
    }
    token = String(body?.bot_token ?? "").trim();
  } catch (_) {
    return json({ error: "BAD_REQUEST" }, 400);
  }
  if (!TOKEN.test(token)) return json({ error: "BAD_TOKEN_FORMAT" }, 400);

  const owner = await db
    .from("owner_bots")
    .select("club_id,owner_chat_id,active")
    .eq("bot_token", token)
    .maybeSingle();
  if (owner.error) return json({ error: "DB_ERROR" }, 500);
  if (!owner.data || !owner.data.active) {
    // The cashier/client bot has a token of its own: say so, people mix
    // them up.
    const other = await db.from("club_bots").select("club_id").eq("bot_token", token).maybeSingle();
    return json({ error: other.data ? "NOT_OWNER_BOT" : "UNKNOWN_TOKEN" }, other.data ? 409 : 401);
  }
  const clubId = owner.data.club_id as string;

  const action = String(body.action ?? "");
  const tzRow = await db.from("clubs").select("timezone").eq("id", clubId).maybeSingle();
  const timezone = tzRow.data?.timezone ?? "Asia/Tashkent";
  if (action === "clips_poll") {
    let tables: string[] = [];
    try {
      const raw = typeof body.tables === "string" ? JSON.parse(body.tables) : body.tables;
      if (Array.isArray(raw)) tables = raw.map((t) => String(t)).slice(0, 50);
    } catch (_) { /* no tables */ }
    return clipsPoll(clubId, tables, timezone);
  }
  const requestId = String(body.request_id ?? "");
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!UUID.test(requestId)) return json({ error: "BAD_REQUEST" }, 400);
  if (action === "clip_fail") return clipFail(clubId, requestId, String(body.reason ?? "FAILED"));
  if (action === "clip_done" && upload) return clipDone(clubId, requestId, upload, timezone);
  return json({ error: "BAD_REQUEST" }, 400);
});
