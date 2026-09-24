-- 1) Telegram push to the referrer the moment their reward is credited.
--    Fires from the same trigger that awards the bonus, via pg_net (async,
--    fire-and-forget — a failed push must not roll back the order).
create or replace function public.reward_customer_referral()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referral customer_referrals%rowtype;
  v_reward bigint;
  v_referrer_chat bigint;
  v_bot_token text;
  v_referred_name text;
begin
  if new.customer_id is null
     or new.status <> 'COMPLETED'
     or old.status is not distinct from 'COMPLETED' then
    return new;
  end if;

  select * into v_referral
  from customer_referrals
  where club_id = new.club_id
    and referred_customer_id = new.customer_id
    and status = 'LINKED'
  for update;

  if not found or v_referral.referrer_customer_id = new.customer_id then
    return new;
  end if;

  v_reward := floor(new.total_amount * v_referral.reward_percent / 100.0)::bigint;

  update customer_referrals
  set status = 'REWARDED', reward_amount = v_reward,
      reward_order_id = new.id, rewarded_at = now()
  where id = v_referral.id and status = 'LINKED';

  if found and v_reward > 0 then
    update customers
    set bonus_points = bonus_points + v_reward
    where id = v_referral.referrer_customer_id
      and club_id = new.club_id and active and archived_at is null
    returning telegram_id into v_referrer_chat;

    insert into audit_logs (
      club_id, action, entity_type, entity_id, metadata
    ) values (
      new.club_id, 'customer.referral_reward', 'customer',
      v_referral.referrer_customer_id,
      jsonb_build_object(
        'points', v_reward,
        'percent', v_referral.reward_percent,
        'order_id', new.id,
        'referred_customer_id', new.customer_id
      )
    );

    if v_referrer_chat is not null then
      select bot_token into v_bot_token
      from club_bots where club_id = new.club_id and active limit 1;

      if v_bot_token is not null then
        select coalesce(full_name, 'Друг') into v_referred_name
        from customers where id = new.customer_id;

        perform net.http_post(
          url := 'https://api.telegram.org/bot' || v_bot_token || '/sendMessage',
          headers := jsonb_build_object('content-type', 'application/json'),
          body := jsonb_build_object(
            'chat_id', v_referrer_chat,
            'text', '🎁 ' || v_referred_name || ' оплатил(а) первый чек — вам начислено ' ||
                    v_reward || ' бонусов за приглашение!'
          )
        );
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.reward_customer_referral() is
  'Awards the referrer bonus and pushes them a Telegram message via pg_net the moment it lands.';

-- 2) bot_player_card now also returns the customer''s active reservation, so
--    the Mini App''s bootstrap/"me" call needs one DB round trip instead of two.
--    The project''s Supabase region is far from its userbase (~9000km), so every
--    extra round trip costs real, felt latency — this is the main lever available
--    without a full project migration.
create or replace function public.bot_player_card(p_club_id uuid, p_tg_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare
  v_c customers%rowtype;
  v_tier loyalty_tiers%rowtype;
  v_next loyalty_tiers%rowtype;
  v_active jsonb;
begin
  select * into v_c
  from customers
  where club_id = p_club_id and telegram_id = p_tg_id
    and active and archived_at is null
  limit 1;

  if not found then return jsonb_build_object('ok', false); end if;

  select * into v_tier from loyalty_tiers where id = v_c.tier_id;
  select * into v_next
  from loyalty_tiers
  where club_id = p_club_id
    and active
    and min_total_spent > coalesce(v_tier.min_total_spent, -1)
  order by min_total_spent
  limit 1;

  select jsonb_build_object(
    'id', r.id, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
    'status', r.status, 'resource_name', res.name
  )
  into v_active
  from reservations r
  join resources res on res.id = r.resource_id
  where r.club_id = p_club_id and r.customer_id = v_c.id
    and r.status in ('pending', 'confirmed', 'arrived')
    and r.ends_at >= now()
  order by r.starts_at
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'id', v_c.id,
    'card_token', v_c.card_token,
    'tier_id', v_c.tier_id,
    'level_seen_tier_id', v_c.level_seen_tier_id,
    'name', coalesce(v_c.full_name, 'Игрок'),
    'phone', v_c.phone,
    'bonus_points', v_c.bonus_points,
    'balance', v_c.balance,
    'debt', v_c.debt_amount,
    'visits', v_c.visits_count,
    'total_spent', v_c.total_spent,
    'tier', coalesce(v_tier.name, 'Участник'),
    'tier_color', v_tier.color,
    'earn_percent', coalesce(v_tier.earn_percent, 0),
    'discount_percent', greatest(coalesce(v_tier.discount_percent, 0), v_c.discount_percent),
    'next_tier', v_next.name,
    'next_min_total_spent', v_next.min_total_spent,
    'to_next', case when v_next.id is null then null
                    else greatest(0, v_next.min_total_spent - v_c.total_spent) end,
    'active_reservation', v_active
  );
end;
$$;

revoke all on function public.bot_player_card(uuid, bigint) from public, anon, authenticated;
grant execute on function public.bot_player_card(uuid, bigint) to service_role;

-- 3) Resources + their live session status in one round trip instead of two.
create or replace function public.bot_resources_with_status(p_club_id uuid)
returns jsonb
language sql
stable security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', r.id, 'name', r.name, 'number', r.number, 'photo_url', r.photo_url,
      'status', r.status, 'sort_order', r.sort_order, 'zone', r.zone, 'notes', r.notes,
      'type_name', rt.name, 'family', rt.family,
      'price_per_hour', tf.price_per_hour,
      'session_status', gs.status,
      'session_started_at', gs.started_at,
      'session_planned_end_at', gs.planned_end_at
    ) order by r.sort_order, r.number
  ), '[]'::jsonb)
  from resources r
  left join resource_types rt on rt.id = r.resource_type_id
  left join tariffs tf on tf.id = r.default_tariff_id
  left join lateral (
    select status, started_at, planned_end_at
    from game_sessions
    where resource_id = r.id and status in ('ACTIVE', 'PAUSED')
    order by started_at desc
    limit 1
  ) gs on true
  where r.club_id = p_club_id and r.active and r.archived_at is null;
$$;

revoke all on function public.bot_resources_with_status(uuid) from public, anon, authenticated;
grant execute on function public.bot_resources_with_status(uuid) to service_role;

-- 4) Availability check: resource-exists guard + reservations + sessions used
--    to be three sequential round trips; now it's one.
create or replace function public.bot_resource_busy_ranges(
  p_club_id uuid, p_resource_id uuid, p_from timestamptz, p_until timestamptz
) returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare
  v_exists boolean;
  v_ranges jsonb;
begin
  select exists(
    select 1 from resources
    where id = p_resource_id and club_id = p_club_id and active and archived_at is null
  ) into v_exists;

  if not v_exists then
    return jsonb_build_object('ok', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('starts_at', starts_at, 'ends_at', ends_at)), '[]'::jsonb)
  into v_ranges
  from (
    select starts_at, ends_at
    from reservations
    where club_id = p_club_id and resource_id = p_resource_id
      and status in ('pending', 'confirmed', 'arrived')
      and starts_at < p_until and ends_at > p_from
    union all
    select started_at as starts_at, planned_end_at as ends_at
    from game_sessions
    where club_id = p_club_id and resource_id = p_resource_id
      and status in ('ACTIVE', 'PAUSED') and planned_end_at is not null
  ) x;

  return jsonb_build_object('ok', true, 'ranges', v_ranges);
end;
$$;

revoke all on function public.bot_resource_busy_ranges(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.bot_resource_busy_ranges(uuid, uuid, timestamptz, timestamptz) to service_role;
