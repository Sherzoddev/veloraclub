-- A computer activated once with the vendor's code opens ANY club by its
-- token -- no code-to-club or code-to-token matching. Support staff keep two
-- or three clubs on one laptop and switch by typing the token.
--
-- A license now counts for a computer when it is the club's license (as
-- before, so second tills of a licensed club still need only the token) OR
-- a license activated on this very computer. A brand-new computer with the
-- token of a club that has no license still needs an activation code.

-- device_check_in: the device's own license counts as well as its club's.
create or replace function public.device_check_in(
  p_device_code text, p_name text default null, p_platform text default null, p_hardware_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device devices%rowtype;
  v_license license_codes%rowtype;
  v_club clubs%rowtype;
  v_staff integer;
  v_hw text := nullif(trim(coalesce(p_hardware_id, '')), '');
begin
  if p_device_code is not null and length(trim(p_device_code)) > 0 then
    select * into v_device from devices where device_code = upper(trim(p_device_code));
  end if;

  -- Local storage carrying the device_code can be lost (reinstall, wiped app
  -- data, a fresh build's first run) without the physical till changing. A
  -- stable hardware fingerprint lets us recognize it's the same machine and
  -- hand back its existing code instead of minting a new one.
  if v_device.id is null and v_hw is not null then
    select * into v_device from devices where hardware_id = v_hw;
  end if;

  if v_device.id is null then
    insert into devices (device_code, device_name, platform, hardware_id)
    values (app_generate_device_code(), p_name, p_platform, v_hw)
    returning * into v_device;
  else
    update devices set last_seen_at = now(),
      device_name = coalesce(p_name, device_name),
      platform = coalesce(p_platform, platform),
      hardware_id = coalesce(v_hw, hardware_id)
    where id = v_device.id returning * into v_device;
  end if;

  if v_device.club_id is null then
    return jsonb_build_object('ok', false, 'reason', 'NOT_ACTIVATED', 'device_code', v_device.device_code);
  end if;

  select * into v_club from clubs where id = v_device.club_id;

  select * into v_license from license_codes
  where status = 'ACTIVATED'
    and (club_id = v_device.club_id or bound_device_id = v_device.id or id = v_device.license_code_id)
  order by (expires_at is null) desc, expires_at desc
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'NO_LICENSE', 'device_code', v_device.device_code);
  end if;
  if v_license.expires_at is not null and v_license.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'EXPIRED',
      'device_code', v_device.device_code, 'expires_at', v_license.expires_at);
  end if;

  select count(*) into v_staff from club_members where club_id = v_device.club_id and active;

  return jsonb_build_object(
    'ok', true,
    'device_code', v_device.device_code,
    'club_id', v_device.club_id,
    'club_name', v_club.name,
    'expires_at', v_license.expires_at,
    'duration_kind', v_license.duration_kind,
    'has_staff', v_staff > 0
  );
end;
$$;

-- license_status (called with the token right after a successful check-in):
-- a club opened by an activated computer counts as licensed for it.
create or replace function public.license_status(p_venue_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue venue_tokens%rowtype;
  v_license license_codes%rowtype;
  v_club clubs%rowtype;
begin
  select * into v_venue from venue_tokens where token = p_venue_token;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_VENUE');
  end if;
  if not v_venue.active then
    return jsonb_build_object('ok', false, 'reason', 'VENUE_REVOKED');
  end if;
  if v_venue.club_id is null then
    return jsonb_build_object('ok', false, 'reason', 'VENUE_NOT_SET_UP');
  end if;

  select * into v_club from clubs where id = v_venue.club_id;

  select * into v_license from license_codes lc
  where lc.status = 'ACTIVATED'
    and (lc.club_id = v_venue.club_id
         or lc.bound_device_id in (select d.id from devices d where d.club_id = v_venue.club_id)
         or lc.id in (select d.license_code_id from devices d where d.club_id = v_venue.club_id))
  order by (lc.expires_at is null) desc, lc.expires_at desc
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'NO_LICENSE',
      'club_id', v_venue.club_id, 'club_name', v_club.name);
  end if;
  if v_license.expires_at is not null and v_license.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'EXPIRED',
      'expires_at', v_license.expires_at,
      'club_id', v_venue.club_id, 'club_name', v_club.name);
  end if;

  return jsonb_build_object(
    'ok', true,
    'club_id', v_venue.club_id,
    'club_name', v_club.name,
    'venue_name', v_venue.venue_name,
    'expires_at', v_license.expires_at,
    'duration_kind', v_license.duration_kind
  );
end;
$$;

-- device_join_club: the token is enough when the club is licensed OR this
-- computer holds its own valid license.
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
    where status = 'ACTIVATED' and (expires_at is null or expires_at > v_now)
      and (club_id = v_token.club_id or bound_device_id = v_device.id or id = v_device.license_code_id)
  ) then
    -- Neither the club nor this computer is licensed: use an unused code the
    -- vendor issued for this very computer, if there is one.
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

-- device_activate_venue: a code already activated on THIS computer opens
-- whatever club the token names (it is the computer's permission, not the
-- club's); only a code used by another club without a computer is refused.
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
  if v_license.status = 'ACTIVATED' and v_license.bound_device_id is null
     and v_license.club_id is distinct from v_token.club_id then
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
