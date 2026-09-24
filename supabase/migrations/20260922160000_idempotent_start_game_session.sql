-- A repeated Start click must return the session that is already running.
-- The resource row lock serializes concurrent clicks for the same table.
create or replace function public.start_game_session(
  p_club_id uuid,
  p_resource_id uuid,
  p_tariff_id uuid default null,
  p_billing_mode text default 'POSTPAID',
  p_customer_id uuid default null,
  p_players_count integer default 1,
  p_comment text default null,
  p_prepaid_amount bigint default 0,
  p_planned_minutes integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_resource resources%rowtype;
  v_tariff_id uuid;
  v_snapshot jsonb;
  v_session game_sessions%rowtype;
  v_order orders%rowtype;
  v_shift_id uuid;
  v_needs_relay boolean;
  v_command_id uuid;
  v_status text;
  v_now timestamptz := now();
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

  -- A double click, delayed UI refresh, or a concurrent cashier request is
  -- not an error. Return the authoritative running session instead.
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
    case when p_planned_minutes is not null
      then v_now + make_interval(mins => p_planned_minutes)
    end,
    coalesce(p_prepaid_amount, 0), p_comment, auth.uid(), 'ON',
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
  end if;

  perform app_audit(
    p_club_id,
    'session.start',
    'game_session',
    v_session.id,
    null,
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
    'server_time', v_now,
    'already_active', false
  );
end;
$function$;

