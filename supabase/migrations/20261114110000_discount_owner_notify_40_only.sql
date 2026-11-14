-- "🎁 Получить скидку": the owner's bot is told about ONE thing only -- when
-- the 40 % discount is applied at the cashier. No message when a client draws
-- a prize, none for every other applied code. (The client still gets a short
-- confirmation when his code is applied.)
do $do$
declare
  v_def text;
  v_new text;
  v_n integer;
  p_claim text := 'if v_prize\.percent >= 25 then.*?end if;\s*';
  p_apply text := 'perform app_notify_owner_bot\(v_o\.club_id,\s*format\(E''✅ <b>Код скидки использован</b>.*?v_amount\)\);';
begin
  -- 1) taking a prize: the owner is not told any more
  select pg_get_functiondef('public.bot_discount_claim(uuid,bigint,uuid)'::regprocedure) into v_def;
  select count(*) into v_n from regexp_matches(v_def, p_claim, 'gs');
  if v_n = 1 then
    execute regexp_replace(v_def, p_claim, '', 's');
  elsif v_n <> 0 then
    raise exception 'claim anchor matched % times', v_n;
  end if;

  -- 2) applying a code: only the 40 % one is reported
  select pg_get_functiondef('public.promo_apply_discount_code(uuid,text)'::regprocedure) into v_def;
  select count(*) into v_n from regexp_matches(v_def, p_apply, 'gs');
  if v_n = 1 then
    v_new := regexp_replace(v_def, p_apply,
      replace($r$if v_dc.percent >= 40 then
    perform app_notify_owner_bot(v_o.club_id,
      format(E'🎰 <b>Применена скидка %s%%</b>\nКлиент: %s\nКод: <code>%s</code> · −%s сум',
             v_dc.percent, coalesce(app_promo_who(v_dc.customer_id), 'ID ' || v_dc.telegram_id), v_dc.code, v_amount));
  end if;$r$, '\', '\\'), 's');
    execute v_new;
  elsif v_n <> 0 then
    raise exception 'apply anchor matched % times', v_n;
  end if;
end $do$;
