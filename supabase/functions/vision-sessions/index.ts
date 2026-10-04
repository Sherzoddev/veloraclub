// Tables and their running sessions, for the camera service in the club
// ("vision/" in the repo).
//
// The laptop that watches the cameras compares who stands at a table with
// whether the program has a session running there. It needs nothing but this
// list, so it gets it from here instead of holding a database key: it sends
// the club id and a shared secret (the VISION_SECRET function secret, the
// same value as in the laptop's .env) and gets back table names with the
// state of their session. No customers, no money.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VISION_SECRET = Deno.env.get("VISION_SECRET") ?? "";

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

// Same time whatever the characters, so the secret can't be guessed
// byte by byte from response times.
function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (!VISION_SECRET) return json({ error: "VISION_SECRET_NOT_SET" }, 503);
  if (!safeEqual(req.headers.get("x-vision-secret") ?? "", VISION_SECRET)) {
    return json({ error: "UNAUTHORIZED" }, 401);
  }

  let clubId = "";
  try {
    clubId = String((await req.json())?.club_id ?? "");
  } catch (_) {
    return json({ error: "BAD_REQUEST" }, 400);
  }
  if (!UUID.test(clubId)) return json({ error: "BAD_CLUB_ID" }, 400);

  const [resources, sessions] = await Promise.all([
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
  if (resources.error || sessions.error) {
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
