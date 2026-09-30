-- "To'lov summasi bo'yicha vaqt": a table started for a sum (30 000 = 30 min
-- at 60 000/h) had its light cut when the time ran out, but the session kept
-- counting until the cashier pressed "Yakunlash". Finished 3 min late, the
-- receipt said 34 000 for 30 paid minutes. And the sum itself was never saved
-- (the app sent p_prepaid_amount = 0).
--
-- Now:
--  * billing stops at planned_end_at -- the moment the light goes off;
--  * the sum typed at start is kept in prepaid_amount and the time charge
--    never goes above it (rounding up to whole minutes can't add a few sum);
--  * with a sum the planned end is exact to the second, not rounded minutes;
--  * a pause shifts the planned end by its length (paid time isn't used up
--    while the table is paused);
--  * "Davom ettirish" after time ran out starts the extra time from now: the
--    minutes the table stood dark are not billed, and the extra sum is added
--    to prepaid_amount.

-- Seconds of play in the current round, stopped at the planned end.
create or replace function public.app_session_active_seconds(p_session game_sessions, p_at timestamp with time zone default now())
returns integer
language plpgsql
immutable
as $$
declare
  v_end timestamptz;
  v_wall integer;
  v_paused integer;
begin
  v_end := coalesce(p_session.ended_at, p_at);
  if p_session.status = 'PAUSED' and p_session.pause_started_at is not null then
    v_end := least(v_end, p_session.pause_started_at);
  end if;
  if p_session.planned_end_at is not null then
    v_end := least(v_end, p_session.planned_end_at);
  end if;
  v_wall := greatest(0, extract(epoch from (v_end - p_session.started_at))::integer);
  v_paused := p_session.paused_seconds;
  return greatest(0, v_wall - v_paused);
end;
$$;

-- Live charge (session_current_charge): capped at the sum paid for.
create or replace function public.app_calculate_session_charge(p_session game_sessions, p_at timestamp with time zone default now())
returns jsonb
language plpgsql
immutable
as $$
declare
  s jsonb := p_session.tariff_snapshot;
  v_active_seconds integer;
  v_rounding integer;
  v_minimum_minutes integer;
  v_minimum_charge bigint;
  v_kind text;
  v_price_per_hour bigint;
  v_package_minutes integer;
  v_package_price bigint;
  v_billable_minutes integer;
  v_overtime_minutes integer := 0;
  v_amount bigint;
begin
  v_active_seconds := app_session_active_seconds(p_session, p_at);

  v_kind            := coalesce(s ->> 'kind', 'HOURLY');
  v_price_per_hour  := coalesce((s ->> 'price_per_hour')::bigint, 0);
  v_rounding        := greatest(1, coalesce((s ->> 'rounding_minutes')::integer, 1));
  v_minimum_minutes := greatest(0, coalesce((s ->> 'minimum_minutes')::integer, 0));
  v_minimum_charge  := greatest(0, coalesce((s ->> 'minimum_charge')::bigint, 0));
  v_package_minutes := (s ->> 'package_minutes')::integer;
  v_package_price   := (s ->> 'package_price')::bigint;

  v_billable_minutes := ceil(v_active_seconds::numeric / 60.0 / v_rounding)::integer * v_rounding;
  v_billable_minutes := greatest(v_billable_minutes, v_minimum_minutes);

  if v_kind = 'PACKAGE' and v_package_minutes is not null then
    if v_billable_minutes <= v_package_minutes then
      v_amount := coalesce(v_package_price, 0);
    else
      v_overtime_minutes := v_billable_minutes - v_package_minutes;
      v_amount := coalesce(v_package_price, 0)
                + round(v_price_per_hour::numeric * v_overtime_minutes / 60.0)::bigint;
    end if;
  else
    v_amount := round(v_price_per_hour::numeric * v_billable_minutes / 60.0)::bigint;
  end if;

  v_amount := greatest(v_amount, v_minimum_charge);
  if coalesce(p_session.prepaid_amount, 0) > 0 then
    v_amount := least(v_amount, p_session.prepaid_amount);
  end if;

  return jsonb_build_object(
    'active_seconds', v_active_seconds,
    'billable_minutes', v_billable_minutes,
    'overtime_minutes', v_overtime_minutes,
    'time_amount', v_amount,
    'kind', v_kind,
    'price_per_hour', v_price_per_hour,
    'rounding_minutes', v_rounding,
    'minimum_minutes', v_minimum_minutes,
    'prepaid_amount', p_session.prepaid_amount,
    'planned_end_at', p_session.planned_end_at,
    'calculated_at', p_at
  );
end;
$$;

-- Start: a sum makes the planned end exact to the second.
create or replace function public.start_game_session(
  p_club_id uuid, p_resource_id uuid, p_tariff_id uuid default null::uuid,
  p_billing_mode text default 'POSTPAID'::text, p_customer_id uuid default null::uuid,
  p_players_count integer default 1, p_comment text default null::text,
  p_prepaid_amount bigint default 0, p_planned_minutes integer default null::integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_resource resources%rowtype;
  v_tariff_id uuid;
  v_snapshot jsonb;
  v_session game_sessions%rowtype;
  v_order orders%rowtype;
  v_shift_id uuid;
  v_needs_relay boolean;
  v_command_id uuid;
  v_relay_device jsonb;
  v_status text;
  v_now timestamptz := now();
  v_prepaid bigint := greatest(0, coalesce(p_prepaid_amount, 0));
  v_pph bigint;
  v_planned_end timestamptz;
begin
  perform app_require_permission(p_club_id, 'session.start');

  select * into v_resource
  from resources
  where id = p_resource_id and club_id = p_club_id
  for update;

  if not found then
    raise exception 'RESOURCE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not v_resource.active then
    raise exception 'RESOURCE_INACTIVE' using errcode = 'P0001';
  end if;
  if v_resource.status = 'MAINTENANCE' then
    raise exception 'RESOURCE_IN_MAINTENANCE' using errcode = 'P0001';
  end if;

  select * into v_session
  from game_sessions
  where club_id = p_club_id
    and resource_id = p_resource_id
    and status in ('STARTING', 'ACTIVE', 'PAUSED', 'STOPPING')
  order by started_at desc
  limit 1
  for update;

  if found then
    select * into v_order from orders where id = v_session.order_id;
    return jsonb_build_object(
      'session', to_jsonb(v_session),
      'order', to_jsonb(v_order),
      'relay_command_id', null,
      'server_time', v_now,
      'already_active', true
    );
  end if;

  v_shift_id := app_current_shift_id(p_club_id);
  if v_shift_id is null then
    raise exception 'NO_OPEN_SHIFT' using errcode = 'P0001';
  end if;

  v_tariff_id := coalesce(p_tariff_id, v_resource.default_tariff_id);
  if v_tariff_id is null then
    raise exception 'TARIFF_REQUIRED' using errcode = 'P0001';
  end if;

  v_snapshot := app_build_tariff_snapshot(v_tariff_id, v_now);
  v_pph := coalesce((v_snapshot ->> 'price_per_hour')::bigint, 0);
  v_planned_end := case
    when v_prepaid > 0 and v_pph > 0 and coalesce(v_snapshot ->> 'kind', 'HOURLY') = 'HOURLY'
      then v_now + make_interval(secs => round(v_prepaid * 3600.0 / v_pph)::double precision)
    when p_planned_minutes is not null
      then v_now + make_interval(mins => p_planned_minutes)
  end;

  v_needs_relay := v_resource.relay_device_id is not null
    and not v_resource.relay_demo_mode;
  v_status := case when v_needs_relay then 'STARTING' else 'ACTIVE' end;

  insert into game_sessions (
    club_id, resource_id, customer_id, cash_shift_id, tariff_id,
    tariff_snapshot, billing_mode, status, players_count, started_at,
    planned_end_at, prepaid_amount, comment, started_by,
    expected_relay_state, relay_ok
  ) values (
    p_club_id, p_resource_id, p_customer_id, v_shift_id, v_tariff_id,
    v_snapshot, p_billing_mode, v_status,
    greatest(1, coalesce(p_players_count, 1)), v_now,
    v_planned_end, v_prepaid, p_comment, auth.uid(), 'ON',
    case when v_needs_relay then null else true end
  ) returning * into v_session;

  insert into orders (
    club_id, session_id, customer_id, cash_shift_id, status, opened_by
  ) values (
    p_club_id, v_session.id, p_customer_id, v_shift_id, 'OPEN', auth.uid()
  ) returning * into v_order;

  update game_sessions
  set order_id = v_order.id
  where id = v_session.id
  returning * into v_session;

  update resources set status = 'ACTIVE' where id = p_resource_id;

  if v_resource.relay_device_id is not null then
    v_command_id := app_enqueue_relay_command(
      p_club_id, p_resource_id, 'ON', v_session.id, 'session start'
    );
    select jsonb_build_object(
      'channel', v_resource.relay_channel,
      'provider', rd.provider,
      'direct_control', rd.direct_control,
      'configuration', rd.configuration
    ) into v_relay_device
    from relay_devices rd where rd.id = v_resource.relay_device_id;
  end if;

  perform app_audit(
    p_club_id, 'session.start', 'game_session', v_session.id, null,
    to_jsonb(v_session),
    jsonb_build_object(
      'resource', v_resource.name,
      'relay_command_id', v_command_id
    )
  );

  return jsonb_build_object(
    'session', to_jsonb(v_session),
    'order', to_jsonb(v_order),
    'relay_command_id', v_command_id,
    'relay_device', v_relay_device,
    'server_time', v_now,
    'already_active', false
  );
end;
$$;

-- Resume: the paused minutes move the planned end, they aren't used up.
create or replace function public.resume_game_session(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_session game_sessions%rowtype;
  v_now timestamptz := now();
  v_pause_seconds integer;
  v_command_id uuid;
begin
  select * into v_session from game_sessions where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_session.club_id, 'session.pause');
  if v_session.status <> 'PAUSED' then raise exception 'SESSION_NOT_PAUSED' using errcode = 'P0001'; end if;

  v_pause_seconds := greatest(0, extract(epoch from (v_now - v_session.pause_started_at))::integer);

  update session_pauses set resumed_at = v_now, duration_seconds = v_pause_seconds, resumed_by = auth.uid()
  where session_id = p_session_id and resumed_at is null;

  update game_sessions
  set status = 'ACTIVE', pause_started_at = null,
      paused_seconds = paused_seconds + v_pause_seconds, expected_relay_state = 'ON',
      planned_end_at = planned_end_at + make_interval(secs => v_pause_seconds)
  where id = p_session_id returning * into v_session;

  update resources set status = 'ACTIVE' where id = v_session.resource_id;

  if exists (select 1 from resources where id = v_session.resource_id and relay_device_id is not null) then
    v_command_id := app_enqueue_relay_command(v_session.club_id, v_session.resource_id, 'ON', p_session_id, 'session resume');
  end if;

  perform app_audit(v_session.club_id, 'session.resume', 'game_session', p_session_id,
    null, to_jsonb(v_session), jsonb_build_object('paused_seconds', v_pause_seconds));

  return jsonb_build_object('session', to_jsonb(v_session), 'relay_command_id', v_command_id, 'server_time', v_now);
end;
$$;

-- Finish: billed up to the planned end, never above the sum paid for.
create or replace function public.finish_game_session(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_session game_sessions%rowtype;
  v_resource resources%rowtype;
  v_charge jsonb;
  v_now timestamptz := now();
  v_order orders%rowtype;
  v_command_id uuid;
  v_relay_device jsonb;
  v_pause_seconds integer;
  v_last_seconds integer;
  v_total_seconds integer;
  v_total_amount bigint;
  v_tariff_name text;
  v_tz text;
  v_round record;
  v_allocated bigint := 0;
  v_share bigint;
  v_rounds_count integer;
  v_index integer := 0;
begin
  select * into v_session from game_sessions where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_session.club_id, 'session.finish');
  if v_session.status not in ('ACTIVE', 'PAUSED', 'STARTING') then
    raise exception 'SESSION_NOT_OPEN' using errcode = 'P0001';
  end if;

  if v_session.status = 'PAUSED' and v_session.pause_started_at is not null then
    v_pause_seconds := greatest(0, extract(epoch from (v_now - v_session.pause_started_at))::integer);
    update session_pauses set resumed_at = v_now, duration_seconds = v_pause_seconds, resumed_by = auth.uid()
    where session_id = p_session_id and resumed_at is null;
    update game_sessions
    set paused_seconds = paused_seconds + v_pause_seconds, pause_started_at = null, status = 'ACTIVE',
        planned_end_at = planned_end_at + make_interval(secs => v_pause_seconds)
    where id = p_session_id returning * into v_session;
  end if;

  v_last_seconds := app_session_active_seconds(v_session, v_now);

  insert into session_rounds (club_id, session_id, round_number, started_at, ended_at, billable_seconds, amount)
  values (v_session.club_id, p_session_id, v_session.round_number, v_session.started_at, v_now, v_last_seconds, 0);

  v_total_seconds := v_session.banked_seconds + v_last_seconds;
  v_charge := app_charge_for_seconds(v_session.tariff_snapshot, v_total_seconds);
  v_total_amount := (v_charge ->> 'time_amount')::bigint;
  if v_session.prepaid_amount > 0 and v_total_amount > v_session.prepaid_amount then
    v_total_amount := v_session.prepaid_amount;
    v_charge := v_charge || jsonb_build_object('time_amount', v_total_amount);
  end if;

  v_charge := v_charge || jsonb_build_object(
    'rounds', v_session.round_number,
    'total_time_amount', v_total_amount,
    'total_active_seconds', v_total_seconds,
    'prepaid_amount', v_session.prepaid_amount
  );

  update game_sessions
  set status = 'COMPLETED', ended_at = v_now, ended_by = auth.uid(),
      time_amount = v_total_amount,
      billable_seconds = v_total_seconds,
      banked_time_amount = v_total_amount,
      expected_relay_state = 'OFF'
  where id = p_session_id returning * into v_session;

  select count(*) into v_rounds_count from session_rounds where session_id = p_session_id;
  for v_round in
    select * from session_rounds where session_id = p_session_id order by round_number
  loop
    v_index := v_index + 1;
    if v_index = v_rounds_count then
      v_share := v_total_amount - v_allocated;
    elsif v_total_seconds > 0 then
      v_share := floor(v_total_amount::numeric * v_round.billable_seconds / v_total_seconds)::bigint;
    else
      v_share := 0;
    end if;
    v_allocated := v_allocated + v_share;
    update session_rounds set amount = v_share where id = v_round.id;
  end loop;

  delete from order_items where order_id = v_session.order_id and kind = 'TIME';

  v_tariff_name := coalesce(v_session.tariff_snapshot ->> 'name', 'Игровое время');
  select timezone into v_tz from clubs where id = v_session.club_id;
  v_tz := coalesce(v_tz, 'UTC');

  if v_session.round_number > 1 then
    for v_round in
      select * from session_rounds where session_id = p_session_id order by round_number
    loop
      insert into order_items (club_id, order_id, kind, description, quantity, unit_price, total_price, metadata, created_by)
      values (
        v_session.club_id, v_session.order_id, 'TIME',
        format('%s · раунд %s (%s–%s)%s', v_tariff_name, v_round.round_number,
               to_char(v_round.started_at at time zone v_tz, 'HH24:MI'),
               to_char(v_round.ended_at at time zone v_tz, 'HH24:MI'),
               case when coalesce(v_round.note, '') <> '' then ' — ' || v_round.note else '' end),
        1, v_round.amount, v_round.amount,
        jsonb_build_object('round', v_round.round_number, 'seconds', v_round.billable_seconds, 'note', v_round.note),
        auth.uid()
      );
    end loop;
  else
    insert into order_items (club_id, order_id, kind, description, quantity, unit_price, total_price, metadata, created_by)
    values (v_session.club_id, v_session.order_id, 'TIME', v_tariff_name, 1,
            v_total_amount, v_total_amount, v_charge, auth.uid());
  end if;

  v_order := app_recalculate_order_totals(v_session.order_id);

  select * into v_resource from resources where id = v_session.resource_id for update;
  update resources set status = 'FREE' where id = v_session.resource_id;

  if v_resource.relay_device_id is not null then
    v_command_id := app_enqueue_relay_command(v_session.club_id, v_session.resource_id, 'OFF', p_session_id, 'session finish');
    select jsonb_build_object(
      'channel', v_resource.relay_channel,
      'provider', rd.provider,
      'direct_control', rd.direct_control,
      'configuration', rd.configuration
    ) into v_relay_device
    from relay_devices rd where rd.id = v_resource.relay_device_id;
  end if;

  perform app_audit(v_session.club_id, 'session.finish', 'game_session', p_session_id, null, to_jsonb(v_session), v_charge);

  return jsonb_build_object('session', to_jsonb(v_session), 'order', app_order_json(v_session.order_id),
    'charge', v_charge, 'relay_command_id', v_command_id, 'relay_device', v_relay_device, 'server_time', v_now);
end;
$$;

-- New round while paused: close the pause the same way resume does.
create or replace function public.session_new_round(p_session_id uuid, p_note text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_session game_sessions%rowtype;
  v_seconds integer;
  v_now timestamptz := now();
  v_pause_seconds integer;
  v_charge jsonb;
begin
  select * into v_session from game_sessions where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_session.club_id, 'session.pause');
  if v_session.status not in ('ACTIVE', 'PAUSED') then
    raise exception 'SESSION_NOT_OPEN' using errcode = 'P0001';
  end if;

  if v_session.status = 'PAUSED' and v_session.pause_started_at is not null then
    v_pause_seconds := greatest(0, extract(epoch from (v_now - v_session.pause_started_at))::integer);
    update session_pauses set resumed_at = v_now, duration_seconds = v_pause_seconds, resumed_by = auth.uid()
    where session_id = p_session_id and resumed_at is null;
    update game_sessions
    set paused_seconds = paused_seconds + v_pause_seconds, pause_started_at = null, status = 'ACTIVE',
        planned_end_at = planned_end_at + make_interval(secs => v_pause_seconds)
    where id = p_session_id returning * into v_session;
  end if;

  v_seconds := app_session_active_seconds(v_session, v_now);
  v_charge := app_charge_for_seconds(v_session.tariff_snapshot, v_seconds);

  insert into session_rounds (club_id, session_id, round_number, started_at, ended_at, billable_seconds, amount, note)
  values (v_session.club_id, p_session_id, v_session.round_number, v_session.started_at, v_now, v_seconds,
    coalesce((v_charge ->> 'time_amount')::bigint, 0), nullif(trim(p_note), ''));

  update game_sessions
  set banked_seconds = banked_seconds + v_seconds,
      round_number = round_number + 1,
      started_at = v_now,
      paused_seconds = 0,
      pause_started_at = null
  where id = p_session_id
  returning * into v_session;

  perform app_audit(v_session.club_id, 'session.new_round', 'game_session', p_session_id,
    null, to_jsonb(v_session), jsonb_build_object('seconds', v_seconds, 'note', p_note));

  return jsonb_build_object(
    'session', to_jsonb(v_session),
    'charge', jsonb_build_object('seconds', v_seconds),
    'server_time', v_now
  );
end;
$$;

create or replace function public.session_new_round(p_session_id uuid)
returns jsonb
language sql
security definer
set search_path to 'public'
as $$
  select public.session_new_round(p_session_id, null::text);
$$;

-- Extra time: counted from now when the paid time already ran out (the dark
-- minutes in between are not billed); the extra sum joins prepaid_amount.
-- Old builds call it without p_amount: the sum is then minutes x tariff.
drop function if exists public.extend_session_timer(uuid, integer);

create or replace function public.extend_session_timer(p_session_id uuid, p_minutes integer, p_amount bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_session game_sessions%rowtype;
  v_now timestamptz := now();
  v_from timestamptz;
  v_gap integer := 0;
  v_pph bigint;
  v_add bigint;
  v_extra interval;
begin
  select * into v_session from game_sessions where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_session.club_id, 'session.start');
  if v_session.status not in ('ACTIVE', 'PAUSED') then
    raise exception 'SESSION_NOT_OPEN' using errcode = 'P0001';
  end if;
  if p_minutes is null or p_minutes <= 0 then
    raise exception 'INVALID_MINUTES' using errcode = 'P0001';
  end if;

  -- Where the paid time stands now: this moment, or where a pause began.
  v_from := case when v_session.status = 'PAUSED' and v_session.pause_started_at is not null
                 then v_session.pause_started_at else v_now end;
  if v_session.planned_end_at is not null and v_session.planned_end_at < v_from then
    v_gap := greatest(0, extract(epoch from (v_from - v_session.planned_end_at))::integer);
  end if;

  v_pph := coalesce((v_session.tariff_snapshot ->> 'price_per_hour')::bigint, 0);
  v_add := greatest(0, coalesce(p_amount, round(v_pph::numeric * p_minutes / 60.0)::bigint));
  v_extra := case
    when p_amount is not null and p_amount > 0 and v_pph > 0
         and coalesce(v_session.tariff_snapshot ->> 'kind', 'HOURLY') = 'HOURLY'
      then make_interval(secs => round(p_amount * 3600.0 / v_pph)::double precision)
    else make_interval(mins => p_minutes)
  end;

  update game_sessions
  set paused_seconds = paused_seconds + v_gap,
      planned_end_at = case when v_gap > 0 or planned_end_at is null then v_from else planned_end_at end + v_extra,
      prepaid_amount = case when prepaid_amount > 0 then prepaid_amount + v_add else prepaid_amount end
  where id = p_session_id
  returning * into v_session;

  perform app_audit(v_session.club_id, 'session.extend_timer', 'game_session', p_session_id,
    null, to_jsonb(v_session), jsonb_build_object('minutes', p_minutes, 'amount', p_amount, 'unbilled_gap_seconds', v_gap));

  return jsonb_build_object('session', to_jsonb(v_session));
end;
$$;

grant execute on function public.extend_session_timer(uuid, integer, bigint) to anon, authenticated, service_role;
