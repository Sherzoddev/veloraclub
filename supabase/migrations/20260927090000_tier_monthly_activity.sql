-- Monthly activity check for loyalty levels. A client who spent less than
-- clubs.tier_min_monthly_spend in a calendar month (club time) drops one
-- level and gets a Telegram message; a later month at or above the bar
-- brings one level back. Levels come from lifetime total_spent, so the drop
-- is kept as customers.tier_penalty (levels below the spend-based one)
-- rather than by editing tier_id, which every payment recomputes.

alter table public.customers
  add column if not exists tier_penalty smallint not null default 0 check (tier_penalty >= 0);

alter table public.clubs
  add column if not exists tier_min_monthly_spend bigint check (tier_min_monthly_spend is null or tier_min_monthly_spend > 0),
  add column if not exists tier_activity_from date,
  add column if not exists tier_activity_checked_month date;

comment on column public.clubs.tier_min_monthly_spend is
  'Monthly spend a client needs to keep their loyalty level; null turns the check off.';
comment on column public.clubs.tier_activity_from is
  'First month the activity check looks at (months before it are never judged).';

-- Spend-based level, lowered by the client's penalty, never below the lowest.
create or replace function public.app_tier_for_customer(p_club_id uuid, p_total_spent bigint, p_penalty integer)
returns loyalty_tiers
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    (select * from loyalty_tiers
      where club_id = p_club_id and active and min_total_spent <= greatest(0, p_total_spent)
      order by min_total_spent desc
      offset greatest(0, coalesce(p_penalty, 0)) limit 1)
    union all
    (select * from loyalty_tiers
      where club_id = p_club_id and active
      order by min_total_spent
      limit 1)
  ) t
  limit 1;
$$;

create or replace function public.app_refresh_customer_tier(p_customer_id uuid)
returns loyalty_tiers
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_customer customers%rowtype;
  v_tier loyalty_tiers%rowtype;
begin
  select * into v_customer from customers where id = p_customer_id;
  if not found then return null; end if;

  perform seed_loyalty_tiers(v_customer.club_id);
  select * into v_tier from app_tier_for_customer(v_customer.club_id, v_customer.total_spent, v_customer.tier_penalty);

  if v_tier.id is not null and v_customer.tier_id is distinct from v_tier.id then
    update customers set tier_id = v_tier.id where id = p_customer_id;
    perform app_audit(v_customer.club_id, 'customer.tier_change', 'customer', p_customer_id,
      jsonb_build_object('from', v_customer.tier_id),
      jsonb_build_object('to', v_tier.id, 'tier', v_tier.name), '{}'::jsonb);
  end if;

  return v_tier;
end;
$$;

create or replace function public.app_refresh_club_tiers(p_club_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_count integer := 0;
begin
  perform app_require_permission(p_club_id, 'club.manage');

  update customers c
     set tier_id = (app_tier_for_customer(p_club_id, c.total_spent, c.tier_penalty)).id
   where c.club_id = p_club_id
     and c.tier_id is distinct from (app_tier_for_customer(p_club_id, c.total_spent, c.tier_penalty)).id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- What a client paid in a calendar month of club time (the current month
-- when p_month is null): completed orders, by when they were closed.
create or replace function public.app_customer_month_spend(p_customer_id uuid, p_month date default null)
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $$
  with b as (
    select cl.id as club_id, coalesce(cl.timezone, 'UTC') as tz,
           coalesce(p_month, date_trunc('month', now() at time zone coalesce(cl.timezone, 'UTC'))::date) as m
    from customers cu join clubs cl on cl.id = cu.club_id
    where cu.id = p_customer_id
  )
  select coalesce(sum(o.total_amount), 0)::bigint
  from b join orders o on o.club_id = b.club_id
  where o.customer_id = p_customer_id and o.status = 'COMPLETED'
    and coalesce(o.closed_at, o.created_at) >= (date_trunc('month', b.m)::timestamp at time zone b.tz)
    and coalesce(o.closed_at, o.created_at) < ((date_trunc('month', b.m) + interval '1 month')::timestamp at time zone b.tz);
$$;

-- Judges one club's clients for one month: below the bar drops a level (if
-- there is one to drop), at or above it gives back one dropped level. Only
-- clients who were already in the club when the month began are judged.
create or replace function public.app_tier_activity_check_club(p_club_id uuid, p_month date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_club clubs%rowtype;
  v_token text;
  v_month date := date_trunc('month', p_month)::date;
  v_from timestamptz;
  r record;
  v_spend bigint;
  v_old loyalty_tiers%rowtype;
  v_new loyalty_tiers%rowtype;
  v_lowest uuid;
  v_ru boolean;
  v_name text;
  v_text text;
  v_bar text;
  v_demoted integer := 0;
  v_restored integer := 0;
begin
  select * into v_club from clubs where id = p_club_id;
  if not found or v_club.tier_min_monthly_spend is null then
    return jsonb_build_object('demoted', 0, 'restored', 0);
  end if;
  v_from := v_month::timestamp at time zone coalesce(v_club.timezone, 'UTC');
  v_bar := replace(to_char(v_club.tier_min_monthly_spend, 'FM999,999,999,999'), ',', ' ');
  select bot_token into v_token from club_bots where club_id = p_club_id and active limit 1;
  select id into v_lowest from loyalty_tiers where club_id = p_club_id and active order by min_total_spent limit 1;

  for r in
    select cu.id, cu.full_name, cu.telegram_id, cu.total_spent, cu.tier_penalty, cu.tier_id, bs.language,
           exists (select 1 from club_bot_users bu
                   where bu.club_id = cu.club_id and bu.telegram_id = cu.telegram_id
                     and bu.role = 'CLIENT' and bu.terms_accepted_at is not null) as reachable
    from customers cu
    left join bot_state bs on bs.telegram_id = cu.telegram_id
    where cu.club_id = p_club_id
      and cu.active is not false and cu.archived_at is null
      and cu.created_at < v_from
      and (cu.tier_penalty > 0 or cu.tier_id is distinct from v_lowest)
  loop
    v_spend := app_customer_month_spend(r.id, v_month);
    select * into v_old from app_tier_for_customer(p_club_id, r.total_spent, r.tier_penalty);

    if v_spend < v_club.tier_min_monthly_spend then
      continue when v_old.id is not distinct from v_lowest;
      update customers set tier_penalty = tier_penalty + 1 where id = r.id;
      select * into v_new from app_refresh_customer_tier(r.id);
      -- The Mini App celebrates any tier change it hasn't shown yet; a drop
      -- is marked as seen so it never greets the client with confetti.
      update customers set level_seen_tier_id = v_new.id where id = r.id;
      v_demoted := v_demoted + 1;
    elsif r.tier_penalty > 0 then
      update customers set tier_penalty = tier_penalty - 1 where id = r.id;
      select * into v_new from app_refresh_customer_tier(r.id);
      v_restored := v_restored + 1;
    else
      continue;
    end if;

    perform app_audit(p_club_id, 'customer.tier_activity', 'customer', r.id,
      jsonb_build_object('tier', v_old.name, 'penalty', r.tier_penalty),
      jsonb_build_object('tier', v_new.name),
      jsonb_build_object('month', v_month, 'spent', v_spend, 'required', v_club.tier_min_monthly_spend));

    continue when v_token is null or r.telegram_id is null or not r.reachable
      or v_new.id is not distinct from v_old.id;

    v_ru := r.language = 'ru';
    v_name := app_html(split_part(coalesce(nullif(trim(r.full_name), ''),
      case when v_ru then 'друг' else 'do''stim' end), ' ', 1));
    if v_spend < v_club.tier_min_monthly_spend then
      v_text := case when v_ru then format(
          E'📉 %s, в прошлом месяце вы были не очень активным участником клуба <b>%s</b>, поэтому ваш уровень снизился: <b>%s</b> → <b>%s</b>.\n\nПосещайте наш клуб чаще: от %s сум за месяц — и уровень вернётся. Ждём вас! ⚪',
          v_name, app_html(v_club.name), app_html(v_old.name), app_html(v_new.name), v_bar)
        else format(
          E'📉 %s, o''tgan oyda <b>%s</b> klubida faol bo''lmadingiz, shuning uchun darajangiz pasaydi: <b>%s</b> → <b>%s</b>.\n\nKlubimizga tez-tez keling: oyiga %s so''mdan ko''p — va darajangiz qaytadi. Sizni kutamiz! ⚪',
          v_name, app_html(v_club.name), app_html(v_old.name), app_html(v_new.name), v_bar)
        end;
    else
      v_text := case when v_ru then format(
          E'🎉 %s, спасибо за активность в прошлом месяце! Ваш уровень в <b>%s</b> восстановлен: <b>%s</b> → <b>%s</b>.',
          v_name, app_html(v_club.name), app_html(v_old.name), app_html(v_new.name))
        else format(
          E'🎉 %s, o''tgan oydagi faolligingiz uchun rahmat! <b>%s</b>dagi darajangiz tiklandi: <b>%s</b> → <b>%s</b>.',
          v_name, app_html(v_club.name), app_html(v_old.name), app_html(v_new.name))
        end;
    end if;

    perform net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      headers := '{"Content-Type": "application/json"}'::jsonb,
      body := jsonb_build_object(
        'chat_id', r.telegram_id, 'text', v_text, 'parse_mode', 'HTML',
        'reply_markup', jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', case when v_ru then '📅 Забронировать' else '📅 Band qilish' end,
                             'callback_data', 'wb:book'))))),
      timeout_milliseconds := 15000
    );
  end loop;

  return jsonb_build_object('demoted', v_demoted, 'restored', v_restored);
end;
$$;

-- Hourly; on the 1st of the month from 10:00 club time it judges the month
-- that just ended, once per club.
create or replace function public.app_run_tier_activity_checks()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  c record;
  v_local timestamp;
  v_prev date;
  v_done integer := 0;
begin
  for c in
    select id, timezone, tier_activity_from, tier_activity_checked_month
    from clubs where tier_min_monthly_spend is not null and archived_at is null
  loop
    v_local := now() at time zone coalesce(c.timezone, 'UTC');
    continue when extract(day from v_local) <> 1 or extract(hour from v_local) < 10;
    v_prev := (date_trunc('month', v_local) - interval '1 month')::date;
    continue when c.tier_activity_from is not null and v_prev < c.tier_activity_from;
    continue when c.tier_activity_checked_month is not distinct from v_prev;

    update clubs set tier_activity_checked_month = v_prev where id = c.id;
    perform app_tier_activity_check_club(c.id, v_prev);
    v_done := v_done + 1;
  end loop;
  return v_done;
end;
$$;

revoke execute on function public.app_tier_for_customer(uuid, bigint, integer) from public, anon, authenticated;
revoke execute on function public.app_customer_month_spend(uuid, date) from public, anon, authenticated;
revoke execute on function public.app_tier_activity_check_club(uuid, date) from public, anon, authenticated;
revoke execute on function public.app_run_tier_activity_checks() from public, anon, authenticated;

-- The client card: while a client is below their spend-based level, "to the
-- next level" is what's left of this month's bar, since that is what brings
-- the level back.
do $$
declare
  v_def text := pg_get_functiondef('public.bot_player_card(uuid, bigint)'::regprocedure);
  v_old text := 'else greatest(0, v_next.min_total_spent - v_c.total_spent) end';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'bot_player_card: to_next expression not found';
  end if;
  execute replace(v_def, v_old,
    'when v_c.tier_penalty > 0 and v_next.min_total_spent <= v_c.total_spent then '
    || 'greatest(0, coalesce((select tier_min_monthly_spend from clubs where id = p_club_id), 0) '
    || '- app_customer_month_spend(v_c.id)) '
    || v_old);
end $$;

select cron.schedule('tier-activity-check', '7 * * * *', 'select public.app_run_tier_activity_checks()');

-- The bar is set per club, e.g.:
--   update clubs set tier_min_monthly_spend = 250000, tier_activity_from = '2026-10-01' where id = ...;
