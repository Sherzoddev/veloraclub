-- «6 tashrif = 1 soat bepul»: every 6 visits of an hour or more, paid at
-- least 60 000, give the customer a coupon for one free hour of play between
-- 11:00 and 17:00. The coupon goes to the client bot; unused, it burns after
-- valid_days. Only visits paid after the promo is switched on count, and
-- none after ends_at.
--
-- The visit is taken from create_payment (orders are too busy for a new
-- trigger), the free hour is applied by promo_apply_coupon, and an hourly
-- cron job reminds and burns.
--
-- No foreign keys to clubs/customers: taking the lock on those busy tables
-- hangs; the functions below only ever write ids they have just read.

create table if not exists public.club_visit_promos (
  club_id uuid primary key,
  enabled boolean not null default false,
  visits_needed smallint not null default 6 check (visits_needed between 2 and 50),
  min_amount bigint not null default 60000 check (min_amount >= 0),
  min_minutes smallint not null default 60 check (min_minutes >= 0),
  free_minutes smallint not null default 60 check (free_minutes between 1 and 600),
  valid_days smallint not null default 7 check (valid_days between 1 and 90),
  hour_from smallint not null default 11 check (hour_from between 0 and 23),
  hour_to smallint not null default 17 check (hour_to between 1 and 24),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_promo_visits (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null,
  customer_id uuid not null,
  order_id uuid not null unique,
  visit_on date not null,
  minutes integer not null,
  amount bigint not null,
  coupon_id uuid,
  created_at timestamptz not null default now(),
  unique (customer_id, visit_on)
);
create index if not exists customer_promo_visits_open
  on public.customer_promo_visits (customer_id) where coupon_id is null;

create table if not exists public.customer_coupons (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null,
  customer_id uuid not null,
  code text not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'USED', 'EXPIRED')),
  free_minutes smallint not null,
  hour_from smallint not null,
  hour_to smallint not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  reminded_at timestamptz,
  used_at timestamptz,
  used_order_id uuid,
  used_amount bigint,
  created_at timestamptz not null default now(),
  unique (club_id, code)
);
create index if not exists customer_coupons_status on public.customer_coupons (club_id, status);
create index if not exists customer_coupons_customer on public.customer_coupons (customer_id, status);

alter table public.club_visit_promos enable row level security;
alter table public.customer_promo_visits enable row level security;
alter table public.customer_coupons enable row level security;
revoke all on public.club_visit_promos, public.customer_promo_visits, public.customer_coupons from anon;
revoke insert, update, delete on public.club_visit_promos, public.customer_promo_visits, public.customer_coupons from authenticated;
grant select on public.club_visit_promos, public.customer_promo_visits, public.customer_coupons to authenticated;

drop policy if exists club_visit_promos_read on public.club_visit_promos;
create policy club_visit_promos_read on public.club_visit_promos
  for select to authenticated using (app_is_club_member(club_id));
drop policy if exists customer_promo_visits_read on public.customer_promo_visits;
create policy customer_promo_visits_read on public.customer_promo_visits
  for select to authenticated using (app_is_club_member(club_id));
drop policy if exists customer_coupons_read on public.customer_coupons;
create policy customer_coupons_read on public.customer_coupons
  for select to authenticated using (app_is_club_member(club_id));

-- ------------------------------------------------------------- helpers ---

-- The client's language in the club bot -- the same rule as the bot's own
-- getLang: Uzbek only when they picked it.
create or replace function public.app_promo_lang(p_tg_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select case when (select language from bot_state where telegram_id = p_tg_id) = 'uz'
              then 'uz' else 'ru' end;
$$;

create or replace function public.app_promo_send_client(p_club_id uuid, p_tg_id bigint, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_token text;
begin
  if p_tg_id is null then return; end if;
  select bot_token into v_token from club_bots where club_id = p_club_id and active limit 1;
  if v_token is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('chat_id', p_tg_id, 'text', p_text, 'parse_mode', 'HTML'),
    timeout_milliseconds := 15000);
exception when others then null;
end;
$$;

create or replace function public.app_promo_who(p_customer_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(full_name), ''), 'Без имени')
         || coalesce(' · ' || nullif(phone, ''), '')
  from customers where id = p_customer_id;
$$;

-- Progress and coupons of one customer: what the cash desk, the bot and the
-- customer card show.
create or replace function public.app_promo_customer_json(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_c customers%rowtype;
  v_p club_visit_promos%rowtype;
  v_open integer;
  v_total integer;
  v_coupons jsonb;
begin
  select * into v_c from customers where id = p_customer_id;
  if not found then return null; end if;
  select * into v_p from club_visit_promos where club_id = v_c.club_id;
  if not found then return null; end if;
  select count(*) filter (where coupon_id is null), count(*) into v_open, v_total
    from customer_promo_visits where customer_id = p_customer_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'code', code, 'status', status, 'free_minutes', free_minutes,
           'hour_from', hour_from, 'hour_to', hour_to, 'issued_at', issued_at,
           'expires_at', expires_at, 'used_at', used_at, 'used_amount', used_amount,
           'used_order_id', used_order_id)
           order by issued_at desc), '[]'::jsonb)
    into v_coupons
    from customer_coupons where customer_id = p_customer_id;
  return jsonb_build_object(
    'enabled', v_p.enabled and (v_p.ends_at is null or now() < v_p.ends_at),
    'visits', v_open,
    'visits_total', v_total,
    'needed', v_p.visits_needed,
    'min_amount', v_p.min_amount,
    'min_minutes', v_p.min_minutes,
    'free_minutes', v_p.free_minutes,
    'hour_from', v_p.hour_from,
    'hour_to', v_p.hour_to,
    'ends_at', v_p.ends_at,
    'coupons', v_coupons);
end;
$$;

-- ----------------------------------------------------- counting a visit ---

-- Called from create_payment once an order is paid in full. Never raises:
-- a promo problem must not stop a payment.
create or replace function public.app_promo_after_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_o orders%rowtype;
  v_p club_visit_promos%rowtype;
  v_c customers%rowtype;
  v_tz text;
  v_seconds bigint;
  v_minutes integer;
  v_visit uuid;
  v_open integer;
  v_coupon customer_coupons%rowtype;
  v_code text;
  v_lang text;
  v_until text;
begin
  select * into v_o from orders where id = p_order_id;
  if not found or v_o.status <> 'COMPLETED' then return; end if;

  -- A coupon whose free hour was taken off this order again (another
  -- discount chosen over it) goes back to the customer.
  update customer_coupons cc
     set status = 'ACTIVE', used_at = null, used_order_id = null, used_amount = null
   where cc.used_order_id = p_order_id and cc.status = 'USED'
     and position(cc.code in coalesce(v_o.discount_reason, '')) = 0;

  if v_o.customer_id is null then return; end if;
  select * into v_p from club_visit_promos where club_id = v_o.club_id;
  if not found or not v_p.enabled then return; end if;
  if now() < v_p.starts_at or (v_p.ends_at is not null and now() >= v_p.ends_at) then return; end if;
  if v_o.total_amount < v_p.min_amount then return; end if;

  select coalesce(sum(coalesce(billable_seconds,
           greatest(0, extract(epoch from (coalesce(ended_at, now()) - started_at))::bigint
                       - coalesce(paused_seconds, 0)))), 0)
    into v_seconds
    from game_sessions where order_id = p_order_id and started_at >= v_p.starts_at;
  v_minutes := (v_seconds / 60)::integer;
  if v_minutes < v_p.min_minutes then return; end if;

  select coalesce(timezone, 'Asia/Tashkent') into v_tz from clubs where id = v_o.club_id;
  insert into customer_promo_visits (club_id, customer_id, order_id, visit_on, minutes, amount)
  values (v_o.club_id, v_o.customer_id, p_order_id, (now() at time zone v_tz)::date,
          v_minutes, v_o.total_amount)
  on conflict do nothing
  returning id into v_visit;
  if v_visit is null then return; end if;   -- one visit a day, one per order

  select * into v_c from customers where id = v_o.customer_id;
  v_lang := app_promo_lang(v_c.telegram_id);
  select count(*) into v_open from customer_promo_visits
   where customer_id = v_o.customer_id and coupon_id is null;

  if v_open < v_p.visits_needed then
    perform app_promo_send_client(v_o.club_id, v_c.telegram_id,
      case when v_lang = 'ru' then
        format(E'✅ <b>Визит засчитан: %s из %s</b>\nЕщё %s — и <b>1 час игры БЕСПЛАТНО</b> 🎁',
               v_open, v_p.visits_needed, v_p.visits_needed - v_open)
      else
        format(E'✅ <b>Tashrif hisoblandi: %s / %s</b>\nYana %s ta tashrif — va <b>1 soat o''yin BEPUL</b> 🎁',
               v_open, v_p.visits_needed, v_p.visits_needed - v_open)
      end);
    return;
  end if;

  -- Six collected: the coupon.
  loop
    v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from customer_coupons where club_id = v_o.club_id and code = v_code);
  end loop;
  insert into customer_coupons (club_id, customer_id, code, free_minutes, hour_from, hour_to, expires_at)
  values (v_o.club_id, v_o.customer_id, v_code, v_p.free_minutes, v_p.hour_from, v_p.hour_to,
          date_trunc('day', (now() at time zone v_tz) + make_interval(days => v_p.valid_days + 1)) at time zone v_tz)
  returning * into v_coupon;
  update customer_promo_visits set coupon_id = v_coupon.id
   where id in (select id from customer_promo_visits
                 where customer_id = v_o.customer_id and coupon_id is null
                 order by created_at limit v_p.visits_needed);

  v_until := to_char(v_coupon.expires_at at time zone v_tz - interval '1 minute', 'DD.MM.YYYY');
  perform app_promo_send_client(v_o.club_id, v_c.telegram_id,
    case when v_lang = 'ru' then
      format(E'🎉 <b>Поздравляем!</b>\nВы посетили клуб %s раз.\n\n🎁 <b>Купон на 1 час игры БЕСПЛАТНО</b> — ваш!\n🎟 Код: <code>%s</code>\n🕚 Каждый день с %s:00 до %s:00\n⏳ Действует до %s включительно — не придёте, купон сгорит.\n\nПокажите это сообщение на кассе 😉',
             v_p.visits_needed, v_code, lpad(v_p.hour_from::text, 2, '0'), lpad(v_p.hour_to::text, 2, '0'), v_until)
    else
      format(E'🎉 <b>Tabriklaymiz!</b>\nSiz klubga %s marta tashrif buyurdingiz.\n\n🎁 <b>1 soat BEPUL o''yin kuponi</b> sizniki!\n🎟 Kod: <code>%s</code>\n🕚 Har kuni %s:00 dan %s:00 gacha\n⏳ %s gacha amal qiladi — kelmasangiz kupon kuyadi.\n\nKassada ushbu xabarni ko''rsating 😉',
             v_p.visits_needed, v_code, lpad(v_p.hour_from::text, 2, '0'), lpad(v_p.hour_to::text, 2, '0'), v_until)
    end);
  perform app_notify_owner_bot(v_o.club_id,
    format(E'🎟 <b>Купон выдан</b>\nКлиент: %s\n%s визитов (от %s сум и %s мин)\nКод: <code>%s</code> · до %s%s',
           app_promo_who(v_o.customer_id), v_p.visits_needed, v_p.min_amount, v_p.min_minutes,
           v_code, v_until,
           case when v_c.telegram_id is null then E'\n⚠️ У клиента нет бота — скажите ему код на кассе.' else '' end));
  perform app_audit(v_o.club_id, 'promo.coupon_issued', 'customer', v_o.customer_id, null,
    to_jsonb(v_coupon), jsonb_build_object('order_id', p_order_id));
exception when others then
  raise warning 'app_promo_after_order %: %', p_order_id, sqlerrm;
end;
$$;

-- ------------------------------------------------- using the free hour ---

create or replace function public.promo_apply_coupon(p_order_id uuid, p_coupon_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_o orders%rowtype;
  v_cc customer_coupons%rowtype;
  v_tz text;
  v_start timestamptz;
  v_hour integer;
  v_seconds bigint;
  v_amount bigint;
  v_subtotal bigint;
  v_lang text;
begin
  select * into v_o from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_o.club_id, 'discount.apply');
  if v_o.status <> 'OPEN' then raise exception 'ORDER_NOT_OPEN' using errcode = 'P0001'; end if;

  select * into v_cc from customer_coupons where id = p_coupon_id for update;
  if not found or v_cc.club_id <> v_o.club_id then raise exception 'COUPON_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_o.customer_id is distinct from v_cc.customer_id then
    raise exception 'COUPON_OTHER_CUSTOMER' using errcode = 'P0001';
  end if;
  if v_cc.status <> 'ACTIVE' then raise exception 'COUPON_NOT_ACTIVE' using errcode = 'P0001'; end if;
  if v_cc.expires_at <= now() then raise exception 'COUPON_EXPIRED' using errcode = 'P0001'; end if;

  -- The free hour is for games started between hour_from and hour_to.
  select coalesce(timezone, 'Asia/Tashkent') into v_tz from clubs where id = v_o.club_id;
  select min(started_at), coalesce(sum(coalesce(billable_seconds,
           greatest(0, extract(epoch from (coalesce(ended_at, now()) - started_at))::bigint
                       - coalesce(paused_seconds, 0)))), 0)
    into v_start, v_seconds
    from game_sessions where order_id = p_order_id;
  v_hour := extract(hour from (coalesce(v_start, now()) at time zone v_tz))::integer;
  if v_hour < v_cc.hour_from or v_hour >= v_cc.hour_to then
    raise exception 'COUPON_OUTSIDE_HOURS' using errcode = 'P0001';
  end if;

  v_o := app_recalculate_order_totals(p_order_id);
  if v_o.time_amount <= 0 then raise exception 'COUPON_NO_TIME' using errcode = 'P0001'; end if;
  -- the price of free_minutes at this game's own rate; all of it if shorter
  v_amount := case when v_seconds <= v_cc.free_minutes * 60 then v_o.time_amount
                   else round(v_o.time_amount::numeric * v_cc.free_minutes * 60 / v_seconds)::bigint end;
  v_subtotal := v_o.items_amount + v_o.time_amount + v_o.deposit_amount;
  v_amount := least(v_amount, greatest(0, v_subtotal - v_o.discount_amount));

  update orders
     set discount_amount = discount_amount + v_amount,
         discount_reason = concat_ws(' + ', nullif(discount_reason, ''),
                                     format('Kupon %s (%s min bepul)', v_cc.code, v_cc.free_minutes)),
         discount_applies_to = coalesce(discount_applies_to, 'ALL')
   where id = p_order_id;
  v_o := app_recalculate_order_totals(p_order_id);

  update customer_coupons
     set status = 'USED', used_at = now(), used_order_id = p_order_id, used_amount = v_amount
   where id = p_coupon_id;

  perform app_audit(v_o.club_id, 'promo.coupon_used', 'order', p_order_id, null,
    jsonb_build_object('coupon_id', p_coupon_id, 'code', v_cc.code, 'amount', v_amount), '{}'::jsonb);
  perform app_notify_owner_bot(v_o.club_id,
    format(E'✅ <b>Купон использован</b>\nКлиент: %s\nКод: <code>%s</code> · скидка %s сум',
           app_promo_who(v_cc.customer_id), v_cc.code, v_amount));
  v_lang := app_promo_lang((select telegram_id from customers where id = v_cc.customer_id));
  perform app_promo_send_client(v_o.club_id, (select telegram_id from customers where id = v_cc.customer_id),
    case when v_lang = 'ru' then format(E'🎟 Купон <code>%s</code> использован — 1 час игры за счёт клуба. Приятной игры! 🎱', v_cc.code)
    else format(E'🎟 <code>%s</code> kuponi ishlatildi — 1 soat o''yin klub hisobidan. Yaxshi o''yin! 🎱', v_cc.code) end);

  return jsonb_build_object('order', app_order_json(p_order_id), 'coupon_amount', v_amount);
end;
$$;

-- Undo at the cash desk (wrong customer, changed their mind).
create or replace function public.promo_release_coupon(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_o orders%rowtype;
  v_cc customer_coupons%rowtype;
begin
  select * into v_o from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_o.club_id, 'discount.apply');
  if v_o.status <> 'OPEN' then raise exception 'ORDER_NOT_OPEN' using errcode = 'P0001'; end if;
  select * into v_cc from customer_coupons
   where used_order_id = p_order_id and status = 'USED' for update;
  if not found then return jsonb_build_object('order', app_order_json(p_order_id)); end if;

  update orders
     set discount_amount = greatest(0, discount_amount - coalesce(v_cc.used_amount, 0)),
         discount_reason = nullif(trim(both ' +' from
           replace(coalesce(discount_reason, ''), format('Kupon %s (%s min bepul)', v_cc.code, v_cc.free_minutes), '')), '')
   where id = p_order_id;
  perform app_recalculate_order_totals(p_order_id);
  update customer_coupons set status = 'ACTIVE', used_at = null, used_order_id = null, used_amount = null
   where id = v_cc.id;
  perform app_audit(v_o.club_id, 'promo.coupon_released', 'order', p_order_id, null,
    jsonb_build_object('coupon_id', v_cc.id, 'code', v_cc.code), '{}'::jsonb);
  return jsonb_build_object('order', app_order_json(p_order_id));
end;
$$;

-- What the payment sheet needs about the order's customer.
create or replace function public.promo_order_state(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_o orders%rowtype;
begin
  select * into v_o from orders where id = p_order_id;
  if not found or not app_is_club_member(v_o.club_id) then return null; end if;
  if v_o.customer_id is null then return null; end if;
  return app_promo_customer_json(v_o.customer_id);
end;
$$;

create or replace function public.promo_customer_state(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from customers where id = p_customer_id and app_is_club_member(club_id)) then
    return null;
  end if;
  return app_promo_customer_json(p_customer_id);
end;
$$;

-- Settings from the app (owner / managers).
create or replace function public.promo_save_settings(p_club_id uuid, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row club_visit_promos%rowtype;
begin
  perform app_require_permission(p_club_id, 'club.manage');
  insert into club_visit_promos (club_id) values (p_club_id) on conflict do nothing;
  update club_visit_promos set
    -- switching it on starts the count from now: older visits never count
    starts_at = case when not enabled and coalesce((p_settings->>'enabled')::boolean, enabled)
                     then now() else starts_at end,
    enabled = coalesce((p_settings->>'enabled')::boolean, enabled),
    visits_needed = coalesce((p_settings->>'visits_needed')::smallint, visits_needed),
    min_amount = coalesce((p_settings->>'min_amount')::bigint, min_amount),
    min_minutes = coalesce((p_settings->>'min_minutes')::smallint, min_minutes),
    free_minutes = coalesce((p_settings->>'free_minutes')::smallint, free_minutes),
    valid_days = coalesce((p_settings->>'valid_days')::smallint, valid_days),
    hour_from = coalesce((p_settings->>'hour_from')::smallint, hour_from),
    hour_to = coalesce((p_settings->>'hour_to')::smallint, hour_to),
    ends_at = case when p_settings ? 'ends_at' then (p_settings->>'ends_at')::timestamptz else ends_at end,
    updated_at = now()
  where club_id = p_club_id
  returning * into v_row;
  perform app_audit(p_club_id, 'promo.settings', 'club', p_club_id, null, to_jsonb(v_row), '{}'::jsonb);
  return to_jsonb(v_row);
end;
$$;

-- Numbers for the reports page and the staff bot.
create or replace function public.promo_stats(p_club_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not app_is_club_member(p_club_id) then return null; end if;
  return jsonb_build_object(
    'visits', (select count(*) from customer_promo_visits
                where club_id = p_club_id and created_at >= p_from and created_at < p_to),
    'issued', (select count(*) from customer_coupons
                where club_id = p_club_id and issued_at >= p_from and issued_at < p_to),
    'used', (select count(*) from customer_coupons
              where club_id = p_club_id and status = 'USED' and used_at >= p_from and used_at < p_to),
    'used_amount', (select coalesce(sum(used_amount), 0) from customer_coupons
                     where club_id = p_club_id and status = 'USED' and used_at >= p_from and used_at < p_to),
    'expired', (select count(*) from customer_coupons
                 where club_id = p_club_id and status = 'EXPIRED' and expires_at >= p_from and expires_at < p_to),
    'active', (select count(*) from customer_coupons
                where club_id = p_club_id and status = 'ACTIVE' and expires_at > now()));
end;
$$;

-- ------------------------------------------------ reminders and burning ---

create or replace function public.app_promo_sweep()
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_tz text;
  v_lang text;
begin
  -- a free hour put on a check that was then cancelled comes back
  update customer_coupons cc set status = 'ACTIVE', used_at = null, used_order_id = null, used_amount = null
    from orders o
   where o.id = cc.used_order_id and cc.status = 'USED' and o.status = 'CANCELLED';

  -- a day before: remind
  for r in
    select cc.*, c.telegram_id from customer_coupons cc join customers c on c.id = cc.customer_id
     where cc.status = 'ACTIVE' and cc.reminded_at is null
       and cc.expires_at > now() and cc.expires_at <= now() + interval '24 hours'
  loop
    update customer_coupons set reminded_at = now() where id = r.id;
    v_lang := app_promo_lang(r.telegram_id);
    perform app_promo_send_client(r.club_id, r.telegram_id,
      case when v_lang = 'ru' then
        format(E'⏳ <b>Завтра ваш купон сгорит!</b>\nПриходите сегодня с %s:00 до %s:00 — 1 час игры бесплатно.\n🎟 Код: <code>%s</code>',
               lpad(r.hour_from::text, 2, '0'), lpad(r.hour_to::text, 2, '0'), r.code)
      else
        format(E'⏳ <b>Kuponingiz ertaga kuyadi!</b>\nBugun %s:00 dan %s:00 gacha keling — 1 soat o''yin bepul.\n🎟 Kod: <code>%s</code>',
               lpad(r.hour_from::text, 2, '0'), lpad(r.hour_to::text, 2, '0'), r.code)
      end);
  end loop;

  -- past the date: burn
  for r in
    update customer_coupons set status = 'EXPIRED'
     where status = 'ACTIVE' and expires_at <= now()
    returning *
  loop
    v_lang := app_promo_lang((select telegram_id from customers where id = r.customer_id));
    perform app_promo_send_client(r.club_id, (select telegram_id from customers where id = r.customer_id),
      case when v_lang = 'ru' then format(E'🔥 Купон <code>%s</code> сгорел. Новые 6 визитов — новый бесплатный час!', r.code)
      else format(E'🔥 <code>%s</code> kuponi kuydi. Yangi 6 ta tashrif — yangi bepul soat!', r.code) end);
    perform app_notify_owner_bot(r.club_id,
      format(E'🔥 <b>Купон сгорел</b>\nКлиент: %s\nКод: <code>%s</code>', app_promo_who(r.customer_id), r.code));
    perform app_audit(r.club_id, 'promo.coupon_expired', 'customer', r.customer_id, null,
      jsonb_build_object('coupon_id', r.id, 'code', r.code), '{}'::jsonb);
  end loop;
exception when others then
  raise warning 'app_promo_sweep: %', sqlerrm;
end;
$$;

revoke all on function public.app_promo_after_order(uuid), public.app_promo_sweep(),
  public.app_promo_send_client(uuid, bigint, text), public.app_promo_lang(bigint),
  public.app_promo_who(uuid), public.app_promo_customer_json(uuid) from public, anon, authenticated;
revoke all on function public.promo_apply_coupon(uuid, uuid), public.promo_release_coupon(uuid),
  public.promo_order_state(uuid), public.promo_customer_state(uuid),
  public.promo_save_settings(uuid, jsonb), public.promo_stats(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.promo_apply_coupon(uuid, uuid), public.promo_release_coupon(uuid),
  public.promo_order_state(uuid), public.promo_customer_state(uuid),
  public.promo_save_settings(uuid, jsonb), public.promo_stats(uuid, timestamptz, timestamptz) to authenticated;

select cron.schedule('promo-coupon-sweep', '17 * * * *', 'select public.app_promo_sweep()');

-- ------------------------------------------- hooks into live functions ---
-- Patched in place (anchor replaced once) so nothing else in them changes.
do $patch$
declare
  v_def text;
  v_anchor text;
begin
  v_def := pg_get_functiondef('public.create_payment(uuid,jsonb,text)'::regprocedure);
  if position('app_promo_after_order' in v_def) = 0 then
    v_anchor := E'  perform app_audit(v_order.club_id, ''payment.create'', ''order'', p_order_id, null,';
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'create_payment anchor not found exactly once';
    end if;
    execute replace(v_def, v_anchor,
      E'  if v_order.status = ''COMPLETED'' then\n'
      || E'    begin\n      perform app_promo_after_order(p_order_id);\n'
      || E'    exception when others then null;\n    end;\n  end if;\n\n'
      || v_anchor);
  end if;

  v_def := pg_get_functiondef('public.bot_player_card(uuid,bigint)'::regprocedure);
  if position('app_promo_customer_json' in v_def) = 0 then
    v_anchor := E'''active_reservation'', v_active';
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'bot_player_card anchor not found exactly once';
    end if;
    execute replace(v_def, v_anchor,
      v_anchor || E',\n    ''promo'', app_promo_customer_json(v_c.id)');
  end if;
end
$patch$;

-- New customers (registered in the bot) and coupons reach the cash desk at
-- once: the app already listens, the tables were just not published.
do $pub$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'customers') then
    alter publication supabase_realtime add table public.customers;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'customer_coupons') then
    alter publication supabase_realtime add table public.customer_coupons;
  end if;
end
$pub$;
