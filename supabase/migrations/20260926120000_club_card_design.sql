-- Member card design in the client Mini App, picked by the club in the admin
-- Mini App. Not every club is a billiards club: a PlayStation club was stuck
-- with the 8-ball card. The design also drives the fallback art on the
-- client's "Клуб" screen and the tagline under the club's wordmark.
alter table public.clubs
  add column if not exists card_design text not null default 'billiards';

alter table public.clubs drop constraint if exists clubs_card_design_check;
alter table public.clubs add constraint clubs_card_design_check
  check (card_design in ('billiards', 'pyramid', 'playstation', 'combo', 'neon', 'gold'));
