-- Allow a one-visit promo (owners try the coupon flow with 1 visit first).
alter table public.club_visit_promos drop constraint if exists club_visit_promos_visits_needed_check;
alter table public.club_visit_promos add constraint club_visit_promos_visits_needed_check
  check (visits_needed between 1 and 50);
