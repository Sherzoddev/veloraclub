-- Tournaments: the admin Mini App creates them and opens/closes sign-up;
-- clients sign up from the client Mini App with first name, last name and
-- phone; the admin gets the list as an Excel file. Both Mini Apps reach the
-- tables only through their edge functions (service role), so RLS is on
-- with no policies.

create table public.tournaments (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  description text check (description is null or char_length(description) <= 1000),
  starts_at timestamptz not null,
  max_participants integer check (max_participants is null or max_participants > 0),
  registration_open boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tournaments_club on public.tournaments (club_id, starts_at);

create table public.tournament_registrations (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  club_id uuid not null references public.clubs(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  telegram_id bigint not null,
  first_name text not null check (char_length(first_name) between 1 and 60),
  last_name text not null check (char_length(last_name) between 1 and 60),
  phone text not null check (char_length(phone) between 5 and 30),
  created_at timestamptz not null default now(),
  unique (tournament_id, telegram_id)
);
create index tournament_registrations_tournament on public.tournament_registrations (tournament_id, created_at);

alter table public.tournaments enable row level security;
alter table public.tournament_registrations enable row level security;

-- Sign-up with the capacity check under a row lock, so two clients taking
-- the last seat at once can't both get in. Signing up again updates the
-- name/phone instead of failing.
create or replace function public.tournament_register(
  p_club_id uuid, p_tournament_id uuid, p_telegram_id bigint, p_customer_id uuid,
  p_first_name text, p_last_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_t tournaments%rowtype;
  v_count integer;
  v_existing uuid;
begin
  select * into v_t from tournaments where id = p_tournament_id and club_id = p_club_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND'); end if;

  select id into v_existing from tournament_registrations
   where tournament_id = p_tournament_id and telegram_id = p_telegram_id;
  if v_existing is not null then
    update tournament_registrations
       set first_name = p_first_name, last_name = p_last_name, phone = p_phone,
           customer_id = coalesce(p_customer_id, customer_id)
     where id = v_existing;
    return jsonb_build_object('ok', true, 'updated', true);
  end if;

  if not v_t.registration_open then return jsonb_build_object('ok', false, 'reason', 'CLOSED'); end if;
  if v_t.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'STARTED'); end if;
  if v_t.max_participants is not null then
    select count(*) into v_count from tournament_registrations where tournament_id = p_tournament_id;
    if v_count >= v_t.max_participants then return jsonb_build_object('ok', false, 'reason', 'FULL'); end if;
  end if;

  insert into tournament_registrations (tournament_id, club_id, customer_id, telegram_id, first_name, last_name, phone)
  values (p_tournament_id, p_club_id, p_customer_id, p_telegram_id, p_first_name, p_last_name, p_phone);
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.tournament_register(uuid, uuid, bigint, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.tournament_register(uuid, uuid, bigint, uuid, text, text, text) to service_role;
