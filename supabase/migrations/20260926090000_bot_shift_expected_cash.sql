-- Cash that should be in the drawer right now for a shift, for the owner bot
-- (service role, so shift_totals' club-member check can't pass). Same formula
-- as shift_totals.expected_cash; closed shifts keep theirs in cash_shifts.
create or replace function public.bot_shift_expected_cash(p_shift_id uuid)
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $$
  select s.opening_cash
    + coalesce((select sum(p.amount) from payments p join payment_methods pm on pm.id = p.payment_method_id
                where p.cash_shift_id = s.id and p.status = 'COMPLETED' and pm.affects_cash_drawer), 0)
    - coalesce((select sum(e.amount) from expenses e left join payment_methods pm on pm.id = e.payment_method_id
                where e.cash_shift_id = s.id and e.status = 'ACTIVE' and coalesce(pm.affects_cash_drawer, true)), 0)
    + coalesce((select sum(amount) from cash_movements where cash_shift_id = s.id and kind = 'DEPOSIT'), 0)
    - coalesce((select sum(amount) from cash_movements where cash_shift_id = s.id and kind = 'WITHDRAWAL'), 0)
  from cash_shifts s where s.id = p_shift_id;
$$;

revoke execute on function public.bot_shift_expected_cash(uuid) from public, anon, authenticated;
grant execute on function public.bot_shift_expected_cash(uuid) to service_role;
