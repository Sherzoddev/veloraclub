-- "Найти соперника" (billiards). A client posts one request; it is pushed to
-- every client of the club and the first one to accept plays. An opponent
-- backing out puts the request back up, until its creator cancels it. A
-- request stays live until an hour after its play time.
--
-- The bot and the client Mini App only ever call the RPCs below. All the
-- Telegram fan-out (the broadcast to every client, editing those broadcasts
-- as the request changes, confirmations, relayed messages between the two
-- players) happens in the match-notify edge function, fired by the triggers
-- at the bottom -- one implementation for both channels.

create table public.match_requests (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  creator_customer_id uuid not null references public.customers(id) on delete cascade,
  opponent_customer_id uuid references public.customers(id) on delete set null,
  play_at timestamptz not null,
  level text not null default 'MIDDLE' check (level in ('NOVICE', 'MIDDLE', 'PRO')),
  comment text check (comment is null or char_length(comment) <= 200),
  status text not null default 'OPEN' check (status in ('OPEN', 'MATCHED', 'CANCELLED', 'EXPIRED')),
  matched_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index match_requests_one_active
  on public.match_requests (club_id, creator_customer_id) where status in ('OPEN', 'MATCHED');
create index match_requests_board on public.match_requests (club_id, status, play_at);
create index match_requests_opponent on public.match_requests (opponent_customer_id) where status = 'MATCHED';

-- Messages between the two players, relayed through the bot. Scoped to a
-- pair: when an opponent backs out and someone else accepts, the new pair
-- starts with an empty thread.
create table public.match_messages (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.match_requests(id) on delete cascade,
  sender_customer_id uuid not null references public.customers(id) on delete cascade,
  recipient_customer_id uuid not null references public.customers(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index match_messages_thread on public.match_messages (match_id, created_at);
create index match_messages_unread on public.match_messages (recipient_customer_id) where read_at is null;

-- Which Telegram message each client got for a request, so it can be edited
-- ("✅ Соперник найден", back to open, "❌ Отменена") instead of re-sending.
create table public.match_broadcasts (
  match_id uuid not null references public.match_requests(id) on delete cascade,
  chat_id bigint not null,
  message_id bigint not null,
  lang text not null default 'ru',
  primary key (match_id, chat_id)
);

alter table public.match_requests enable row level security;
alter table public.match_messages enable row level security;
alter table public.match_broadcasts enable row level security;
revoke all on table public.match_requests, public.match_messages, public.match_broadcasts from anon, authenticated;

-- Live = still worth showing: open or matched, and not more than an hour
-- past its play time.
create or replace function public.match_is_live(p_status text, p_play_at timestamptz)
returns boolean language sql stable as $$
  select p_status in ('OPEN', 'MATCHED') and p_play_at > now() - interval '1 hour'
$$;

create or replace function public.match_expire_stale(p_club_id uuid)
returns void language sql security definer set search_path to 'public' as $$
  update match_requests set status = 'EXPIRED', updated_at = now()
  where club_id = p_club_id and status in ('OPEN', 'MATCHED') and play_at <= now() - interval '1 hour';
$$;

create or replace function public.match_create(
  p_club_id uuid, p_customer_id uuid, p_play_at timestamptz, p_level text, p_comment text
) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from customers where id = p_customer_id and club_id = p_club_id) then
    return jsonb_build_object('ok', false, 'reason', 'NO_CARD');
  end if;
  if p_play_at < now() - interval '5 minutes' or p_play_at > now() + interval '24 hours' then
    return jsonb_build_object('ok', false, 'reason', 'BAD_TIME');
  end if;
  perform match_expire_stale(p_club_id);
  select id into v_id from match_requests
  where club_id = p_club_id and creator_customer_id = p_customer_id and status in ('OPEN', 'MATCHED');
  if found then
    return jsonb_build_object('ok', false, 'reason', 'ALREADY_ACTIVE', 'id', v_id);
  end if;
  if exists (select 1 from match_requests where club_id = p_club_id and opponent_customer_id = p_customer_id
             and status = 'MATCHED') then
    return jsonb_build_object('ok', false, 'reason', 'ALREADY_PLAYING');
  end if;
  insert into match_requests (club_id, creator_customer_id, play_at, level, comment)
  values (p_club_id, p_customer_id, greatest(p_play_at, now()),
          case when p_level in ('NOVICE', 'MIDDLE', 'PRO') then p_level else 'MIDDLE' end,
          nullif(left(btrim(coalesce(p_comment, '')), 200), ''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- First come, first served: the row lock makes two simultaneous "Сыграю!"
-- taps resolve to exactly one opponent.
create or replace function public.match_accept(p_match_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r match_requests%rowtype;
begin
  select * into r from match_requests where id = p_match_id for update;
  if not found or not exists (select 1 from customers where id = p_customer_id and club_id = r.club_id) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
  end if;
  if r.creator_customer_id = p_customer_id then
    return jsonb_build_object('ok', false, 'reason', 'OWN');
  end if;
  if r.status in ('CANCELLED', 'EXPIRED') or not match_is_live(r.status, r.play_at) then
    return jsonb_build_object('ok', false, 'reason', 'CLOSED');
  end if;
  if r.status = 'MATCHED' then
    return jsonb_build_object('ok', r.opponent_customer_id = p_customer_id,
      'reason', case when r.opponent_customer_id = p_customer_id then 'ALREADY_YOURS' else 'TAKEN' end);
  end if;
  if exists (select 1 from match_requests m where m.club_id = r.club_id and m.status = 'MATCHED'
             and match_is_live(m.status, m.play_at)
             and (m.opponent_customer_id = p_customer_id or m.creator_customer_id = p_customer_id)) then
    return jsonb_build_object('ok', false, 'reason', 'ALREADY_PLAYING');
  end if;
  -- Found a game: their own open request (if any) is no longer needed.
  update match_requests set status = 'CANCELLED', updated_at = now()
  where club_id = r.club_id and creator_customer_id = p_customer_id and status = 'OPEN';
  update match_requests set status = 'MATCHED', opponent_customer_id = p_customer_id,
    matched_at = now(), updated_at = now()
  where id = p_match_id;
  return jsonb_build_object('ok', true);
end $$;

-- The opponent backs out: the request goes back up for everyone.
create or replace function public.match_leave(p_match_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  update match_requests set status = 'OPEN', opponent_customer_id = null, matched_at = null, updated_at = now()
  where id = p_match_id and status = 'MATCHED' and opponent_customer_id = p_customer_id;
  return jsonb_build_object('ok', found);
end $$;

create or replace function public.match_cancel(p_match_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  update match_requests set status = 'CANCELLED', updated_at = now()
  where id = p_match_id and creator_customer_id = p_customer_id and status in ('OPEN', 'MATCHED');
  return jsonb_build_object('ok', found);
end $$;

create or replace function public.match_send(p_match_id uuid, p_customer_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r match_requests%rowtype;
  v_to uuid;
  m match_messages%rowtype;
begin
  select * into r from match_requests where id = p_match_id;
  if not found or r.status <> 'MATCHED'
     or p_customer_id not in (r.creator_customer_id, r.opponent_customer_id) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_MATCHED');
  end if;
  if char_length(btrim(coalesce(p_body, ''))) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'EMPTY');
  end if;
  v_to := case when p_customer_id = r.creator_customer_id then r.opponent_customer_id else r.creator_customer_id end;
  insert into match_messages (match_id, sender_customer_id, recipient_customer_id, body)
  values (p_match_id, p_customer_id, v_to, left(btrim(p_body), 1000))
  returning * into m;
  -- Answering means the other side's messages have been seen.
  update match_messages set read_at = now()
  where match_id = p_match_id and recipient_customer_id = p_customer_id and read_at is null;
  return jsonb_build_object('ok', true, 'message', jsonb_build_object(
    'id', m.id, 'mine', true, 'body', m.body, 'read_at', m.read_at, 'created_at', m.created_at));
end $$;

-- The current pair's thread, oldest first; marks what was sent to the caller
-- as read.
create or replace function public.match_thread(p_match_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r match_requests%rowtype;
  v_other uuid;
  v_messages jsonb;
begin
  select * into r from match_requests where id = p_match_id;
  if not found or r.status <> 'MATCHED'
     or p_customer_id not in (r.creator_customer_id, r.opponent_customer_id) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_MATCHED');
  end if;
  v_other := case when p_customer_id = r.creator_customer_id then r.opponent_customer_id else r.creator_customer_id end;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'mine', t.sender_customer_id = p_customer_id, 'body', t.body,
      'read_at', t.read_at, 'created_at', t.created_at) order by t.created_at), '[]'::jsonb)
  into v_messages
  from (
    select * from match_messages
    where match_id = p_match_id
      and sender_customer_id in (p_customer_id, v_other) and recipient_customer_id in (p_customer_id, v_other)
    order by created_at desc limit 200
  ) t;
  update match_messages set read_at = now()
  where match_id = p_match_id and recipient_customer_id = p_customer_id and read_at is null;
  return jsonb_build_object('ok', true, 'messages', v_messages,
    'other', (select jsonb_build_object('name', split_part(coalesce(full_name, 'Игрок'), ' ', 1), 'visits', coalesce(visits_count, 0))
              from customers where id = v_other));
end $$;

-- Everything the "Найти соперника" screen needs in one round trip.
create or replace function public.match_board(p_club_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform match_expire_stale(p_club_id);
  return jsonb_build_object(
    'mine', (
      select jsonb_build_object('id', m.id, 'status', m.status, 'play_at', m.play_at, 'level', m.level,
        'comment', m.comment, 'created_at', m.created_at,
        'opponent', case when m.opponent_customer_id is null then null else (
          select jsonb_build_object('name', split_part(coalesce(c.full_name, 'Игрок'), ' ', 1), 'visits', coalesce(c.visits_count, 0))
          from customers c where c.id = m.opponent_customer_id) end)
      from match_requests m
      where m.club_id = p_club_id and m.creator_customer_id = p_customer_id and m.status in ('OPEN', 'MATCHED')
      limit 1),
    'playing', (
      select jsonb_build_object('id', m.id, 'play_at', m.play_at, 'level', m.level, 'comment', m.comment,
        'creator', jsonb_build_object('name', split_part(coalesce(c.full_name, 'Игрок'), ' ', 1), 'visits', coalesce(c.visits_count, 0)))
      from match_requests m join customers c on c.id = m.creator_customer_id
      where m.club_id = p_club_id and m.opponent_customer_id = p_customer_id and m.status = 'MATCHED'
      order by m.play_at limit 1),
    'open', (
      select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'play_at', m.play_at, 'level', m.level,
        'comment', m.comment, 'name', split_part(coalesce(c.full_name, 'Игрок'), ' ', 1),
        'visits', coalesce(c.visits_count, 0)) order by m.play_at), '[]'::jsonb)
      from match_requests m join customers c on c.id = m.creator_customer_id
      where m.club_id = p_club_id and m.status = 'OPEN' and m.creator_customer_id <> p_customer_id
        and match_is_live(m.status, m.play_at)),
    'unread', (select count(*)::int from match_messages mm join match_requests m on m.id = mm.match_id
               where mm.recipient_customer_id = p_customer_id and mm.read_at is null and m.status = 'MATCHED')
  );
end $$;

revoke execute on function public.match_create(uuid, uuid, timestamptz, text, text),
  public.match_accept(uuid, uuid), public.match_leave(uuid, uuid), public.match_cancel(uuid, uuid),
  public.match_send(uuid, uuid, text), public.match_thread(uuid, uuid), public.match_board(uuid, uuid),
  public.match_expire_stale(uuid)
  from public, anon, authenticated;

-- Fire match-notify after every meaningful change. pg_net queues the request
-- inside the transaction and sends it after commit.
create or replace function public.match_notify_trigger()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_payload jsonb;
begin
  if tg_table_name = 'match_messages' then
    v_payload := jsonb_build_object('event', 'message', 'match_id', new.match_id, 'message_id', new.id);
  elsif tg_op = 'INSERT' then
    v_payload := jsonb_build_object('event', 'created', 'match_id', new.id);
  elsif new.status is distinct from old.status then
    v_payload := jsonb_build_object(
      'event', case
        when new.status = 'MATCHED' then 'matched'
        when new.status = 'OPEN' then 'reopened'
        when new.status = 'CANCELLED' then 'cancelled'
        else 'expired' end,
      'match_id', new.id, 'prev_opponent', old.opponent_customer_id);
  end if;
  if v_payload is not null then
    perform net.http_post(
      url := 'https://aatriitpqpwhdcehjzip.supabase.co/functions/v1/match-notify?key=p7oc8zbhdskjopwb4n6ntxkbvgsu64y0at3w',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := v_payload
    );
  end if;
  return new;
end $$;

create trigger match_requests_notify after insert or update on public.match_requests
  for each row execute function public.match_notify_trigger();
create trigger match_messages_notify after insert on public.match_messages
  for each row execute function public.match_notify_trigger();
