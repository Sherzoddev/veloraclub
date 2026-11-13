-- "6 visits = 1 free hour": one visit per club day, not per calendar day.
-- A game paid at 00:28 belongs to the evening before; counting it under the
-- new date made the next afternoon's visit collide with it
-- (unique (customer_id, visit_on)) and get dropped. Orders closed before
-- 06:00 local now count for the previous day.
do $$
declare
  v_def text;
  v_old text := '(now() at time zone v_tz)::date';
  v_new text;
begin
  select pg_get_functiondef('public.app_promo_after_order(uuid)'::regprocedure) into v_def;
  if position(v_old in v_def) = 0 then
    return; -- already patched
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'anchor must occur exactly once';
  end if;
  v_new := replace(v_def, v_old, '((now() at time zone v_tz) - interval ''6 hours'')::date');
  execute v_new;
end $$;
