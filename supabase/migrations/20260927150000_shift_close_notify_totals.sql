-- The owner-bot message on shift close carried only date, time and who
-- closed it. It now also has the shift's takings: revenue and receipts,
-- per payment method, expenses, net profit, and the cash check (expected
-- in the drawer vs handed over).
create or replace function public.close_cash_shift(p_shift_id uuid, p_actual_cash bigint, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_shift cash_shifts%rowtype;
  v_totals jsonb;
  v_expected bigint;
  v_open_sessions integer;
  v_tz text;
  v_closer_name text;
  v_opener_name text;
  v_methods text;
  v_cash_line text;
begin
  select * into v_shift from cash_shifts where id = p_shift_id for update;
  if not found then raise exception 'SHIFT_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_shift.club_id, 'shift.close');
  if v_shift.status <> 'OPEN' then raise exception 'SHIFT_ALREADY_CLOSED' using errcode = 'P0001'; end if;

  select count(*) into v_open_sessions from game_sessions
  where cash_shift_id = p_shift_id and status in ('STARTING', 'ACTIVE', 'PAUSED', 'STOPPING');
  if v_open_sessions > 0 then
    raise exception 'OPEN_SESSIONS_REMAIN: %', v_open_sessions using errcode = 'P0001';
  end if;

  v_totals := shift_totals(p_shift_id);
  v_expected := (v_totals ->> 'expected_cash')::bigint;

  update cash_shifts
  set status = 'CLOSED', closed_at = now(), closed_by = auth.uid(),
      expected_cash = v_expected, actual_cash = p_actual_cash,
      difference = p_actual_cash - v_expected, totals = v_totals, note = p_note
  where id = p_shift_id returning * into v_shift;

  perform app_audit(v_shift.club_id, 'shift.close', 'cash_shift', p_shift_id, null, to_jsonb(v_shift), v_totals);

  if v_shift.difference is not null and v_shift.difference <> 0 then
    perform app_open_incident(v_shift.club_id, 'OTHER',
      format('Расхождение по кассе: %s', v_shift.difference),
      case when abs(v_shift.difference) > 100000 then 'CRITICAL' else 'WARNING' end,
      jsonb_build_object('shift_id', p_shift_id, 'difference', v_shift.difference));
  end if;

  select timezone into v_tz from clubs where id = v_shift.club_id;
  v_tz := coalesce(v_tz, 'UTC');
  select full_name into v_closer_name from profiles where id = v_shift.closed_by;
  select full_name into v_opener_name from profiles where id = v_shift.opened_by;

  select string_agg(format(E'  · %s — %s сум', app_html(m.key), app_money(m.value::bigint)), E'\n' order by m.value::bigint desc)
    into v_methods
  from jsonb_each_text(coalesce(v_totals -> 'by_payment_method', '{}'::jsonb)) m
  where m.value::bigint <> 0;

  v_cash_line := format(E'💵 В кассе должно быть: <b>%s сум</b>\nСдано: %s сум',
    app_money(v_expected), app_money(p_actual_cash))
    || case when v_shift.difference = 0 then ' ✅'
            when v_shift.difference > 0 then format(' · излишек <b>+%s сум</b> ⚠️', app_money(v_shift.difference))
            else format(' · недостача <b>−%s сум</b> ⚠️', app_money(-v_shift.difference)) end;

  perform app_notify_owner_bot(v_shift.club_id, format(
    E'🔴 <b>Смена закрыта</b>\n\n🟢 Открыта: %s · %s\n🔴 Закрыта: %s · %s\n\n💰 Выручка: <b>%s сум</b> · %s чеков\n%s📉 Расходы: %s сум\n✅ Чистая прибыль: <b>%s сум</b>\n\n%s',
    to_char(v_shift.opened_at at time zone v_tz, 'DD.MM HH24:MI'), coalesce(app_html(v_opener_name), 'неизвестно'),
    to_char(v_shift.closed_at at time zone v_tz, 'DD.MM HH24:MI'), coalesce(app_html(v_closer_name), 'неизвестно'),
    app_money((v_totals ->> 'revenue')::bigint), coalesce(v_totals ->> 'orders_count', '0'),
    case when v_methods is null then '' else v_methods || E'\n' end,
    app_money((v_totals ->> 'expenses')::bigint),
    app_money((v_totals ->> 'net_profit')::bigint),
    v_cash_line
  ));

  return jsonb_build_object('shift', to_jsonb(v_shift), 'totals', v_totals);
end;
$function$;
