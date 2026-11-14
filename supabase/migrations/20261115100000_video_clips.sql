-- "🎬 Мой удар": a client names a table and the time of his shot in the club
-- bot; Velora Vision (the camera program on the club's computer) cuts that
-- moment out of the camera's own recording and the bot sends it to the client.
-- Nothing is stored here but the request: the video goes straight to Telegram.

create table if not exists public.clip_requests (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null,
  telegram_id bigint not null,
  resource_id uuid not null,
  moment timestamptz not null,
  status text not null default 'PENDING'
    check (status in ('PENDING', 'PROCESSING', 'DONE', 'FAILED', 'EXPIRED')),
  reason text,
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists clip_requests_club_status_idx on public.clip_requests (club_id, status, created_at);
create index if not exists clip_requests_client_idx on public.clip_requests (club_id, telegram_id, created_at desc);

-- Tables that the camera program can cut right now: it reports them on every
-- poll, so a switched-off computer makes the bot's button go away by itself.
create table if not exists public.club_clip_tables (
  club_id uuid not null,
  resource_id uuid not null,
  seen_at timestamptz not null default now(),
  primary key (club_id, resource_id)
);

alter table public.clip_requests enable row level security;
alter table public.club_clip_tables enable row level security;

-- Tables a client can pick (the camera program was heard from lately).
create or replace function public.bot_clip_tables(p_club_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.sort_order, r.number), '[]'::jsonb)
    from club_clip_tables t
    join resources r on r.id = t.resource_id and r.club_id = t.club_id and r.active
   where t.club_id = p_club_id and t.seen_at > now() - interval '10 minutes';
$$;

-- A request. The moment must be inside what the camera still keeps (3 days),
-- already over (the clip shows 20 s after it) and fall in a running or ended
-- session at that table, so nobody asks for footage of an empty hall.
create or replace function public.bot_clip_request(
  p_club_id uuid, p_tg_id bigint, p_resource_id uuid, p_moment timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not exists (
    select 1 from club_clip_tables
     where club_id = p_club_id and resource_id = p_resource_id and seen_at > now() - interval '10 minutes'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_AVAILABLE');
  end if;
  if p_moment > now() - interval '40 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'TOO_FRESH');
  end if;
  if p_moment < now() - interval '72 hours' then
    return jsonb_build_object('ok', false, 'reason', 'TOO_OLD');
  end if;
  if not exists (
    select 1 from game_sessions g
     where g.club_id = p_club_id and g.resource_id = p_resource_id and g.status <> 'CANCELLED'
       and g.started_at <= p_moment + interval '60 seconds'
       and coalesce(g.ended_at, now()) >= p_moment - interval '60 seconds'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'NO_SESSION');
  end if;
  if exists (
    select 1 from clip_requests
     where club_id = p_club_id and telegram_id = p_tg_id and status in ('PENDING', 'PROCESSING')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'BUSY');
  end if;
  if (select count(*) from clip_requests
       where club_id = p_club_id and telegram_id = p_tg_id and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'LIMIT');
  end if;
  insert into clip_requests (club_id, telegram_id, resource_id, moment)
  values (p_club_id, p_tg_id, p_resource_id, p_moment) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Requests that nobody picked up (the computer is off): tell the client and
-- close them. Runs every minute.
create or replace function public.clip_sweep()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_token text;
  v_lang text;
  v_n integer := 0;
begin
  update clip_requests set status = 'PENDING', attempts = attempts + 1, updated_at = now()
   where status = 'PROCESSING' and updated_at < now() - interval '6 minutes' and attempts < 2;
  for r in
    update clip_requests set status = 'EXPIRED', updated_at = now(),
           reason = case when status = 'PROCESSING' then 'STUCK' else 'NO_PROGRAM' end
     where status in ('PENDING', 'PROCESSING') and created_at < now() - interval '10 minutes'
    returning club_id, telegram_id
  loop
    select bot_token into v_token from club_bots where club_id = r.club_id and active limit 1;
    select case when language = 'uz' then 'uz' else 'ru' end into v_lang from bot_state where telegram_id = r.telegram_id;
    if v_token is not null then
      perform net.http_post(
        url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
        timeout_milliseconds := 30000,
        headers := jsonb_build_object('content-type', 'application/json'),
        body := jsonb_build_object('chat_id', r.telegram_id, 'text',
          case when v_lang = 'uz'
            then 'Videoni tayyorlab bo''lmadi 😔 Birozdan keyin qayta urinib ko''ring.'
            else 'Не получилось подготовить ролик 😔 Попробуйте ещё раз чуть позже.' end));
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.bot_clip_tables(uuid) from public, anon, authenticated;
revoke all on function public.bot_clip_request(uuid, bigint, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.clip_sweep() from public, anon, authenticated;
grant execute on function public.bot_clip_tables(uuid) to service_role;
grant execute on function public.bot_clip_request(uuid, bigint, uuid, timestamptz) to service_role;
grant execute on function public.clip_sweep() to service_role;

select cron.schedule('clip-sweep', '* * * * *', 'select public.clip_sweep()');
