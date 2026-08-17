-- A new function is not everybody's function.
--
-- Postgres grants `EXECUTE` to `PUBLIC` on every function it creates,
-- and `anon` is in PUBLIC. So a migration that writes
--
--   create function app.something(...) ... security definer ...;
--   grant execute on function app.something(...) to authenticated;
--
-- has not restricted anything: the grant is additive and the implicit
-- PUBLIC one is still there. Sixteen functions across `0162`–`0164` went
-- in that way and `supabase/tests/statutory.sql` caught every one of
-- them on CI run 188 — which is the test doing exactly its job.
--
-- Most of the sixteen self-guard: `raise_strata_charges` checks
-- `can_post`, `strata_arrears` checks `is_org_member`, and an anonymous
-- caller gets a refusal rather than data. Three did not:
--
--   * `app.strata_rate_on` returns a scheme's charge rate to anyone who
--     names the scheme.
--   * `app.property_income_account` and `app.time_income_account` are
--     SECURITY DEFINER and **insert an accounts row**. An anonymous
--     caller holding an organization's uuid could create a ledger
--     account in it.
--
-- Both are gated behind an unguessable uuid, which is why this is a hole
-- rather than an open door. It is still a hole.
--
-- ---------------------------------------------------------------------
-- The fix is the one this schema already uses for the same shape of
-- mistake. `ensure_rls` is an event trigger that turns row level
-- security on for every new table, because remembering to do it by hand
-- is a rule that gets forgotten exactly once and then silently. This is
-- that, for function privileges.

create or replace function app.revoke_public_execute()
returns event_trigger language plpgsql
set search_path = pg_catalog, public, pg_temp as $$
declare cmd record;
begin
  for cmd in select * from pg_event_trigger_ddl_commands() loop
    -- Only our own two schemas. An extension installing its own
    -- functions is not this rule's business, and stripping PUBLIC from
    -- `citext_eq` would break every comparison in the database.
    if cmd.command_tag = 'CREATE FUNCTION'
       and cmd.schema_name in ('public', 'app') then
      -- PUBLIC *and* anon. Revoking PUBLIC alone is not enough here:
      -- Supabase ships `alter default privileges in schema public grant
      -- all on functions to anon, authenticated, service_role`, so a new
      -- function in `public` arrives with an explicit anon grant already
      -- attached. Verified rather than assumed — after revoking PUBLIC
      -- from all sixteen, the nine in `public` were still reachable by
      -- anon and the seven in `app` were not.
      --
      -- A grant to `authenticated` survives, which is what makes this
      -- safe to leave on. A function anon genuinely needs must say so
      -- *after* its create, which all three of the token-gated ones
      -- already do.
      execute format('revoke execute on function %s from public',
                     cmd.object_identity);
      execute format('revoke execute on function %s from anon',
                     cmd.object_identity);
    end if;
  end loop;
end $$;

create event trigger revoke_public_execute
  on ddl_command_end
  when tag in ('CREATE FUNCTION')
  execute function app.revoke_public_execute();

-- ---------------------------------------------------------------------
-- And the sixteen already in
--
-- Written out rather than looped over every SECURITY DEFINER function in
-- the schema. A blanket revoke would also strip PUBLIC from functions
-- that have been reachable since 0010 and are relied on somewhere this
-- migration cannot see; naming them keeps the change to what 0162–0164
-- actually added.
-- ---------------------------------------------------------------------
revoke execute on function app.has_property_module(uuid) from public;
revoke execute on function app.strata_rate_on(uuid, date) from public;
revoke execute on function app.property_income_account(uuid, text) from public;
revoke execute on function public.strata_charge_preview(uuid, date, date) from public;
revoke execute on function public.raise_strata_charges(uuid, date, date, date) from public;
revoke execute on function public.strata_arrears(uuid, date) from public;
revoke execute on function public.rent_preview(uuid, date, date) from public;
revoke execute on function public.raise_rent_invoices(uuid, date, date, date) from public;
revoke execute on function public.property_statutory_due(uuid, integer) from public;

revoke execute on function app.has_time_module(uuid) from public;
revoke execute on function app.billing_rate_for(uuid, uuid, uuid, uuid, date) from public;
revoke execute on function app.time_income_account(uuid) from public;
revoke execute on function app.bill_time_internal(
  uuid, uuid, uuid, uuid, text, date, date, date) from public;
revoke execute on function public.bill_project_time(uuid, date, date, date) from public;
revoke execute on function public.bill_matter_time(uuid, date, date, date) from public;
revoke execute on function public.report_timesheet(uuid, date, date) from public;

-- The grants a signed-in member needs are re-stated here, because a
-- reader should be able to see from this file alone who is left holding
-- each of them. `app.has_property_module` and `app.has_time_module` are
-- called from inside RLS policies, which are evaluated as the querying
-- user, so `authenticated` genuinely needs those two.
grant execute on function app.has_property_module(uuid) to authenticated;
grant execute on function app.has_time_module(uuid) to authenticated;
grant execute on function app.billing_rate_for(uuid, uuid, uuid, uuid, date)
  to authenticated;
grant execute on function public.strata_charge_preview(uuid, date, date) to authenticated;
grant execute on function public.raise_strata_charges(uuid, date, date, date) to authenticated;
grant execute on function public.strata_arrears(uuid, date) to authenticated;
grant execute on function public.rent_preview(uuid, date, date) to authenticated;
grant execute on function public.raise_rent_invoices(uuid, date, date, date) to authenticated;
grant execute on function public.property_statutory_due(uuid, integer) to authenticated;
grant execute on function public.bill_project_time(uuid, date, date, date) to authenticated;
grant execute on function public.bill_matter_time(uuid, date, date, date) to authenticated;
grant execute on function public.report_timesheet(uuid, date, date) to authenticated;

-- The nine in `public` needed anon taking off them by name, for the
-- default-privileges reason above.
revoke execute on function public.strata_charge_preview(uuid, date, date) from anon;
revoke execute on function public.raise_strata_charges(uuid, date, date, date) from anon;
revoke execute on function public.strata_arrears(uuid, date) from anon;
revoke execute on function public.rent_preview(uuid, date, date) from anon;
revoke execute on function public.raise_rent_invoices(uuid, date, date, date) from anon;
revoke execute on function public.property_statutory_due(uuid, integer) from anon;
revoke execute on function public.bill_project_time(uuid, date, date, date) from anon;
revoke execute on function public.bill_matter_time(uuid, date, date, date) from anon;
revoke execute on function public.report_timesheet(uuid, date, date) from anon;

-- Deliberately left with no grant at all: `app.strata_rate_on`,
-- `app.property_income_account`, `app.time_income_account` and
-- `app.bill_time_internal`. Every caller is a SECURITY DEFINER function
-- that runs as the owner, so nothing signed in ever needs to reach them
-- directly — and the two that create accounts are the ones this
-- migration exists for.
