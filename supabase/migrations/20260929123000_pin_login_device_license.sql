-- PIN login follows the same license rule as device_check_in: the club's own
-- license OR a license activated on this computer. Without it a laptop that
-- opened a club by its token got to the PIN screen and then every PIN failed
-- with NO_LICENSE (shown by the app as a connection error).
create or replace function public.auth_resolve_pin_device(p_device_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device devices%rowtype;
  v_license license_codes%rowtype;
  v_pin staff_pins%rowtype;
  v_role text;
begin
  select * into v_device from devices where device_code = upper(trim(p_device_code));
  if not found or v_device.club_id is null then
    return jsonb_build_object('ok', false, 'reason', 'NOT_ACTIVATED');
  end if;

  select * into v_license from license_codes
  where status = 'ACTIVATED'
    and (club_id = v_device.club_id or bound_device_id = v_device.id or id = v_device.license_code_id)
  order by (expires_at is null) desc, expires_at desc
  limit 1;
  if not found then return jsonb_build_object('ok', false, 'reason', 'NO_LICENSE'); end if;
  if v_license.expires_at is not null and v_license.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'EXPIRED', 'expires_at', v_license.expires_at);
  end if;

  select * into v_pin from staff_pins
  where club_id = v_device.club_id and active and pin_hash = extensions.crypt(p_pin, pin_hash)
  limit 1;
  if not found then return jsonb_build_object('ok', false, 'reason', 'BAD_PIN'); end if;
  if v_pin.locked_until is not null and v_pin.locked_until > now() then
    return jsonb_build_object('ok', false, 'reason', 'LOCKED');
  end if;

  update staff_pins set failed_attempts = 0, locked_until = null where id = v_pin.id;

  select r.key into v_role
  from club_members cm join roles r on r.id = cm.role_id
  where cm.club_id = v_device.club_id and cm.user_id = v_pin.user_id and cm.active;

  return jsonb_build_object('ok', true, 'user_id', v_pin.user_id,
    'club_id', v_device.club_id, 'role', v_role);
end;
$$;
