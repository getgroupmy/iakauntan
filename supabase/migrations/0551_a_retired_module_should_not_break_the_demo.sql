-- ---------------------------------------------------------------------
-- 0551  A retired module should not break the demo
-- ---------------------------------------------------------------------
-- `app.demo_rebuild()` refuses to run on the hosted project, and has
-- for as long as anything has been retired in the console:
--
--     ERROR: 42501: Insufficient privileges to raise a ticket
--     PL/pgSQL function create_ticket(...) line 13 at RAISE
--     PL/pgSQL function demo_tickets_sinar(uuid,uuid) line 97
--     PL/pgSQL function demo_rebuild() line 62
--
-- The chain, measured rather than guessed:
--
--   * `demo_tickets_sinar` grants itself what it needs --
--     `app.demo_modules(p_org, array['ticketing'])` -- and then raises
--     tickets.
--   * `app.demo_modules` inserts only `where exists (select 1 from
--     platform_modules m where m.code = c and m.is_active)`.
--   * `ticketing` is retired on the hosted project. Six are:
--     chat, loyalty, mailbox, memberships, ticketing, workspace_address.
--
-- So the grant matches nothing, inserts nothing, reports nothing, and
-- the next statement is refused by a module guard doing its job. One
-- switch in the console breaks the whole demo rebuild, and the failure
-- names a permission rather than the retirement that caused it.
--
-- ### Why CI never saw it
--
-- `supabase/tests/demo_rebuild.sql` runs the whole of `demo_rebuild()`
-- and passes. It passes because a database built from these migrations
-- has nothing retired -- `is_active` is true for every module in the
-- seed. The test therefore asserts the behaviour of a configuration
-- that only exists before anybody uses the console. It is green here
-- and red there, which is the worst arrangement available: the thing
-- CI is for is telling you the deployed system works.
--
-- The assertion added in `supabase/tests/demo_modules.sql` retires a
-- module first and then seeds, which is the state the hosted project
-- has been in for weeks.
--
-- ### The fix
--
-- A demo tenant may hold a retired module. It is showcase data, not a
-- customer: nothing is sold, nothing is billed (0489 bills only real
-- companies), and a retired module is usually retired because it is
-- not finished -- which is exactly the thing a demo is for.
--
-- For every other company the rule is unchanged, and that is the half
-- worth being careful about: `is_active = false` still means "nobody
-- new is offered this", and `set_own_module` still refuses it.
-- ---------------------------------------------------------------------

create or replace function app.demo_modules(p_org uuid, p_codes text[])
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_n    integer;
  v_demo boolean;
begin
  select coalesce(o.is_demo, false) into v_demo
    from public.organizations o where o.id = p_org;

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  select p_org, c, true, now()
    from unnest(p_codes) c
   where exists (
     select 1 from public.platform_modules m
      where m.code = c
        -- A retired module is still granted to a DEMO tenant. It is
        -- showcase data rather than a customer: nothing is sold and
        -- nothing is billed, and a module is usually retired because
        -- it is not finished, which is the thing a demo exists to
        -- show. For every other company `is_active` still decides.
        and (m.is_active or v_demo))
  on conflict (org_id, module_code)
    do update set is_enabled = true, enabled_at = now();
  get diagnostics v_n = row_count;

  -- A seed asking for a module that does not exist at all is a typo in
  -- a seed, and it used to be silent: the row simply did not appear and
  -- the next statement failed somewhere else with a permission error.
  -- Saying so here costs nothing and names the actual problem.
  if v_n < coalesce(array_length(p_codes, 1), 0) then
    raise warning 'demo_modules(%): asked for %, granted %. Missing: %',
      p_org, array_length(p_codes, 1), v_n,
      (select string_agg(c, ', ')
         from unnest(p_codes) c
        where not exists (select 1 from public.platform_modules m
                           where m.code = c));
  end if;

  return v_n;
end $$;

comment on function app.demo_modules(uuid, text[]) is
  'Grants modules to a demo tenant, including retired ones -- a demo is '
  'showcase data and a retired module is usually one still being '
  'finished. For any other company is_active still decides. See 0551.';
