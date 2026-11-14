-- Client polls in the club bot: "which features should we add?" -- a message
-- with one button per option (one tap = one vote) and a "my own idea" option
-- that asks for a few words. The owner reads the result in the admin bot
-- ("📊 Опрос") and every own idea reaches the owner's bot as it arrives.
--
-- Options are data: a poll can be made, changed or repeated without code.

create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null,
  body_ru text not null,
  body_uz text not null,
  status text not null default 'DRAFT' check (status in ('DRAFT', 'OPEN', 'CLOSED')),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.poll_options (
  poll_id uuid not null,
  pos smallint not null check (pos between 1 and 12),
  emoji text not null default '',
  label_ru text not null,
  label_uz text not null,
  primary key (poll_id, pos)
);

create table if not exists public.poll_recipients (
  poll_id uuid not null,
  telegram_id bigint not null,
  chat_id bigint not null,
  lang text not null default 'ru',
  sent_at timestamptz,
  request_id bigint,
  primary key (poll_id, telegram_id)
);

-- pos 0 = "my own idea" (the text is in idea)
create table if not exists public.poll_votes (
  poll_id uuid not null,
  telegram_id bigint not null,
  pos smallint not null check (pos between 0 and 12),
  idea text,
  voted_at timestamptz not null default now(),
  primary key (poll_id, telegram_id)
);

alter table public.polls enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_recipients enable row level security;
alter table public.poll_votes enable row level security;
drop policy if exists polls_select on public.polls;
create policy polls_select on public.polls for select using (app_is_club_member(club_id));

-- A poll for the clients of the club bot. p_options: [{"emoji","ru","uz"}, ...]
-- (in the order of the buttons). p_from_campaign: only clients who received
-- that discount campaign (Telegram said ok), so nobody who blocked the bot is
-- counted; null = every client of the bot.
create or replace function public.bot_poll_create(
  p_club_id uuid, p_body_ru text, p_body_uz text, p_options jsonb, p_from_campaign uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_n integer;
  o jsonb;
  i integer := 0;
begin
  insert into polls (club_id, body_ru, body_uz) values (p_club_id, p_body_ru, p_body_uz) returning id into v_id;
  for o in select * from jsonb_array_elements(p_options) loop
    i := i + 1;
    insert into poll_options (poll_id, pos, emoji, label_ru, label_uz)
    values (v_id, i, coalesce(o->>'emoji', ''), o->>'ru', o->>'uz');
  end loop;
  insert into poll_recipients (poll_id, telegram_id, chat_id, lang)
  select distinct on (u.telegram_id) v_id, u.telegram_id, u.chat_id,
         case when s.language = 'uz' then 'uz' else 'ru' end
    from club_bot_users u
    left join bot_state s on s.telegram_id = u.telegram_id
   where u.club_id = p_club_id and u.role = 'CLIENT' and u.chat_id is not null
     and (p_from_campaign is null or exists (
           select 1 from discount_recipients d
             join net._http_response r on r.id = d.request_id
            where d.campaign_id = p_from_campaign and d.telegram_id = u.telegram_id
              and r.status_code = 200))
   order by u.telegram_id
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('poll_id', v_id, 'recipients', v_n, 'options', i);
end;
$$;

-- Send to the next p_limit clients that have not got it yet (call until "left" is 0).
create or replace function public.bot_poll_send(p_poll_id uuid, p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p polls%rowtype;
  v_token text;
  v_text text;
  v_rows jsonb;
  v_req bigint;
  v_sent integer := 0;
  r record;
begin
  select * into v_p from polls where id = p_poll_id for update;
  if not found then raise exception 'POLL_NOT_FOUND'; end if;
  select bot_token into v_token from club_bots where club_id = v_p.club_id and active limit 1;
  if v_token is null then raise exception 'NO_BOT'; end if;
  if v_p.status = 'DRAFT' then
    update polls set status = 'OPEN', sent_at = now() where id = p_poll_id returning * into v_p;
  end if;
  for r in
    select * from poll_recipients where poll_id = p_poll_id and sent_at is null
     order by telegram_id limit greatest(p_limit, 1)
  loop
    -- one button per option (two to a row) and the last one: "my own idea"
    select jsonb_agg(row_buttons order by rn) into v_rows from (
      select (pos - 1) / 2 as rn,
             jsonb_agg(jsonb_build_object(
               'text', btrim(emoji || ' ' || case when r.lang = 'uz' then label_uz else label_ru end),
               'callback_data', 'poll:' || p_poll_id::text || ':' || pos) order by pos) as row_buttons
        from poll_options where poll_id = p_poll_id group by (pos - 1) / 2) t;
    v_rows := coalesce(v_rows, '[]'::jsonb) || jsonb_build_array(jsonb_build_array(jsonb_build_object(
      'text', case when r.lang = 'uz' then '✍️ O''z g''oyamni yozaman' else '✍️ Предложу своё' end,
      'callback_data', 'poll:' || p_poll_id::text || ':0')));
    v_text := case when r.lang = 'uz' then v_p.body_uz else v_p.body_ru end;
    v_req := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      timeout_milliseconds := 30000,
      headers := jsonb_build_object('content-type', 'application/json'),
      body := jsonb_build_object('chat_id', r.chat_id, 'text', v_text, 'parse_mode', 'HTML',
                                 'reply_markup', jsonb_build_object('inline_keyboard', v_rows)));
    update poll_recipients set sent_at = now(), request_id = v_req
     where poll_id = p_poll_id and telegram_id = r.telegram_id;
    v_sent := v_sent + 1;
  end loop;
  return jsonb_build_object('sent_now', v_sent,
    'left', (select count(*) from poll_recipients where poll_id = p_poll_id and sent_at is null));
end;
$$;

-- One tap. A second tap changes the choice (the last one counts).
create or replace function public.bot_poll_vote(p_club_id uuid, p_tg_id bigint, p_poll_id uuid, p_pos smallint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p polls%rowtype;
  v_label_ru text;
  v_label_uz text;
begin
  select * into v_p from polls where id = p_poll_id and club_id = p_club_id;
  if not found or v_p.status <> 'OPEN' then return jsonb_build_object('ok', false, 'reason', 'CLOSED'); end if;
  if not exists (select 1 from poll_recipients where poll_id = p_poll_id and telegram_id = p_tg_id) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_RECIPIENT');
  end if;
  if p_pos <> 0 then
    select label_ru, label_uz into v_label_ru, v_label_uz from poll_options where poll_id = p_poll_id and pos = p_pos;
    if not found then return jsonb_build_object('ok', false, 'reason', 'NO_OPTION'); end if;
  end if;
  insert into poll_votes (poll_id, telegram_id, pos) values (p_poll_id, p_tg_id, p_pos)
  on conflict (poll_id, telegram_id) do update
    set pos = excluded.pos, voted_at = now(), idea = case when excluded.pos = 0 then poll_votes.idea else null end;
  return jsonb_build_object('ok', true, 'own', p_pos = 0, 'label_ru', v_label_ru, 'label_uz', v_label_uz);
end;
$$;

-- The "my own idea" text: kept, and passed on to the owner's bot right away.
create or replace function public.bot_poll_idea(p_club_id uuid, p_tg_id bigint, p_poll_id uuid, p_text text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_text text := left(btrim(coalesce(p_text, '')), 500);
  v_who text;
begin
  if v_text = '' then return jsonb_build_object('ok', false, 'reason', 'EMPTY'); end if;
  if not exists (select 1 from polls where id = p_poll_id and club_id = p_club_id and status = 'OPEN')
     or not exists (select 1 from poll_recipients where poll_id = p_poll_id and telegram_id = p_tg_id) then
    return jsonb_build_object('ok', false, 'reason', 'CLOSED');
  end if;
  insert into poll_votes (poll_id, telegram_id, pos, idea) values (p_poll_id, p_tg_id, 0, v_text)
  on conflict (poll_id, telegram_id) do update set pos = 0, idea = excluded.idea, voted_at = now();
  select coalesce(
           (select nullif(c.full_name, '') from customers c where c.club_id = p_club_id and c.telegram_id = p_tg_id limit 1),
           (select nullif(trim(coalesce(u.full_name, '') || case when u.username is not null then ' @' || u.username else '' end), '')
              from club_bot_users u where u.club_id = p_club_id and u.telegram_id = p_tg_id limit 1),
           'ID ' || p_tg_id) into v_who;
  perform app_notify_owner_bot(p_club_id,
    format(E'💡 <b>Идея клиента</b>\n%s\n\n%s', v_who, v_text));
  return jsonb_build_object('ok', true);
end;
$$;

-- For the admin bot: who got it, how many answered, votes by option, own ideas.
create or replace function public.bot_poll_results(p_club_id uuid, p_poll_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := p_poll_id;
begin
  if v_id is null then
    select id into v_id from polls where club_id = p_club_id and status <> 'DRAFT' order by sent_at desc nulls last limit 1;
  end if;
  if v_id is null then return jsonb_build_object('ok', false, 'reason', 'NO_POLL'); end if;
  return jsonb_build_object(
    'ok', true,
    'poll_id', v_id,
    'sent_at', (select sent_at from polls where id = v_id),
    'recipients', (select count(*) from poll_recipients where poll_id = v_id and sent_at is not null),
    'delivered', (select count(*) from poll_recipients r join net._http_response h on h.id = r.request_id
                   where r.poll_id = v_id and h.status_code = 200),
    'answered', (select count(*) from poll_votes where poll_id = v_id),
    'options', coalesce((select jsonb_agg(jsonb_build_object(
        'pos', o.pos, 'emoji', o.emoji, 'label', o.label_ru,
        'votes', (select count(*) from poll_votes v where v.poll_id = v_id and v.pos = o.pos)) order by o.pos)
        from poll_options o where o.poll_id = v_id), '[]'::jsonb),
    'own_ideas', (select count(*) from poll_votes where poll_id = v_id and pos = 0),
    'ideas', coalesce((select jsonb_agg(i.idea order by i.voted_at desc) from (
        select idea, voted_at from poll_votes where poll_id = v_id and pos = 0 and idea is not null
         order by voted_at desc limit 20) i), '[]'::jsonb));
end;
$$;

revoke all on function public.bot_poll_create(uuid, text, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.bot_poll_send(uuid, integer) from public, anon, authenticated;
revoke all on function public.bot_poll_vote(uuid, bigint, uuid, smallint) from public, anon, authenticated;
revoke all on function public.bot_poll_idea(uuid, bigint, uuid, text) from public, anon, authenticated;
revoke all on function public.bot_poll_results(uuid, uuid) from public, anon, authenticated;
grant execute on function public.bot_poll_create(uuid, text, text, jsonb, uuid) to service_role;
grant execute on function public.bot_poll_send(uuid, integer) to service_role;
grant execute on function public.bot_poll_vote(uuid, bigint, uuid, smallint) to service_role;
grant execute on function public.bot_poll_idea(uuid, bigint, uuid, text) to service_role;
grant execute on function public.bot_poll_results(uuid, uuid) to service_role;
