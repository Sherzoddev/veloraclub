-- The owner's bot is also told when the 40 % discount FALLS to a client (the
-- other half is in 20261114110000: when it is applied). Nothing for any other
-- prize, and a second tap of the same client sends nothing.
do $do$
declare
  v_def text;
  v_old text := 'return jsonb_build_object(''ok'', true, ''already'', false,';
  v_add text;
begin
  select pg_get_functiondef('public.bot_discount_claim(uuid,bigint,uuid)'::regprocedure) into v_def;
  if position('Выпала скидка' in v_def) > 0 then return; end if;   -- already patched
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'anchor must occur exactly once';
  end if;
  v_add := $r$if v_prize.percent >= 40 then
    perform app_notify_owner_bot(p_club_id,
      format(E'🎰 <b>Выпала скидка %s%%</b>\nКлиент: %s\nКод: <code>%s</code>',
             v_prize.percent,
             coalesce(app_promo_who(v_customer),
                      (select nullif(trim(coalesce(u.full_name, '') || case when u.username is not null then ' @' || u.username else '' end), '')
                         from club_bot_users u where u.club_id = p_club_id and u.telegram_id = p_tg_id limit 1),
                      'ID ' || p_tg_id),
             v_code));
  end if;
  $r$;
  execute replace(v_def, v_old, v_add || v_old);
end $do$;
