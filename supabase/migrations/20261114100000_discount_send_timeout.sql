-- bot_discount_campaign_send: wait up to 30 s for Telegram's answer.
-- pg_net's default is 5 s; Telegram sometimes answers slower, and then the
-- request is recorded as timed out without telling whether the message went.
do $$
declare
  v_def text;
  v_old text := 'url := ''https://api.telegram.org/bot'' || v_token || ''/sendMessage'',';
  v_new text;
begin
  select pg_get_functiondef('public.bot_discount_campaign_send(uuid,integer)'::regprocedure) into v_def;
  if position('timeout_milliseconds' in v_def) > 0 then
    return; -- already patched
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'anchor must occur exactly once';
  end if;
  v_new := replace(v_def, v_old, v_old || E'\n      timeout_milliseconds := 30000,');
  execute v_new;
end $$;
