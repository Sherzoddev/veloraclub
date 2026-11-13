-- "🎰 Получить скидку": every client of the club bot gets a message with a
-- button; the button gives a random discount code (3..40 %) for a few days.
-- The cashier enters the code on the payment sheet; it takes the percent off
-- the PLAY TIME only (bar and goods are not discounted).
--
-- The prizes are a fixed, shuffled pool made when the campaign is created:
-- exactly one 40 %, the mean 8.5 %, mostly 5-10 %. Whoever presses the button
-- takes the next prize, so the shares do not drift with luck.

create table if not exists public.discount_campaigns (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null,
  valid_days integer not null check (valid_days between 1 and 60),
  status text not null default 'DRAFT' check (status in ('DRAFT', 'SENT')),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  ends_at timestamptz
);

create table if not exists public.discount_prizes (
  id bigserial primary key,
  campaign_id uuid not null,
  ord integer not null,
  percent smallint not null check (percent between 1 and 90),
  telegram_id bigint,
  claimed_at timestamptz,
  unique (campaign_id, ord)
);

create table if not exists public.discount_recipients (
  campaign_id uuid not null,
  telegram_id bigint not null,
  chat_id bigint not null,
  lang text not null default 'ru',
  sent_at timestamptz,
  request_id bigint,
  primary key (campaign_id, telegram_id)
);

create table if not exists public.customer_discount_codes (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null,
  campaign_id uuid not null,
  telegram_id bigint not null,
  customer_id uuid,
  code text not null unique,
  percent smallint not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'USED')),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_order_id uuid,
  used_amount bigint,
  unique (campaign_id, telegram_id)
);
create index if not exists customer_discount_codes_order_idx on public.customer_discount_codes (used_order_id);
create index if not exists customer_discount_codes_tg_idx on public.customer_discount_codes (club_id, telegram_id);

alter table public.discount_campaigns enable row level security;
alter table public.discount_prizes enable row level security;
alter table public.discount_recipients enable row level security;
alter table public.customer_discount_codes enable row level security;
drop policy if exists discount_campaigns_select on public.discount_campaigns;
create policy discount_campaigns_select on public.discount_campaigns
  for select using (app_is_club_member(club_id));
drop policy if exists customer_discount_codes_select on public.customer_discount_codes;
create policy customer_discount_codes_select on public.customer_discount_codes
  for select using (app_is_club_member(club_id));

-- The shuffled prize list for n clients: one 40 %, the rest from the shares
-- below, then nudged so that the mean is 8.5 %.
create or replace function public.app_discount_pool(p_n integer)
returns integer[]
language plpgsql
set search_path = public
as $$
declare
  tiers integer[] := array[3, 5, 7, 10, 15, 20, 25, 30];
  base integer[]  := array[19, 25, 22, 15, 9, 5, 2, 1];   -- per 98 non-jackpot clients
  c integer[] := array[0, 0, 0, 0, 0, 0, 0, 0];
  m integer := p_n - 1;
  i integer;
  j integer;
  total integer := 0;
  sum_pct integer := 40;
  target integer;
  result integer[];
begin
  if p_n < 1 then return array[]::integer[]; end if;
  if p_n = 1 then return array[40]; end if;
  for i in 1..8 loop
    c[i] := round(base[i] * m / 98.0);
    total := total + c[i];
  end loop;
  while total > m loop                       -- rounding gave too many: trim the biggest tier
    j := 1;
    for i in 2..8 loop if c[i] > c[j] then j := i; end if; end loop;
    c[j] := c[j] - 1; total := total - 1;
  end loop;
  c[2] := c[2] + (m - total);                 -- too few: the 5 % tier takes the rest
  for i in 1..8 loop sum_pct := sum_pct + tiers[i] * c[i]; end loop;
  target := round(8.5 * p_n);
  while target - sum_pct >= 5 and c[2] > 0 loop
    c[2] := c[2] - 1; c[4] := c[4] + 1; sum_pct := sum_pct + 5;      -- 5 % -> 10 %
  end loop;
  while target - sum_pct >= 2 and c[2] > 0 loop
    c[2] := c[2] - 1; c[3] := c[3] + 1; sum_pct := sum_pct + 2;      -- 5 % -> 7 %
  end loop;
  while sum_pct - target >= 5 and c[4] > 0 loop
    c[4] := c[4] - 1; c[2] := c[2] + 1; sum_pct := sum_pct - 5;      -- small n: back down
  end loop;
  select array_agg(t.p order by random()) into result
    from (
      select tiers[gs.k] as p from generate_series(1, 8) as gs(k)
        cross join lateral generate_series(1, c[gs.k]) as g(x)
      union all select 40
    ) t;
  return result;
end;
$$;

-- A campaign for every client of the club bot: the list of who gets the
-- message and the prize pool. Nothing is sent yet.
create or replace function public.bot_discount_campaign_create(p_club_id uuid, p_valid_days integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_n integer;
  v_pool integer[];
begin
  insert into discount_campaigns (club_id, valid_days) values (p_club_id, p_valid_days) returning id into v_id;
  insert into discount_recipients (campaign_id, telegram_id, chat_id, lang)
  select distinct on (u.telegram_id) v_id, u.telegram_id, u.chat_id,
         case when s.language = 'uz' then 'uz' else 'ru' end
    from club_bot_users u
    left join bot_state s on s.telegram_id = u.telegram_id
   where u.club_id = p_club_id and u.role = 'CLIENT' and u.chat_id is not null
   order by u.telegram_id
  on conflict do nothing;
  get diagnostics v_n = row_count;
  v_pool := app_discount_pool(v_n);
  insert into discount_prizes (campaign_id, ord, percent)
  select v_id, g, v_pool[g] from generate_series(1, v_n) g;
  return jsonb_build_object(
    'campaign_id', v_id, 'recipients', v_n,
    'mean', (select round(avg(percent), 2) from discount_prizes where campaign_id = v_id),
    'distribution', (select jsonb_object_agg(percent::text, n) from (
        select percent, count(*) as n from discount_prizes where campaign_id = v_id group by percent) t));
end;
$$;

-- Send the message to the next p_limit clients that have not got it yet
-- (call again until "left" is 0; Telegram allows about 30 messages a second).
-- The first call fixes the end date: valid_days days, up to the end of that day.
create or replace function public.bot_discount_campaign_send(p_campaign_id uuid, p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c discount_campaigns%rowtype;
  v_tz text;
  v_token text;
  v_date text;
  v_text text;
  v_btn text;
  v_req bigint;
  v_sent integer := 0;
  r record;
begin
  select * into v_c from discount_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'CAMPAIGN_NOT_FOUND'; end if;
  select coalesce(timezone, 'Asia/Tashkent') into v_tz from clubs where id = v_c.club_id;
  select bot_token into v_token from club_bots where club_id = v_c.club_id and active limit 1;
  if v_token is null then raise exception 'NO_BOT'; end if;
  if v_c.status = 'DRAFT' then
    update discount_campaigns
       set status = 'SENT', sent_at = now(),
           ends_at = (date_trunc('day', now() at time zone v_tz) + make_interval(days => v_c.valid_days + 1)) at time zone v_tz
     where id = p_campaign_id returning * into v_c;
  end if;
  v_date := to_char((v_c.ends_at - interval '1 minute') at time zone v_tz, 'DD.MM');

  for r in
    select * from discount_recipients
     where campaign_id = p_campaign_id and sent_at is null
     order by telegram_id limit greatest(p_limit, 1)
  loop
    if r.lang = 'uz' then
      v_text := format(E'🎰 <b>Mijozlarimiz uchun aksiya!</b>\n\nTugmani bosing va keyingi tashrifingizga qancha chegirma olishingizni biling: <b>3%% dan 40%% gacha</b>.\n\n⏳ Chegirma <b>%s</b> gacha amal qiladi.\n🎱 Chegirma o''yin vaqtiga amal qiladi — bar va mahsulotlarga tegishli emas.\nHar bir mijozga — bitta urinish. Kimdir hammadan omadli bo''ladi 🍀', v_date);
      v_btn := '🎁 Chegirma olish';
    else
      v_text := format(E'🎰 <b>Акция для наших клиентов!</b>\n\nНажмите кнопку и узнайте, какую скидку вы получите: <b>от 3%% до 40%%</b> на следующий визит.\n\n⏳ Скидка действует до <b>%s</b> включительно.\n🎱 Скидка на время игры — на бар и товары не распространяется.\nУ каждого клиента — одна попытка. Кому-то повезёт больше всех 🍀', v_date);
      v_btn := '🎁 Получить скидку';
    end if;
    v_req := net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := jsonb_build_object('content-type', 'application/json'),
      body := jsonb_build_object(
        'chat_id', r.chat_id, 'text', v_text, 'parse_mode', 'HTML',
        'reply_markup', jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', v_btn, 'callback_data', 'disc:' || p_campaign_id::text))))));
    update discount_recipients set sent_at = now(), request_id = v_req
     where campaign_id = p_campaign_id and telegram_id = r.telegram_id;
    v_sent := v_sent + 1;
  end loop;
  return jsonb_build_object(
    'sent_now', v_sent, 'ends_on', v_date,
    'left', (select count(*) from discount_recipients where campaign_id = p_campaign_id and sent_at is null));
end;
$$;

-- The button: the next prize from the pool, once per client.
create or replace function public.bot_discount_claim(p_club_id uuid, p_tg_id bigint, p_campaign_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_c discount_campaigns%rowtype;
  v_dc customer_discount_codes%rowtype;
  v_prize discount_prizes%rowtype;
  v_code text;
  v_customer uuid;
  v_tz text;
begin
  select * into v_c from discount_campaigns where id = p_campaign_id and club_id = p_club_id;
  if not found or v_c.status <> 'SENT' then return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND'); end if;
  if not exists (select 1 from discount_recipients where campaign_id = p_campaign_id and telegram_id = p_tg_id) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_RECIPIENT');
  end if;
  select coalesce(timezone, 'Asia/Tashkent') into v_tz from clubs where id = p_club_id;

  select * into v_dc from customer_discount_codes where campaign_id = p_campaign_id and telegram_id = p_tg_id;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'percent', v_dc.percent, 'code', v_dc.code,
      'until', to_char((v_dc.expires_at - interval '1 minute') at time zone v_tz, 'DD.MM'), 'used', v_dc.status = 'USED');
  end if;
  if now() >= v_c.ends_at then return jsonb_build_object('ok', false, 'reason', 'ENDED'); end if;

  -- two simultaneous taps of different clients never take the same prize
  select * into v_prize from discount_prizes
   where campaign_id = p_campaign_id and telegram_id is null
   order by ord limit 1 for update skip locked;
  if not found then return jsonb_build_object('ok', false, 'reason', 'NO_PRIZES'); end if;

  loop
    v_code := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::integer, 1), '')
                 from generate_series(1, 6));
    exit when not exists (select 1 from customer_discount_codes where code = v_code);
  end loop;
  select id into v_customer from customers
   where club_id = p_club_id and telegram_id = p_tg_id and active and archived_at is null limit 1;

  insert into customer_discount_codes (club_id, campaign_id, telegram_id, customer_id, code, percent, expires_at)
  values (p_club_id, p_campaign_id, p_tg_id, v_customer, v_code, v_prize.percent, v_c.ends_at);
  update discount_prizes set telegram_id = p_tg_id, claimed_at = now() where id = v_prize.id;

  if v_customer is not null then
    perform app_audit(p_club_id, 'discount.claimed', 'customer', v_customer, null,
      jsonb_build_object('percent', v_prize.percent, 'code', v_code), '{}'::jsonb);
  end if;
  if v_prize.percent >= 25 then
    perform app_notify_owner_bot(p_club_id, format(E'🎰 <b>Выпала скидка %s%%</b>\nКлиент: %s\nКод: <code>%s</code>',
      v_prize.percent, coalesce(app_promo_who(v_customer), 'ID ' || p_tg_id), v_code));
  end if;
  return jsonb_build_object('ok', true, 'already', false, 'percent', v_prize.percent, 'code', v_code,
    'until', to_char((v_c.ends_at - interval '1 minute') at time zone v_tz, 'DD.MM'), 'used', false);
end;
$$;

-- Cashier side ---------------------------------------------------------------

-- What the payment sheet shows: a code already on the order, the order's
-- customer's own unused code, and whether a campaign is running at all.
create or replace function public.promo_discount_order_state(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_o orders%rowtype;
  v_used customer_discount_codes%rowtype;
  v_mine customer_discount_codes%rowtype;
  v_tg bigint;
begin
  select * into v_o from orders where id = p_order_id;
  if not found or not app_is_club_member(v_o.club_id) then return null; end if;
  select * into v_used from customer_discount_codes where used_order_id = p_order_id and status = 'USED' limit 1;
  if v_o.customer_id is not null then
    select telegram_id into v_tg from customers where id = v_o.customer_id;
    select * into v_mine from customer_discount_codes
     where club_id = v_o.club_id and telegram_id = v_tg and status = 'ACTIVE' and expires_at > now()
     order by expires_at limit 1;
  end if;
  return jsonb_build_object(
    'live', exists (select 1 from discount_campaigns where club_id = v_o.club_id and status = 'SENT' and ends_at > now()),
    'used', case when v_used.id is null then null else jsonb_build_object(
        'code', v_used.code, 'percent', v_used.percent, 'amount', v_used.used_amount) end,
    'mine', case when v_mine.id is null then null else jsonb_build_object(
        'code', v_mine.code, 'percent', v_mine.percent, 'expires_at', v_mine.expires_at) end);
end;
$$;

create or replace function public.promo_apply_discount_code(p_order_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_o orders%rowtype;
  v_dc customer_discount_codes%rowtype;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_base bigint;
  v_amount bigint;
  v_lang text;
begin
  select * into v_o from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_o.club_id, 'discount.apply');
  if v_o.status <> 'OPEN' then raise exception 'ORDER_NOT_OPEN' using errcode = 'P0001'; end if;
  if exists (select 1 from customer_discount_codes where used_order_id = p_order_id and status = 'USED') then
    raise exception 'DISCOUNT_CODE_ALREADY_ON_ORDER' using errcode = 'P0001';
  end if;

  select * into v_dc from customer_discount_codes where code = v_code and club_id = v_o.club_id for update;
  if not found then raise exception 'DISCOUNT_CODE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_dc.status <> 'ACTIVE' then raise exception 'DISCOUNT_CODE_USED' using errcode = 'P0001'; end if;
  if v_dc.expires_at <= now() then raise exception 'DISCOUNT_CODE_EXPIRED' using errcode = 'P0001'; end if;

  -- the play time only: not the bar, not goods, not a deposit
  v_o := app_recalculate_order_totals(p_order_id);
  v_base := greatest(0, v_o.time_amount - v_o.discount_amount);
  if v_base <= 0 then raise exception 'DISCOUNT_CODE_NO_TIME' using errcode = 'P0001'; end if;
  v_amount := round(v_base::numeric * v_dc.percent / 100)::bigint;

  update orders
     set discount_amount = discount_amount + v_amount,
         discount_reason = concat_ws(' + ', nullif(discount_reason, ''), format('Kod %s (%s%%)', v_dc.code, v_dc.percent)),
         discount_applies_to = coalesce(discount_applies_to, 'ALL')
   where id = p_order_id;
  v_o := app_recalculate_order_totals(p_order_id);

  update customer_discount_codes
     set status = 'USED', used_at = now(), used_order_id = p_order_id, used_amount = v_amount
   where id = v_dc.id;

  perform app_audit(v_o.club_id, 'promo.discount_code_used', 'order', p_order_id, null,
    jsonb_build_object('code', v_dc.code, 'percent', v_dc.percent, 'amount', v_amount), '{}'::jsonb);
  perform app_notify_owner_bot(v_o.club_id,
    format(E'✅ <b>Код скидки использован</b>\nКод: <code>%s</code> · %s%% · −%s сум', v_dc.code, v_dc.percent, v_amount));
  v_lang := app_promo_lang(v_dc.telegram_id);
  perform app_promo_send_client(v_o.club_id, v_dc.telegram_id,
    case when v_lang = 'ru'
      then format(E'🎟 Код <code>%s</code> использован — скидка %s%% на время игры применена. Приятной игры! 🎱', v_dc.code, v_dc.percent)
      else format(E'🎟 <code>%s</code> kodi ishlatildi — o''yin vaqtiga %s%% chegirma qo''llandi. Yaxshi o''yin! 🎱', v_dc.code, v_dc.percent) end);

  return jsonb_build_object('order', app_order_json(p_order_id), 'discount_amount', v_amount);
end;
$$;

create or replace function public.promo_release_discount_code(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_o orders%rowtype;
  v_dc customer_discount_codes%rowtype;
begin
  select * into v_o from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_o.club_id, 'discount.apply');
  if v_o.status <> 'OPEN' then raise exception 'ORDER_NOT_OPEN' using errcode = 'P0001'; end if;
  select * into v_dc from customer_discount_codes where used_order_id = p_order_id and status = 'USED' for update;
  if not found then return jsonb_build_object('order', app_order_json(p_order_id)); end if;

  update orders
     set discount_amount = greatest(0, discount_amount - coalesce(v_dc.used_amount, 0)),
         discount_reason = nullif(trim(both ' +' from
           replace(coalesce(discount_reason, ''), format('Kod %s (%s%%)', v_dc.code, v_dc.percent), '')), '')
   where id = p_order_id;
  perform app_recalculate_order_totals(p_order_id);
  update customer_discount_codes set status = 'ACTIVE', used_at = null, used_order_id = null, used_amount = null
   where id = v_dc.id;
  perform app_audit(v_o.club_id, 'promo.discount_code_released', 'order', p_order_id, null,
    jsonb_build_object('code', v_dc.code), '{}'::jsonb);
  return jsonb_build_object('order', app_order_json(p_order_id));
end;
$$;

-- Bot-only functions: nobody but the service role (the bot, the owner) may
-- start campaigns, send them or take prizes. The cashier functions check the
-- permission themselves and are open to signed-in staff only (like the coupon).
revoke all on function public.app_discount_pool(integer) from public, anon, authenticated;
revoke all on function public.bot_discount_campaign_create(uuid, integer) from public, anon, authenticated;
revoke all on function public.bot_discount_campaign_send(uuid, integer) from public, anon, authenticated;
revoke all on function public.bot_discount_claim(uuid, bigint, uuid) from public, anon, authenticated;
grant execute on function public.app_discount_pool(integer) to service_role;
grant execute on function public.bot_discount_campaign_create(uuid, integer) to service_role;
grant execute on function public.bot_discount_campaign_send(uuid, integer) to service_role;
grant execute on function public.bot_discount_claim(uuid, bigint, uuid) to service_role;

revoke all on function public.promo_discount_order_state(uuid) from public, anon;
revoke all on function public.promo_apply_discount_code(uuid, text) from public, anon;
revoke all on function public.promo_release_discount_code(uuid) from public, anon;
grant execute on function public.promo_discount_order_state(uuid) to authenticated, service_role;
grant execute on function public.promo_apply_discount_code(uuid, text) to authenticated, service_role;
grant execute on function public.promo_release_discount_code(uuid) to authenticated, service_role;
