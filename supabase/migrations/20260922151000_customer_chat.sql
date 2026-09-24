create table if not exists public.customer_chat_messages (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete set null,
  sender_type text not null check (sender_type in ('CLIENT', 'ADMIN')),
  sender_telegram_id bigint,
  body text not null check (char_length(body) between 1 and 1000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists customer_chat_messages_thread_idx
  on public.customer_chat_messages (club_id, customer_id, created_at desc);
create index if not exists customer_chat_messages_unread_idx
  on public.customer_chat_messages (club_id, customer_id, sender_type)
  where read_at is null;

alter table public.customer_chat_messages enable row level security;
revoke all on table public.customer_chat_messages from anon, authenticated;

comment on table public.customer_chat_messages is
  'Persistent conversation between a club customer in Mini App and club administrators in Telegram.';
