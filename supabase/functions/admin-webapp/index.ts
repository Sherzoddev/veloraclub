// Admin Mini App — opened only from the club's own bot (club-bot) by a
// caller whose role is ADMIN. Deliberately its own edge function with its
// own auth check and its own HTML: it must never be reachable through the
// client Mini App's URL or session, and a bug here must never be able to
// touch the client-facing site.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const client: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

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
  const secretKey = await hmacSha256(new TextEncoder().encode("WebAppData"), botToken);
  const computed = toHex(await hmacSha256(secretKey, dataCheckString));
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

async function sendTelegram(token: string, chatId: number, text: string, extra: Record<string, unknown> = {}): Promise<boolean> {
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", ...extra }),
    });
    return res.ok;
  } catch (_) {
    return false; /* a failed push must not fail the admin action */
  }
}

const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const CLIENT_APP_URL = "https://velora-club-miniapp-production.up.railway.app/";

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
  const bytes = Uint8Array.from(atob(match[2]), (c) => c.charCodeAt(0));
  if (bytes.length > 8 * 1024 * 1024) throw new Error("IMAGE_TOO_LARGE");
  const path = `${clubId}/${prefix}-${crypto.randomUUID()}.${ext}`;
  const { error } = await client.storage.from("club-assets").upload(path, bytes, { contentType, upsert: true });
  if (error) throw error;
  return client.storage.from("club-assets").getPublicUrl(path).data.publicUrl;
}

// GET is unused by real traffic (the Mini App is served from Railway,
// which calls this function only for POST actions) -- Supabase's edge
// functions gateway rewrites an HTML response to text/plain with a
// locked-down CSP, which makes Telegram show raw source instead of
// rendering a WebApp. A redirect avoids that entirely.
const ADMIN_WEB_URL = "https://velora-club-miniapp-production.up.railway.app/admin";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method === "GET") {
    const url = new URL(req.url);
    const club = url.searchParams.get("c");
    return Response.redirect(ADMIN_WEB_URL + (club ? `?c=${encodeURIComponent(club)}` : ""), 302);
  }
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const body = await req.json();
    const action = String(body.action ?? "");
    const clubId = String(body.c ?? "");
    const initData = String(body.initData ?? "");
    const payload = body.payload && typeof body.payload === "object" ? body.payload : {};
    if (!/^[0-9a-f-]{36}$/i.test(clubId)) return json({ error: "BAD_CLUB" }, 400);

    const { data: clubConfig, error: clubError } = await client.rpc("bot_club_by_id", { p_club_id: clubId });
    if (clubError || !clubConfig?.ok) return json({ error: "CLUB_NOT_FOUND" }, 404);

    const verified = await verifyInitData(initData, clubConfig.bot_token);
    if (!verified) return json({ error: "UNAUTHORIZED" }, 401);

    const { data: role } = await client.rpc("admin_webapp_role", { p_club_id: clubId, p_tg_id: verified.tgId });
    if (role !== "ADMIN") return json({ error: "FORBIDDEN" }, 403);

    const zone = String(clubConfig.timezone ?? "Asia/Tashkent");
    const cur = String(clubConfig.currency_suffix ?? "сум");

    if (action === "bootstrap") {
      const [{ count: pendingBookings }, { data: threads }, { data: clubRow }] = await Promise.all([
        client.from("reservations").select("id", { count: "exact", head: true })
          .eq("club_id", clubId).eq("status", "pending"),
        client.rpc("admin_chat_threads", { p_club_id: clubId }),
        client.from("clubs").select("name").eq("id", clubId).single(),
      ]);
      const unreadChats = ((threads ?? []) as any[]).filter((t) => Number(t.unread) > 0).length;
      return json({
        ok: true, role,
        club: { name: clubRow?.data?.name ?? clubConfig.club_name },
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
      return json({ bookings: (data ?? []).map((row: any) => ({
        id: row.id, resource_name: row.resources?.name ?? "Стол",
        when: dayLabel(row.starts_at, zone), customer_name: row.customer_name, customer_phone: row.customer_phone,
      })) });
    }

    if (action === "booking_confirm" || action === "booking_cancel") {
      const id = String(payload.id ?? "");
      const { data: reservation } = await client.from("reservations")
        .select("id,starts_at,customer_id,resource_id").eq("id", id).eq("club_id", clubId).maybeSingle();
      if (!reservation) return json({ error: "NOT_FOUND" }, 404);
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
        EdgeRuntime.waitUntil(sendTelegram(clubConfig.bot_token, Number(customer.telegram_id), text));
      }
      return json({ ok: true });
    }

    if (action === "chat_threads") {
      const { data, error } = await client.rpc("admin_chat_threads", { p_club_id: clubId });
      if (error) throw error;
      return json({ threads: data ?? [] });
    }

    if (action === "chat_thread") {
      const customerId = String(payload.customerId ?? "");
      // Newest 200, oldest first -- ascending with a limit froze long
      // threads at their first messages.
      const [{ data, error }, { data: customer }] = await Promise.all([
        client.from("customer_chat_messages")
          .select("id,sender_type,body,read_at,created_at")
          .eq("club_id", clubId).eq("customer_id", customerId)
          .order("created_at", { ascending: false }).limit(200),
        client.from("customers").select("id,full_name,phone,telegram_id")
          .eq("id", customerId).eq("club_id", clubId).maybeSingle(),
      ]);
      if (error) throw error;
      if (!customer) return json({ error: "NOT_FOUND" }, 404);
      const messages = (data ?? []).reverse();
      if (messages.some((m: any) => m.sender_type === "CLIENT" && !m.read_at)) {
        await client.from("customer_chat_messages").update({ read_at: new Date().toISOString() })
          .eq("club_id", clubId).eq("customer_id", customerId).eq("sender_type", "CLIENT").is("read_at", null);
      }
      return json({
        messages,
        customer: { id: customer.id, name: customer.full_name, phone: customer.phone, hasTelegram: Boolean(customer.telegram_id) },
      });
    }

    if (action === "chat_reply") {
      const customerId = String(payload.customerId ?? "");
      const message = String(payload.message ?? "").trim();
      if (!message || message.length > 1000) return json({ error: "BAD_MESSAGE" }, 400);
      // Scoped to this club: the id comes from the page, and an admin must
      // never be able to message another club's customer.
      const { data: customer } = await client.from("customers").select("telegram_id")
        .eq("id", customerId).eq("club_id", clubId).maybeSingle();
      if (!customer) return json({ error: "NOT_FOUND" }, 404);
      const { data: created, error } = await client.from("customer_chat_messages").insert({
        club_id: clubId, customer_id: customerId, sender_type: "ADMIN",
        sender_telegram_id: verified.tgId, body: message,
      }).select("id,sender_type,body,read_at,created_at").single();
      if (error) throw error;
      // Answering means the client's messages have been seen.
      EdgeRuntime.waitUntil((async () => {
        await client.from("customer_chat_messages").update({ read_at: new Date().toISOString() })
          .eq("club_id", clubId).eq("customer_id", customerId).eq("sender_type", "CLIENT").is("read_at", null);
      })());
      if (customer.telegram_id) {
        // Same push as club-bot-service postAdminMessage: the client answers
        // right in Telegram, or opens the whole thread in the Mini App.
        // In the background, so the admin's bubble lands at once.
        const tgId = Number(customer.telegram_id);
        EdgeRuntime.waitUntil((async () => {
          const { data: state } = await client.from("bot_state").select("language").eq("telegram_id", tgId).maybeSingle();
          const uz = state?.language !== "ru";
          await sendTelegram(clubConfig.bot_token, tgId, `💬 <b>${esc(clubConfig.club_name)}</b>\n\n${esc(message)}`, {
            reply_markup: {
              inline_keyboard: [[
                { text: uz ? "↩️ Javob berish" : "↩️ Ответить", callback_data: "chatc" },
                { text: uz ? "💬 Chatni ochish" : "💬 Открыть чат", web_app: { url: `${CLIENT_APP_URL}?c=${encodeURIComponent(clubId)}&chat=1` } },
              ]],
            },
          });
        })());
      }
      return json({ ok: true, message: created, delivered: Boolean(customer.telegram_id) });
    }

    if (action === "promotions_list") {
      const { data, error } = await client.from("promotions").select("id,title,body,photo_url,active")
        .eq("club_id", clubId).order("sort_order").order("created_at", { ascending: false });
      if (error) throw error;
      return json({ promotions: data ?? [] });
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
        return json({ ok: true, id });
      }
      const title = String(payload.title ?? "").trim().slice(0, 120);
      if (!title) return json({ error: "BAD_TITLE" }, 400);
      const { data, error } = await client.from("promotions").insert({
        club_id: clubId, title, body: String(payload.body ?? "").slice(0, 600) || null, photo_url: photoUrl ?? null,
      }).select("id").single();
      if (error) throw error;
      return json({ ok: true, id: data.id });
    }

    if (action === "promotion_delete") {
      const id = String(payload.id ?? "");
      const { error } = await client.from("promotions").delete().eq("id", id).eq("club_id", clubId);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "resources_list") {
      const { data, error } = await client.from("resources").select("id,name,photo_url")
        .eq("club_id", clubId).eq("active", true).is("archived_at", null).order("sort_order").order("number");
      if (error) throw error;
      return json({ resources: data ?? [] });
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
      if (!updated) return json({ error: "NOT_FOUND" }, 404);
      return json({ ok: true, photoUrl });
    }

    if (action === "settings_get") {
      const { data, error } = await client.from("clubs")
        .select("name,phone,address,work_hours_text,late_note,late_until,bot_welcome_photo_url,timezone")
        .eq("id", clubId).single();
      if (error) throw error;
      const lateActive = Boolean(data.late_until && new Date(data.late_until).getTime() > Date.now());
      return json({ settings: {
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
      return json({ ok: true });
    }

    if (action === "settings_extend") {
      const minutes = Math.max(15, Math.min(360, Number(payload.minutes ?? 60)));
      const lateUntil = new Date(Date.now() + minutes * 60_000).toISOString();
      const note = String(payload.note ?? "").trim().slice(0, 160) || null;
      const { error } = await client.from("clubs").update({ late_until: lateUntil, late_note: note }).eq("id", clubId);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "settings_clear_late") {
      const { error } = await client.from("clubs").update({ late_until: null, late_note: null }).eq("id", clubId);
      if (error) throw error;
      return json({ ok: true });
    }

    if (action === "settings_set_welcome_photo") {
      const photoUrl = await uploadPhoto(clubId, "welcome", String(payload.photoBase64 ?? ""));
      const { error } = await client.from("clubs").update({ bot_welcome_photo_url: photoUrl }).eq("id", clubId);
      if (error) throw error;
      return json({ ok: true, photoUrl });
    }

    return json({ error: "UNKNOWN_ACTION" }, 404);
  } catch (error) {
    console.error("admin-webapp", error);
    return json({ error: "INTERNAL_ERROR" }, 500);
  }
});
