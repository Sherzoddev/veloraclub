-- "🎬 Мои удары": the clip is the minute the client named (19:52:00 - 19:53:00), so
-- the minute must be over (and its piece written) before a request is taken.

create or replace function public.bot_clip_request(
  p_club_id uuid, p_tg_id bigint, p_resource_id uuid, p_moment timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not exists (
    select 1 from club_clip_tables
     where club_id = p_club_id and resource_id = p_resource_id and seen_at > now() - interval '10 minutes'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_AVAILABLE');
  end if;
  if p_moment > now() - interval '75 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'TOO_FRESH');
  end if;
  if p_moment < now() - interval '24 hours' then
    return jsonb_build_object('ok', false, 'reason', 'TOO_OLD');
  end if;
  if exists (
    select 1 from clip_requests
     where club_id = p_club_id and telegram_id = p_tg_id and status in ('PENDING', 'PROCESSING')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'BUSY');
  end if;
  if (select count(*) from clip_requests
       where club_id = p_club_id and telegram_id = p_tg_id and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'reason', 'LIMIT');
  end if;
  insert into clip_requests (club_id, telegram_id, resource_id, moment)
  values (p_club_id, p_tg_id, p_resource_id, p_moment) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

revoke all on function public.bot_clip_request(uuid, bigint, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.bot_clip_request(uuid, bigint, uuid, timestamptz) to service_role;
