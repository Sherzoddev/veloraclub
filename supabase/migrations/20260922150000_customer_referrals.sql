-- One-time club referral reward: the inviter receives 2% of the invited
-- customer's first completed order. All state changes happen in the same
-- transaction as checkout, so retries cannot award the bonus twice.

create table if not exists public.customer_referrals (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  referrer_customer_id uuid not null references public.customers(id) on delete cascade,
  referred_telegram_id bigint not null,
  referred_customer_id uuid references public.customers(id) on delete set null,
  status text not null default 'PENDING'
    check (status in ('PENDING', 'LINKED', 'REWARDED', 'CANCELLED')),
  reward_percent smallint not null default 2 check (reward_percent between 0 and 100),
  reward_amount bigint not null default 0 check (reward_amount >= 0),
  reward_order_id uuid references public.orders(id) on delete set null,
  invited_at timestamptz not null default now(),
  linked_at timestamptz,
  rewarded_at timestamptz,
  unique (club_id, referred_telegram_id)
);

create unique index if not exists customer_referrals_referred_customer_uidx
  on public.customer_referrals (club_id, referred_customer_id)
  where referred_customer_id is not null;
create index if not exists customer_referrals_referrer_idx
  on public.customer_referrals (club_id, referrer_customer_id, invited_at desc);
create index if not exists customer_referrals_pending_reward_idx
  on public.customer_referrals (club_id, referred_customer_id)
  where status = 'LINKED';

alter table public.customer_referrals enable row level security;
revoke all on table public.customer_referrals from anon, authenticated;

create or replace function public.bot_claim_referral(
  p_club_id uuid,
  p_tg_id bigint,
  p_referrer_card uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referrer customers%rowtype;
  v_referred customers%rowtype;
  v_claim customer_referrals%rowtype;
begin
  select * into v_referrer
  from customers
  where club_id = p_club_id and card_token = p_referrer_card
    and active and archived_at is null;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'INVALID_REFERRAL');
  end if;
  if v_referrer.telegram_id = p_tg_id then
    return jsonb_build_object('ok', false, 'reason', 'SELF_REFERRAL');
  end if;

  select * into v_referred
  from customers
  where club_id = p_club_id and telegram_id = p_tg_id
    and active and archived_at is null
  limit 1;

  if found and (v_referred.id = v_referrer.id or v_referred.visits_count > 0 or v_referred.total_spent > 0) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_NEW_CUSTOMER');
  end if;

  insert into customer_referrals (
    club_id, referrer_customer_id, referred_telegram_id,
    referred_customer_id, status, linked_at
  ) values (
    p_club_id, v_referrer.id, p_tg_id,
    v_referred.id,
    case when v_referred.id is null then 'PENDING' else 'LINKED' end,
    case when v_referred.id is null then null else now() end
  )
  on conflict (club_id, referred_telegram_id) do nothing
  returning * into v_claim;

  if not found then
    select * into v_claim from customer_referrals
    where club_id = p_club_id and referred_telegram_id = p_tg_id;
    return jsonb_build_object(
      'ok', v_claim.referrer_customer_id = v_referrer.id,
      'reason', 'ALREADY_CLAIMED',
      'referrer_name', v_referrer.full_name
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'status', v_claim.status,
    'referrer_name', v_referrer.full_name
  );
end;
$$;

revoke all on function public.bot_claim_referral(uuid, bigint, uuid) from public, anon, authenticated;
grant execute on function public.bot_claim_referral(uuid, bigint, uuid) to service_role;

create or replace function public.link_customer_referral()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.telegram_id is not null then
    update customer_referrals
    set referred_customer_id = new.id,
        status = 'LINKED',
        linked_at = coalesce(linked_at, now())
    where club_id = new.club_id
      and referred_telegram_id = new.telegram_id
      and referred_customer_id is null
      and status = 'PENDING'
      and referrer_customer_id <> new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists customers_link_referral on public.customers;
create trigger customers_link_referral
after insert or update of telegram_id on public.customers
for each row execute function public.link_customer_referral();

create or replace function public.reward_customer_referral()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referral customer_referrals%rowtype;
  v_reward bigint;
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
      and club_id = new.club_id and active and archived_at is null;

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
  end if;

  return new;
end;
$$;

drop trigger if exists orders_reward_customer_referral on public.orders;
create trigger orders_reward_customer_referral
after update of status on public.orders
for each row
when (new.status = 'COMPLETED' and old.status is distinct from 'COMPLETED')
execute function public.reward_customer_referral();

comment on table public.customer_referrals is
  'One-time 2% reward for the inviter after the referred customer first completes an order.';
