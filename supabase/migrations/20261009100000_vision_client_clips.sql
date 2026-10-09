-- Velora Vision: the best shots of a game go to the client, and the channel
-- gets a weekly vote for the shot of the week.
--
-- * vision_clips: every clip the camera program sent to the channel (only the
--   place of the post in the channel: the video itself lives in Telegram).
--   The program fills it through the function vision-clips.
-- * When a check with a client's card is completed, the 5 best clips of that
--   game are copied from the channel to the client's chat by the club bot
--   (vision_share_clips_for_order, called from create_payment in the next
--   migration). Closing a check never fails because of this.
-- * Once a week the function vision-weekly closes the last poll, names the
--   winner and starts the next poll (scheduled in a later migration).

create table if not exists public.vision_clips (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  resource_id uuid references public.resources(id) on delete set null,
  session_id uuid references public.game_sessions(id) on delete set null,
  table_name text not null,
  chat_id bigint not null,          -- the channel, as Telegram numbers it (-100...)
  message_id bigint not null,
  score numeric(6, 2) not null default 0,
  shot_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (chat_id, message_id)
);
create index if not exists vision_clips_session_idx on public.vision_clips (session_id);
create index if not exists vision_clips_club_time_idx on public.vision_clips (club_id, shot_at desc);

create table if not exists public.vision_clip_shares (
  order_id uuid primary key references public.orders(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  clips_sent integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.vision_weekly_polls (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  chat_id bigint not null,
  poll_message_id bigint not null,
  clip_ids uuid[] not null,         -- the clips behind the poll's options, in order
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists vision_weekly_polls_club_idx on public.vision_weekly_polls (club_id, created_at desc);

-- Only the server (service role and the functions below) touches these.
alter table public.vision_clips enable row level security;
alter table public.vision_clip_shares enable row level security;
alter table public.vision_weekly_polls enable row level security;
revoke all on public.vision_clips, public.vision_clip_shares, public.vision_weekly_polls from anon, authenticated;

-- The best clips of one game: highest score first, handed over in the order
-- they were played.
create or replace function public.vision_clips_for_session(p_session_id uuid, p_limit integer default 5)
returns setof public.vision_clips
language sql
stable
set search_path to 'public'
as $$
  select t.*
  from (
    select c.*
    from public.vision_clips c
    where c.session_id = p_session_id
    order by c.score desc, c.shot_at
    limit greatest(p_limit, 1)
  ) t
  order by t.shot_at;
$$;
revoke all on function public.vision_clips_for_session(uuid, integer) from public, anon, authenticated;

-- Copies the best clips of the game behind a completed check to the client's
-- chat with the club bot. Called from create_payment when the check closes
-- (a trigger on orders could not be created: the statement hangs on the
-- project). Any error is a warning: closing a check never fails because of it.
create or replace function public.vision_share_clips_for_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order record;
  v_tg bigint;
  v_token text;
  v_tz text;
  v_n integer := 0;
  r record;
  v_caption text;
begin
  begin
    select id, club_id, customer_id, session_id into v_order from public.orders where id = p_order_id;
    if not found or v_order.customer_id is null or v_order.session_id is null then
      return;
    end if;
    if not exists (select 1 from public.vision_clips where session_id = v_order.session_id) then
      return;
    end if;

    select telegram_id into v_tg from public.customers where id = v_order.customer_id;
    select bot_token into v_token from public.club_bots where club_id = v_order.club_id and active limit 1;
    if v_tg is null or v_token is null then
      return;
    end if;

    insert into public.vision_clip_shares (order_id, customer_id)
    values (v_order.id, v_order.customer_id)
    on conflict (order_id) do nothing;
    if not found then
      return;  -- already sent for this check
    end if;

    select coalesce(timezone, 'Asia/Tashkent') into v_tz from public.clubs where id = v_order.club_id;

    for r in select * from public.vision_clips_for_session(v_order.session_id, 5) loop
      v_n := v_n + 1;
      v_caption := case when v_n = 1 then E'🎬 Лучшие моменты вашей игры\n' else '' end
        || '🎱 ' || r.table_name || ', ' || to_char(r.shot_at at time zone v_tz, 'HH24:MI');
      perform net.http_post(
        url := 'https://api.telegram.org/bot' || v_token || '/copyMessage',
        headers := jsonb_build_object('content-type', 'application/json'),
        body := jsonb_build_object(
          'chat_id', v_tg,
          'from_chat_id', r.chat_id,
          'message_id', r.message_id,
          'caption', v_caption
        )
      );
    end loop;

    update public.vision_clip_shares set clips_sent = v_n where order_id = v_order.id;
  exception when others then
    raise warning 'vision_share_clips_for_order: %', sqlerrm;
  end;
end;
$function$;
revoke all on function public.vision_share_clips_for_order(uuid) from public, anon, authenticated;
