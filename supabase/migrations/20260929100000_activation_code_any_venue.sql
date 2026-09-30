-- Activation code = the vendor's permission to run the program on a computer.
-- The venue token alone says WHICH club it is. Until now a code had to be
-- prepared for the very club whose token is typed next to it: a code the bot
-- issued "for BILLION" plus a token of a new club failed with
-- CLUB_NOT_LICENSED ("Zavod litsenziyasi faol emas"), with no way out on the
-- token-only screen. Now the first use of a code decides its club: code +
-- token -> the code is activated for the token's club and pinned to this
-- computer, and the till goes straight to the PIN screen.
--
-- Still guarded: a code pinned to another computer, a revoked or expired
-- code, or a code already used by another club is refused; ten wrong codes
-- typed with one token lock that token's activations for 30 minutes (codes
-- are 6 digits, the token is the scarce secret).

alter table public.venue_tokens
  add column if not exists activation_failures integer not null default 0,
  add column if not exists activation_locked_until timestamptz;

create or replace function public.app_note_activation_failure(p_token_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update venue_tokens
  set activation_failures = case when activation_failures + 1 >= 10 then 0 else activation_failures + 1 end,
      activation_locked_until = case when activation_failures + 1 >= 10
                                     then now() + interval '30 minutes'
                                     else activation_locked_until end
  where id = p_token_id;
$$;

revoke all on function public.app_note_activation_failure(uuid) from public, anon, authenticated;

-- One step for the Windows app: activation code + venue token.
create or replace function public.device_activate_venue(
  p_device_code text, p_activation_code text, p_venue_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device devices%rowtype;
  v_token venue_tokens%rowtype;
  v_club clubs%rowtype;
  v_license license_codes%rowtype;
  v_code text := regexp_replace(coalesce(p_activation_code, ''), '[^0-9A-Za-z-]', '', 'g');
  v_now timestamptz := now();
begin
  select * into v_device from devices
  where device_code = upper(trim(coalesce(p_device_code, ''))) for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_DEVICE'); end if;

  select * into v_token from venue_tokens
  where token = regexp_replace(coalesce(p_venue_token, ''), '\s', '', 'g') for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_TOKEN'); end if;
  if not v_token.active then return jsonb_build_object('ok', false, 'reason', 'TOKEN_REVOKED'); end if;
  select * into v_club from clubs where id = v_token.club_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_TOKEN'); end if;

  if v_token.activation_locked_until is not null and v_token.activation_locked_until > v_now then
    return jsonb_build_object('ok', false, 'reason', 'LOCKED', 'locked_until', v_token.activation_locked_until);
  end if;

  if v_code <> '' then
    select * into v_license from license_codes where upper(code) = upper(v_code) for update;
  end if;
  if v_license.id is null then
    perform app_note_activation_failure(v_token.id);
    return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_CODE');
  end if;
  if v_license.status not in ('ISSUED', 'ACTIVATED') then
    perform app_note_activation_failure(v_token.id);
    return jsonb_build_object('ok', false, 'reason', 'CODE_REVOKED');
  end if;
  if v_license.bound_device_id is not null and v_license.bound_device_id <> v_device.id then
    perform app_note_activation_failure(v_token.id);
    return jsonb_build_object('ok', false, 'reason', 'CODE_BOUND_ELSEWHERE');
  end if;
  if v_license.status = 'ACTIVATED' and v_license.club_id is distinct from v_token.club_id then
    perform app_note_activation_failure(v_token.id);
    return jsonb_build_object('ok', false, 'reason', 'CODE_ALREADY_USED');
  end if;
  if v_license.status = 'ACTIVATED' and v_license.expires_at is not null and v_license.expires_at <= v_now then
    return jsonb_build_object('ok', false, 'reason', 'EXPIRED', 'expires_at', v_license.expires_at);
  end if;

  if v_license.status = 'ISSUED' then
    update license_codes
    set status = 'ACTIVATED',
        club_id = v_token.club_id,
        bound_venue_token_id = v_token.id,
        bound_device_id = v_device.id,
        activated_at = v_now,
        expires_at = app_license_expiry(duration_kind, v_now)
    where id = v_license.id
    returning * into v_license;
  end if;

  update devices
  set club_id = v_token.club_id, license_code_id = v_license.id, activated_at = v_now
  where id = v_device.id;

  update venue_tokens set activation_failures = 0 where id = v_token.id;

  return jsonb_build_object(
    'ok', true, 'club_id', v_club.id, 'club_name', v_club.name, 'expires_at', v_license.expires_at
  );
end;
$$;

revoke all on function public.device_activate_venue(text, text, text) from public;
grant execute on function public.device_activate_venue(text, text, text) to anon, authenticated;

-- Already-installed builds call device_activate(code) and then
-- device_join_club(token). device_activate no longer burns the code on the
-- club it was prepared for: it only checks it and pins it to this computer;
-- device_join_club then activates it for the token's club if that club has
-- no license yet. Generic codes with neither club nor computer stay for the
-- new one-step screen, which counts wrong attempts.
create or replace function public.device_activate(p_device_code text, p_activation_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device devices%rowtype;
  v_license license_codes%rowtype;
begin
  select * into v_device from devices where device_code = upper(trim(p_device_code)) for update;
  if not found then raise exception 'UNKNOWN_DEVICE' using errcode = 'P0002'; end if;

  select * into v_license from license_codes
  where upper(code) = upper(regexp_replace(coalesce(p_activation_code, ''), '[^0-9A-Za-z-]', '', 'g'))
  for update;
  if not found then raise exception 'UNKNOWN_CODE' using errcode = 'P0002'; end if;
  if v_license.status not in ('ISSUED', 'ACTIVATED') then raise exception 'CODE_REVOKED' using errcode = 'P0001'; end if;
  if v_license.bound_device_id is not null and v_license.bound_device_id <> v_device.id then
    raise exception 'CODE_BOUND_ELSEWHERE' using errcode = 'P0001';
  end if;
  if v_license.club_id is null and v_license.bound_device_id is null then
    raise exception 'CODE_NOT_PREPARED' using errcode = 'P0001';
  end if;

  if v_license.bound_device_id is null then
    update license_codes set bound_device_id = v_device.id where id = v_license.id returning * into v_license;
  end if;

  return jsonb_build_object('ok', true, 'club_id', v_license.club_id, 'expires_at', v_license.expires_at);
end;
$$;

create or replace function public.device_join_club(p_device_code text, p_venue_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device devices%rowtype;
  v_token venue_tokens%rowtype;
  v_club clubs%rowtype;
  v_pending license_codes%rowtype;
  v_now timestamptz := now();
begin
  select * into v_device from devices where device_code = upper(trim(p_device_code)) for update;
  if not found then raise exception 'UNKNOWN_DEVICE' using errcode = 'P0002'; end if;

  select * into v_token from venue_tokens
  where token = regexp_replace(coalesce(p_venue_token, ''), '\s', '', 'g');
  if not found then raise exception 'UNKNOWN_TOKEN' using errcode = 'P0002'; end if;
  if not v_token.active then raise exception 'TOKEN_REVOKED' using errcode = 'P0001'; end if;

  select * into v_club from clubs where id = v_token.club_id;
  if not found then raise exception 'UNKNOWN_TOKEN' using errcode = 'P0002'; end if;

  if not exists (
    select 1 from license_codes
    where club_id = v_token.club_id and status = 'ACTIVATED'
      and (expires_at is null or expires_at > v_now)
  ) then
    -- The club has no license yet: use an unused code the vendor issued for
    -- this very computer, whichever club it was prepared for.
    select * into v_pending from license_codes
    where bound_device_id = v_device.id and status = 'ISSUED'
    order by created_at desc
    limit 1
    for update;
    if not found then
      raise exception 'CLUB_NOT_LICENSED' using errcode = 'P0001';
    end if;
    update license_codes
    set status = 'ACTIVATED', club_id = v_token.club_id, bound_venue_token_id = v_token.id,
        activated_at = v_now, expires_at = app_license_expiry(duration_kind, v_now)
    where id = v_pending.id;
    update devices set license_code_id = v_pending.id where id = v_device.id;
  end if;

  update devices set club_id = v_token.club_id, activated_at = v_now
  where id = v_device.id;

  return jsonb_build_object('ok', true, 'club_id', v_token.club_id, 'club_name', v_club.name);
end;
$$;
