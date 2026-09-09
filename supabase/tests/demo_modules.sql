-- =====================================================================
-- iAkauntan :: what a retired module does to the demo
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_modules.sql
--
-- `demo_rebuild.sql` runs the whole rebuild and passes. It passes on a
-- database built from these migrations, where `is_active` is true for
-- every module because nothing has ever been retired -- which is the
-- configuration that exists before anybody opens the console.
--
-- On the hosted project six modules are retired, and the rebuild has
-- been failing there with a permission error naming `create_ticket`:
-- `demo_tickets_sinar` grants itself `ticketing`, `demo_modules` only
-- granted active modules, the grant matched nothing, and the next
-- statement was refused by a module guard doing its job.
--
-- So the fixture here retires a module FIRST. That is the state the
-- deployed system is actually in, and the only state in which this
-- failure exists.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_demo    uuid;
  v_real    uuid;
  v_granted integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_demo := pg_temp.test_org('Sinar Contoh Sdn Bhd', array['crm']);
  perform pg_temp.allow_many_companies();
  v_real := pg_temp.test_org('Syarikat Sebenar Sdn Bhd', array['crm']);

  update public.organizations set is_demo = true where id = v_demo;

  -- Retire it, exactly as the console does.
  update public.platform_modules set is_active = false where code = 'ticketing';
  perform pg_temp.check_true('the module under test is retired',
    not (select is_active from public.platform_modules where code = 'ticketing'));

  -- ------------------------------------------------------------------
  -- The demo gets it anyway
  -- ------------------------------------------------------------------
  v_granted := app.demo_modules(v_demo, array['ticketing']);
  perform pg_temp.check_eq('a demo tenant is granted a retired module',
    v_granted, 1);
  perform pg_temp.check_true('so the seed that needs it can run',
    app.has_module(v_demo, 'ticketing'));
  perform pg_temp.check_true('and the guard that refused the rebuild passes',
    app.can_write_module(v_demo, 'ticketing'));

  -- ------------------------------------------------------------------
  -- And a real company does not
  -- ------------------------------------------------------------------
  -- The half worth being careful about. `is_active = false` still means
  -- nobody new is offered it.
  perform pg_temp.check_eq('a real company is not granted a retired module',
    app.demo_modules(v_real, array['ticketing']), 0);
  perform pg_temp.check_true('and does not hold it',
    not app.has_module(v_real, 'ticketing'));

  -- An active module reaches both, which is the case that must not have
  -- been broken on the way past.
  perform pg_temp.check_eq('an active module still reaches a real company',
    app.demo_modules(v_real, array['inventory']), 1);
  perform pg_temp.check_true('and it holds it',
    app.has_module(v_real, 'inventory'));

  update public.platform_modules set is_active = true where code = 'ticketing';

  -- And put the fixture back to being an ordinary company. The rebuild
  -- below tears down every `is_demo` org, and it refuses -- rightly --
  -- to tear down one carrying a real member, which this fixture's
  -- owner is.
  update public.organizations set is_demo = false where id = v_demo;
end $$;

-- ---------------------------------------------------------------------
-- The whole rebuild, with something retired
-- ---------------------------------------------------------------------
-- The assertion that would have caught this. `demo_rebuild()` walks
-- every seed and several of them grant themselves an add-on; with one
-- retired, the run used to die on whichever seed asked for it first.
do $$
declare
  v_report text;
  v_tickets integer;
begin
  update public.platform_modules set is_active = false
   where code in ('ticketing', 'chat');

  v_report := app.demo_rebuild();

  perform pg_temp.check_true('the rebuild survives a retired module',
    v_report is not null and v_report <> '');

  -- And the seed that needed the retired one actually produced
  -- something, rather than being skipped quietly.
  select count(*) into v_tickets from public.tickets t
    join public.organizations o on o.id = t.org_id
   where o.slug like 'sinar-teknologi%';
  perform pg_temp.check_true('and the seed that needed it still ran',
    v_tickets > 0);
end $$;

rollback;
