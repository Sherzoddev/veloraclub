// Tables and their running sessions, for the camera program in the club
// ("vision/" in the repo).
//
// The program on the club's computer compares who stands at a table with
// whether a session is running there. The one thing the owner types into it
// is the token of the owner's Telegram bot: it is already a secret that only
// this club has, so it also tells us which club is asking. We answer with
// the club's tables and the state of their sessions, the chat the alerts go
// to and the time zone. No customers, no money.

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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  let token = "";
  try {
    token = String((await req.json())?.bot_token ?? "").trim();
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

  const [club, resources, sessions] = await Promise.all([
    db.from("clubs").select("name,timezone").eq("id", clubId).maybeSingle(),
    db.from("resources")
      .select("id,name,zone,sort_order,number")
      .eq("club_id", clubId)
      .eq("active", true)
      .is("archived_at", null)
      .order("sort_order", { ascending: true })
      .order("number", { ascending: true }),
    db.from("game_sessions")
      .select("resource_id,status,started_at")
      .eq("club_id", clubId)
      .in("status", ["STARTING", "ACTIVE", "PAUSED", "STOPPING"]),
  ]);
  if (club.error || resources.error || sessions.error) {
    return json({ error: "DB_ERROR" }, 500);
  }

  const byResource = new Map<string, { status: string; started_at: string }>();
  for (const s of sessions.data ?? []) {
    byResource.set(s.resource_id as string, {
      status: s.status as string,
      started_at: s.started_at as string,
    });
  }

  return json({
    server_time: new Date().toISOString(),
    club_name: club.data?.name ?? "",
    timezone: club.data?.timezone ?? "Asia/Tashkent",
    owner_chat_id: owner.data.owner_chat_id ?? null,
    resources: (resources.data ?? []).map((r) => {
      const s = byResource.get(r.id as string);
      return {
        id: r.id,
        name: r.name,
        zone: r.zone,
        session_status: s?.status ?? null,
        session_started_at: s?.started_at ?? null,
      };
    }),
  });
});
