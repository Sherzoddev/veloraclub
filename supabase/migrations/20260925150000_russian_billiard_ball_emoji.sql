-- BILLION and the other clubs play Russian billiards: the 🎱 (American
-- eight-ball) emoji in bot texts becomes a plain white ball ⚪. The bot,
-- match-notify and Mini App code are updated alongside; these are the two
-- database functions that build Telegram messages with it.
do $$
declare
  fn text;
begin
  foreach fn in array array['app_order_receipt_message', 'app_send_winback_reminders'] loop
    execute replace(pg_get_functiondef(fn::regproc), '🎱', '⚪');
  end loop;
end $$;
