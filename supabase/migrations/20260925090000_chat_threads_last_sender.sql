-- Admin Mini App chat list: who wrote last (shown as "Вы: …") and whether
-- the client can get Telegram pushes at all. One lateral lookup per thread
-- instead of two correlated subqueries for the same last message.
create or replace function public.admin_chat_threads(p_club_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(row_to_json(t) order by t.last_at desc), '[]'::jsonb)
  from (
    select c.id as customer_id, c.full_name, c.phone,
      (c.telegram_id is not null) as has_telegram,
      l.body as last_body, l.sender_type as last_sender, l.created_at as last_at,
      (select count(*)::int from customer_chat_messages m
        where m.customer_id = c.id and m.club_id = p_club_id
          and m.sender_type = 'CLIENT' and m.read_at is null) as unread
    from customers c
    join lateral (
      select m.body, m.sender_type, m.created_at from customer_chat_messages m
      where m.customer_id = c.id and m.club_id = p_club_id
      order by m.created_at desc limit 1
    ) l on true
    where c.club_id = p_club_id
  ) t;
$function$;
