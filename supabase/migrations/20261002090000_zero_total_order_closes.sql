-- A check whose total is 0 (100% discount, or fully paid with bonus points)
-- could not be closed: create_payment stopped at "nothing left to pay" with
-- ORDER_ALREADY_PAID, and a payment line of 0 is not allowed either, so the
-- order stayed OPEN and the table never got its receipt.
--
-- Now an OPEN order with nothing left to pay is simply completed, without a
-- payment line. It still needs an open shift, and an empty order (no time, no
-- items, nothing paid) is still refused.

create or replace function public.create_payment(p_order_id uuid, p_payments jsonb, p_note text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order orders%rowtype;
  v_line jsonb;
  v_method payment_methods%rowtype;
  v_amount bigint;
  v_sum bigint := 0;
  v_remaining bigint;
  v_zero boolean := false;
  v_shift_id uuid;
  v_created jsonb := '[]'::jsonb;
  v_payment payments%rowtype;
  v_loyalty_percent smallint;
  v_points_earned bigint;
begin
  select * into v_order from orders where id = p_order_id for update;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  perform app_require_permission(v_order.club_id, 'payment.create');
  if v_order.status <> 'OPEN' then raise exception 'ORDER_NOT_OPEN' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_payments) <> 'array' or jsonb_array_length(p_payments) = 0 then
    raise exception 'NO_PAYMENT_LINES' using errcode = 'P0001';
  end if;

  v_order := app_recalculate_order_totals(p_order_id);
  v_remaining := v_order.total_amount - v_order.paid_amount;
  if v_remaining <= 0 then
    -- Nothing left to pay: close it only if there was something to bill.
    if (v_order.items_amount + v_order.time_amount) <= 0 and v_order.paid_amount <= 0 then
      raise exception 'ORDER_ALREADY_PAID' using errcode = 'P0001';
    end if;
    v_zero := true;
  end if;

  v_shift_id := coalesce(v_order.cash_shift_id, app_current_shift_id(v_order.club_id));
  if v_shift_id is null then raise exception 'NO_OPEN_SHIFT' using errcode = 'P0001'; end if;

  if v_zero and v_order.cash_shift_id is null then
    update orders set cash_shift_id = v_shift_id where id = p_order_id;
  end if;

  for v_line in select * from jsonb_array_elements(p_payments) where not v_zero
  loop
    v_amount := (v_line ->> 'amount')::bigint;
    if v_amount is null or v_amount <= 0 then raise exception 'INVALID_PAYMENT_AMOUNT' using errcode = 'P0001'; end if;

    select * into v_method from payment_methods
    where id = (v_line ->> 'payment_method_id')::uuid and club_id = v_order.club_id and active;
    if not found then raise exception 'PAYMENT_METHOD_NOT_FOUND' using errcode = 'P0002'; end if;

    if v_method.key = 'cash' and v_amount > v_remaining - v_sum then
      v_amount := greatest(v_remaining - v_sum, 0);
    end if;
    if v_amount <= 0 then raise exception 'INVALID_PAYMENT_AMOUNT' using errcode = 'P0001'; end if;

    v_sum := v_sum + v_amount;

    insert into payments (club_id, order_id, cash_shift_id, payment_method_id, customer_id,
      amount, status, note, external_reference, created_by)
    values (v_order.club_id, p_order_id, v_shift_id, v_method.id, v_order.customer_id,
      v_amount, 'COMPLETED', p_note, v_line ->> 'external_reference', auth.uid())
    returning * into v_payment;

    v_created := v_created || to_jsonb(v_payment);
  end loop;

  if v_sum > v_remaining then
    raise exception 'OVERPAYMENT: remaining %, offered %', v_remaining, v_sum using errcode = 'P0001';
  end if;

  select * into v_order from orders where id = p_order_id;
  if v_order.paid_amount >= v_order.total_amount then
    update orders set status = 'COMPLETED', closed_at = now(), closed_by = auth.uid()
    where id = p_order_id returning * into v_order;

    if v_order.customer_id is not null then
      declare
        v_tier loyalty_tiers%rowtype;
        v_visit_bonus integer := 0;
        v_today date := (now() at time zone coalesce(
          (select timezone from clubs where id = v_order.club_id), 'UTC'))::date;
        v_customer customers%rowtype;
      begin
        select * into v_customer from customers where id = v_order.customer_id for update;

        select * into v_tier from loyalty_tiers where id = v_customer.tier_id;
        if v_tier.id is null then
          select loyalty_earn_percent into v_loyalty_percent from clubs where id = v_order.club_id;
        else
          v_loyalty_percent := v_tier.earn_percent;
        end if;

        v_points_earned := floor(v_order.total_amount * coalesce(v_loyalty_percent, 0) / 100.0);

        if v_customer.last_visit_bonus_on is distinct from v_today then
          select visit_bonus_points into v_visit_bonus from clubs where id = v_order.club_id;
          v_visit_bonus := coalesce(v_visit_bonus, 0);
        end if;

        update customers
        set visits_count = visits_count + 1,
            total_spent = total_spent + v_order.total_amount,
            bonus_points = bonus_points + v_points_earned + v_visit_bonus,
            last_visit_at = now(),
            last_visit_bonus_on = case when v_visit_bonus > 0 then v_today else last_visit_bonus_on end
        where id = v_order.customer_id;

        perform app_refresh_customer_tier(v_order.customer_id);

        if v_points_earned + v_visit_bonus > 0 then
          perform app_audit(v_order.club_id, 'customer.points_earned', 'customer', v_order.customer_id,
            null,
            jsonb_build_object(
              'points', v_points_earned,
              'visit_bonus', v_visit_bonus,
              'percent', v_loyalty_percent,
              'tier', coalesce(v_tier.name, '—')),
            jsonb_build_object('order_id', p_order_id));

          perform app_check_bonus_farming(v_order.club_id, v_order.customer_id);
        end if;
      end;
    end if;
  end if;

  perform app_audit(v_order.club_id, 'payment.create', 'order', p_order_id, null,
    jsonb_build_object('payments', v_created), jsonb_build_object('total', v_sum));

  return jsonb_build_object('order', app_order_json(v_order.id), 'payments', v_created);
end;
$function$;
