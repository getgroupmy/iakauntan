-- =====================================================================
-- iAkauntan :: 0623 the other half of the payslip log
--
-- `20260909090115` found that `payslip_access_requests_requested_by_fkey`
-- and `..._decided_by_fkey` pointed at `auth.users`, which PostgREST
-- cannot traverse to `profiles` -- so `requester:profiles!..._fkey`
-- answered PGRST200 and the Team & Access page rebooted the app in a
-- loop. It renamed both to `..._auth_fkey` and gave the expected names
-- to new keys on `public.profiles`.
--
-- It fixed the two it was looking at. `payslip_access_log_actor_id_fkey`
-- is the third, has the same shape, and is embedded the same way one
-- screen over:
--
--   .select('*, actor:profiles!payslip_access_log_actor_id_fkey(...)')
--
-- It survived because `scripts/check_embeds.py` -- which exists to
-- catch exactly this and caught the first two -- was reading only the
-- FIRST string literal of a `.select()`, and this one is on the second
-- line. That hole is closed in the same commit; this is one of the ten
-- things behind it.
--
-- Same remedy, and deliberately the same ON DELETE as the constraint it
-- sits beside: `profiles.id` references `auth.users(id) on delete
-- cascade` already, so a second cascading path changes nothing about
-- what happens to a log row. This adds a route PostgREST can follow and
-- alters no behaviour.
-- =====================================================================

alter table public.payslip_access_log
  rename constraint payslip_access_log_actor_id_fkey
  to payslip_access_log_actor_id_auth_fkey;

alter table public.payslip_access_log
  add constraint payslip_access_log_actor_id_fkey
  foreign key (actor_id) references public.profiles (id) on delete cascade;

notify pgrst, 'reload schema';

do $do$
begin
  if not exists (
    select 1 from pg_constraint co
    join pg_class c on c.oid = co.conrelid
    join pg_class f on f.oid = co.confrelid
    join pg_namespace fn on fn.oid = f.relnamespace
   where co.conname = 'payslip_access_log_actor_id_fkey'
     and c.relname = 'payslip_access_log'
     and fn.nspname = 'public' and f.relname = 'profiles') then
    raise exception
      'payslip_access_log_actor_id_fkey still does not reach '
      'public.profiles, which is the whole of what 0623 is for.';
  end if;
end
$do$;
