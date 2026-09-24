// Admin Mini App backend — ported from the Supabase Edge Function
// (supabase/functions/admin-webapp) to a persistent Node/Express service,
// the same move already made for club-bot: a Deno edge function pays a
// cold-start tax plus a round trip to Sydney on every call (measured at
// 1.2-3.1s per action here), while a warm Node process on Railway answers
// in well under a second. Business logic is preserved verbatim; only the
// Deno-specific APIs are swapped for their Node/Express equivalents.
import "dotenv/config";
import express from "express";
import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { createHmac, randomUUID } from "node:crypto";

const SUPABASE_URL = process.env.SUPABASE_URL!;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const client: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

function hmacSha256(key: Buffer | string, data: string): Buffer {
  return createHmac("sha256", key).update(data).digest();
}

async function verifyInitData(initData: string, botToken: string): Promise<{ tgId: number; firstName: string } | null> {
  if (!initData) return null;
  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return null;
  params.delete("hash");
  const authDate = Number(params.get("auth_date") ?? "0");
  if (!authDate || Date.now() / 1000 - authDate > 86400) return null;
  const dataCheckString = [...params.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  const secretKey = hmacSha256("WebAppData", botToken);
  const computed = hmacSha256(secretKey, dataCheckString).toString("hex");
  if (computed.length !== hash.length) return null;
  let different = 0;
  for (let i = 0; i < computed.length; i++) different |= computed.charCodeAt(i) ^ hash.charCodeAt(i);
  if (different !== 0) return null;
  try {
    const user = JSON.parse(params.get("user") ?? "{}");
    if (!Number.isSafeInteger(Number(user.id))) return null;
    return { tgId: Number(user.id), firstName: String(user.first_name ?? "") };
  } catch {
    return null;
  }
}

async function sendTelegram(token: string, chatId: number, text: string) {
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML" }),
    });
  } catch (_) { /* a failed push must not fail the admin action */ }
}

function dayLabel(iso: string, zone: string) {
  return new Intl.DateTimeFormat("ru-RU", { timeZone: zone, day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" })
    .format(new Date(iso));
}

const EXT_BY_TYPE: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
async function uploadPhoto(clubId: string, prefix: string, dataUrl: string): Promise<string> {
  const match = /^data:(image\/(?:jpeg|png|webp));base64,(.+)$/.exec(dataUrl);
  if (!match) throw new Error("BAD_IMAGE");
  const contentType = match[1];
  const ext = EXT_BY_TYPE[contentType] ?? "jpg";
  const bytes = Buffer.from(match[2], "base64");
  if (bytes.length > 8 * 1024 * 1024) throw new Error("IMAGE_TOO_LARGE");
  const path = `${clubId}/${prefix}-${randomUUID()}.${ext}`;
  const { error } = await client.storage.from("club-assets").upload(path, bytes, { contentType, upsert: true });
  if (error) throw error;
  return client.storage.from("club-assets").getPublicUrl(path).data.publicUrl;
}

// The Mini App itself is served from Railway (velora-club-miniapp); this
// service only answers POST actions. A GET here only ever happens from a
// stray link, so just send it to the real page.
const ADMIN_WEB_URL = "https://velora-club-miniapp-production.up.railway.app/admin";

const app = express();
app.use(express.json({ limit: "2mb" }));
// A malformed body must fall back to "bad request", matching the old Deno
// handler's req.json().catch(...) instead of Express's default error page.
app.use((err: any, _req: express.Request, res: express.Response, next: express.NextFunction) => {
  if (err?.type === "entity.parse.failed") return res.status(400).send("bad request");
  next(err);
});
app.use((_req, res, next) => {
  res.set({
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
  });
  next();
});
app.options("*", (_req, res) => res.status(204).end());

app.get("/", (req, res) => {
  const club = typeof req.query.c === "string" ? req.query.c : "";
  res.redirect(302, ADMIN_WEB_URL + (club ? `?c=${encodeURIComponent(club)}` : ""));
});

app.post("/", async (req, res) => {
  res.set("Cache-Control", "no-store");
  try {
    const body = req.body ?? {};
    const action = String(body.action ?? "");
    const clubId = String(body.c ?? "");
    const initData = String(body.initData ?? "");
    const payload = body.payload && typeof body.payload === "object" ? body.payload : {};
    if (!/^[0-9a-f-]{36}$/i.test(clubId)) return res.status(400).json({ error: "BAD_CLUB" });

    const { data: clubConfig, error: clubError } = await client.rpc("bot_club_by_id", { p_club_id: clubId });
    if (clubError || !clubConfig?.ok) return res.status(404).json({ error: "CLUB_NOT_FOUND" });

    const verified = await verifyInitData(initData, clubConfig.bot_token);
    if (!verified) return res.status(401).json({ error: "UNAUTHORIZED" });

    const { data: role } = await client.rpc("admin_webapp_role", { p_club_id: clubId, p_tg_id: verified.tgId });
    if (role !== "ADMIN") return res.status(403).json({ error: "FORBIDDEN" });

    const zone = String(clubConfig.timezone ?? "Asia/Tashkent");

    if (action === "bootstrap") {
      const [{ count: pendingBookings }, { data: threads }, { data: clubRow }] = await Promise.all([
        client.from("reservations").select("id", { count: "exact", head: true })
          .eq("club_id", clubId).eq("status", "pending"),
        client.rpc("admin_chat_threads", { p_club_id: clubId }),
        client.from("clubs").select("name").eq("id", clubId).single(),
      ]);
      const unreadChats = ((threads ?? []) as any[]).filter((t) => Number(t.unread) > 0).length;
      return res.json({
        ok: true, role,
        club: { name: clubRow?.name ?? clubConfig.club_name },
        counts: { pendingBookings: pendingBookings ?? 0, unreadChats },
      });
    }

    if (action === "bookings_pending") {
      const { data, error } = await client.from("reservations")
        .select("id,starts_at,customer_name,customer_phone,resources!reservations_resource_id_fkey(name)")
        .eq("club_id", clubId).eq("status", "pending")
        .gte("starts_at", new Date(Date.now() - 3600_000).toISOString())
        .order("starts_at").limit(50);
      if (error) throw error;
      return res.json({ bookings: (data ?? []).map((row: any) => ({
        id: row.id, resource_name: row.resources?.name ?? "Стол",
        when: dayLabel(row.starts_at, zone), customer_name: row.customer_name, customer_phone: row.customer_phone,
      })) });
    }

    if (action === "booking_confirm" || action === "booking_cancel") {
      const id = String(payload.id ?? "");
      const { data: reservation } = await client.from("reservations")
        .select("id,starts_at,customer_id,resource_id").eq("id", id).eq("club_id", clubId).maybeSingle();
      if (!reservation) return res.status(404).json({ error: "NOT_FOUND" });
      const status = action === "booking_confirm" ? "confirmed" : "cancelled";
      const { error } = await client.from("reservations").update({ status }).eq("id", id).eq("club_id", clubId);
      if (error) throw error;
      const [{ data: customer }, { data: resource }] = await Promise.all([
        reservation.customer_id
          ? client.from("customers").select("telegram_id").eq("id", reservation.customer_id).maybeSingle()
          : Promise.resolve({ data: null }),
        client.from("resources").select("name").eq("id", reservation.resource_id).maybeSingle(),
      ]);
      if (customer?.telegram_id) {
        const text = action === "booking_confirm"
          ? `<b>Бронь подтверждена</b>\n\n${resource?.name ?? "Стол"} · ${dayLabel(reservation.starts_at, zone)}\n\nЖдём вас!`
          : `<b>Бронь отменена клубом</b>\n\n${resource?.name ?? "Стол"} · ${dayLabel(reservation.starts_at, zone)}`;
        void sendTelegram(clubConfig.bot_token, Number(customer.telegram_id), text);
      }
      return res.json({ ok: true });
    }

    if (action === "chat_threads") {
      const { data, error } = await client.rpc("admin_chat_threads", { p_club_id: clubId });
      if (error) throw error;
      return res.json({ threads: data ?? [] });
    }

    if (action === "chat_thread") {
      const customerId = String(payload.customerId ?? "");
      const { data, error } = await client.from("customer_chat_messages")
        .select("id,sender_type,body,created_at")
        .eq("club_id", clubId).eq("customer_id", customerId)
        .order("created_at", { ascending: true }).limit(200);
      if (error) throw error;
      await client.from("customer_chat_messages").update({ read_at: new Date().toISOString() })
        .eq("club_id", clubId).eq("customer_id", customerId).eq("sender_type", "CLIENT").is("read_at", null);
      return res.json({ messages: data ?? [] });
    }

    if (action === "chat_reply") {
      const customerId = String(payload.customerId ?? "");
      const message = String(payload.message ?? "").trim();
      if (!message || message.length > 1000) return res.status(400).json({ error: "BAD_MESSAGE" });
      const { data: created, error } = await client.from("customer_chat_messages").insert({
        club_id: clubId, customer_id: customerId, sender_type: "ADMIN",
        sender_telegram_id: verified.tgId, body: message,
      }).select("id,sender_type,body,created_at").single();
      if (error) throw error;
      const { data: customer } = await client.from("customers").select("telegram_id").eq("id", customerId).maybeSingle();
      if (customer?.telegram_id) {
        void sendTelegram(clubConfig.bot_token, Number(customer.telegram_id), `💬 <b>Ответ клуба</b>\n\n${message}`);
      }
      return res.json({ ok: true, message: created });
    }

    if (action === "promotions_list") {
      const { data, error } = await client.from("promotions").select("id,title,body,photo_url,active")
        .eq("club_id", clubId).order("sort_order").order("created_at", { ascending: false });
      if (error) throw error;
      return res.json({ promotions: data ?? [] });
    }

    if (action === "promotion_save") {
      const id = payload.id ? String(payload.id) : null;
      let photoUrl: string | undefined;
      if (payload.photoBase64) photoUrl = await uploadPhoto(clubId, "promo", String(payload.photoBase64));
      if (id) {
        const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
        if (payload.title !== undefined) patch.title = String(payload.title).slice(0, 120);
        if (payload.body !== undefined) patch.body = String(payload.body).slice(0, 600);
        if (payload.active !== undefined) patch.active = Boolean(payload.active);
        if (photoUrl) patch.photo_url = photoUrl;
        const { error } = await client.from("promotions").update(patch).eq("id", id).eq("club_id", clubId);
        if (error) throw error;
        return res.json({ ok: true, id });
      }
      const title = String(payload.title ?? "").trim().slice(0, 120);
      if (!title) return res.status(400).json({ error: "BAD_TITLE" });
      const { data, error } = await client.from("promotions").insert({
        club_id: clubId, title, body: String(payload.body ?? "").slice(0, 600) || null, photo_url: photoUrl ?? null,
      }).select("id").single();
      if (error) throw error;
      return res.json({ ok: true, id: data.id });
    }

    if (action === "promotion_delete") {
      const id = String(payload.id ?? "");
      const { error } = await client.from("promotions").delete().eq("id", id).eq("club_id", clubId);
      if (error) throw error;
      return res.json({ ok: true });
    }

    if (action === "resources_list") {
      const { data, error } = await client.from("resources").select("id,name,photo_url")
        .eq("club_id", clubId).eq("active", true).is("archived_at", null).order("sort_order").order("number");
      if (error) throw error;
      return res.json({ resources: data ?? [] });
    }

    if (action === "resource_set_photo") {
      const id = String(payload.id ?? "");
      const photoUrl = await uploadPhoto(clubId, "resource", String(payload.photoBase64 ?? ""));
      const { data: updated, error } = await client.from("resources")
        .update({ photo_url: photoUrl }).eq("id", id).eq("club_id", clubId)
        .select("id").maybeSingle();
      if (error) throw error;
      // An id that doesn't belong to this club (or doesn't exist) matches no
      // row -- Postgres reports that as success with zero rows affected, so
      // without this check the admin would see "photo updated" even though
      // nothing changed.
      if (!updated) return res.status(404).json({ error: "NOT_FOUND" });
      return res.json({ ok: true, photoUrl });
    }

    if (action === "settings_get") {
      const { data, error } = await client.from("clubs")
        .select("name,phone,address,work_hours_text,late_note,late_until,bot_welcome_photo_url,timezone")
        .eq("id", clubId).single();
      if (error) throw error;
      const lateActive = Boolean(data.late_until && new Date(data.late_until).getTime() > Date.now());
      return res.json({ settings: {
        name: data.name, phone: data.phone, address: data.address, workHoursText: data.work_hours_text,
        lateNote: data.late_note, lateActive,
        lateUntilLabel: lateActive ? dayLabel(data.late_until, data.timezone ?? zone) : null,
        welcomePhoto: data.bot_welcome_photo_url,
      } });
    }

    if (action === "settings_update") {
      const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (payload.name !== undefined && String(payload.name).trim()) patch.name = String(payload.name).trim().slice(0, 120);
      if (payload.phone !== undefined) patch.phone = String(payload.phone).trim().slice(0, 40) || null;
      if (payload.address !== undefined) patch.address = String(payload.address).trim().slice(0, 240) || null;
      if (payload.workHoursText !== undefined) patch.work_hours_text = String(payload.workHoursText).trim().slice(0, 60) || null;
      const { error } = await client.from("clubs").update(patch).eq("id", clubId);
      if (error) throw error;
      return res.json({ ok: true });
    }

    if (action === "settings_extend") {
      const minutes = Math.max(15, Math.min(360, Number(payload.minutes ?? 60)));
      const lateUntil = new Date(Date.now() + minutes * 60_000).toISOString();
      const note = String(payload.note ?? "").trim().slice(0, 160) || null;
      const { error } = await client.from("clubs").update({ late_until: lateUntil, late_note: note }).eq("id", clubId);
      if (error) throw error;
      return res.json({ ok: true });
    }

    if (action === "settings_clear_late") {
      const { error } = await client.from("clubs").update({ late_until: null, late_note: null }).eq("id", clubId);
      if (error) throw error;
      return res.json({ ok: true });
    }

    if (action === "settings_set_welcome_photo") {
      const photoUrl = await uploadPhoto(clubId, "welcome", String(payload.photoBase64 ?? ""));
      const { error } = await client.from("clubs").update({ bot_welcome_photo_url: photoUrl }).eq("id", clubId);
      if (error) throw error;
      return res.json({ ok: true, photoUrl });
    }

    return res.status(404).json({ error: "UNKNOWN_ACTION" });
  } catch (error) {
    console.error("admin-webapp", error);
    return res.status(500).json({ error: "INTERNAL_ERROR" });
  }
});

const PORT = Number(process.env.PORT ?? 8787);
app.listen(PORT, () => {
  console.log(`admin-webapp-service слушает порт ${PORT}`);
});
