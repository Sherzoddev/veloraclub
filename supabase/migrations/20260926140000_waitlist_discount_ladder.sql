-- Queue discount: 5 000 as soon as the client joins, then a falling ladder
-- every full 10 minutes -- +2000, +1800, +1700, +1600, +1500, +1400, which
-- lands on exactly 15 000 at one hour -- and +1000 per 10 minutes after
-- that. Was a flat 3000 + 1000 per 10 minutes.
--
-- One function for both the live figure the cashier sees (waitlist_list) and
-- the amount written onto the order when the client is seated
-- (waitlist_seat), so the two can never disagree again.
create or replace function public.app_waitlist_discount(p_waited_seconds bigint)
returns bigint
language sql
immutable
set search_path to 'public'
as $function$
  select (5000
    + (array[0, 2000, 3800, 5500, 7100, 8600, 10000])[least(s, 6) + 1]
    + greatest(s - 6, 0) * 1000)::bigint
  from (select (greatest(0, coalesce(p_waited_seconds, 0)) / 600)::int as s) steps;
$function$;

revoke all on function public.app_waitlist_discount(bigint) from public, anon, authenticated;

create or replace function public.waitlist_list(p_club_id uuid)
returns setof jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform app_require_permission(p_club_id, 'session.start');
  return query
    select to_jsonb(w) || jsonb_build_object(
      'waited_seconds', extract(epoch from (now() - w.joined_at))::bigint,
      'accrued_discount', app_waitlist_discount(extract(epoch from (now() - w.joined_at))::bigint)
    )
    from waitlist_entries w
    where w.club_id = p_club_id and w.status = 'WAITING'
    order by w.joined_at;
end;
$function$;

create or replace function public.waitlist_seat(p_entry_id uuid, p_resource_id uuid, p_tariff_id uuid default null::uuid, p_billing_mode text default 'POSTPAID'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_entry waitlist_entries%rowtype;
  v_result jsonb;
  v_order_id uuid;
  v_discount bigint;
begin
  select * into v_entry from waitlist_entries where id = p_entry_id for update;
  if not found then raise exception 'ENTRY_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_entry.status <> 'WAITING' then raise exception 'ENTRY_NOT_WAITING' using errcode = 'P0001'; end if;

  v_discount := app_waitlist_discount(extract(epoch from (now() - v_entry.joined_at))::bigint);

  v_result := start_game_session(
    p_club_id => v_entry.club_id,
    p_resource_id => p_resource_id,
    p_tariff_id => p_tariff_id,
    p_customer_id => v_entry.customer_id,
    p_billing_mode => p_billing_mode,
    p_players_count => 1,
    p_comment => 'из очереди ожидания',
    p_prepaid_amount => 0,
    p_planned_minutes => null
  );

  v_order_id := (v_result -> 'order' ->> 'id')::uuid;
  if v_discount > 0 then
    update orders set discount_amount = v_discount,
      discount_reason = format('Скидка за ожидание (%s)', v_discount)
    where id = v_order_id;
    perform app_recalculate_order_totals(v_order_id);
  end if;

  update waitlist_entries
  set status = 'SEATED', resolved_at = now(), session_id = (v_result -> 'session' ->> 'id')::uuid
  where id = p_entry_id;

  perform app_audit(v_entry.club_id, 'waitlist.seat', 'waitlist_entry', p_entry_id, null,
    to_jsonb(v_entry), jsonb_build_object('resource_id', p_resource_id, 'discount', v_discount));

  return v_result || jsonb_build_object('discount_applied', v_discount);
end;
$function$;
