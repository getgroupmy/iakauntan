-- =====================================================================
-- iAkauntan :: the notice nobody posted
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/maintenance_mode.sql
--
-- `0018` seeded `maintenance_mode` as "Show a maintenance banner and
-- block writes" and it has never done either. `0564` keeps both
-- promises, and the three assertions worth the file are:
--
--   * a write is actually refused, not merely discouraged;
--   * reads are not, because somebody looking at an invoice when the
--     shutter comes down goes on looking at it;
--   * platform staff are not locked out, because the operator who
--     turned it on has to be able to turn it off -- which is the
--     property that stops this being a way to brick the platform with
--     one click.
--
-- ---------------------------------------------------------------------
-- Mutants, each named with the assertion that killed it
--
--   `can_write` without its `not in_maintenance()` clause, so the
--   banner shows and nothing is blocked -- "nobody may write".
--
--   `in_maintenance()`'s fallback flipped, so a deleted row stops every
--   write in the product -- "a missing setting reads as open".
--
--   the grant left off `can_write`, which is the state the first draft
--   of `0564` was in after `0165`'s event trigger stripped PUBLIC --
--   "permission denied for function can_write", at the first write.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Open, and open when the row is missing
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the platform starts open',
    not app.in_maintenance());
  perform pg_temp.check_true('and says nothing',
    public.maintenance_notice() is null);

  -- A deleted row that stopped every write in the product would be the
  -- failure of a lookup wearing the face of a decision -- and this one
  -- would fail closed across every company at once.
  delete from public.platform_settings where key = 'maintenance_mode';
  perform pg_temp.check_true('a missing setting reads as open',
    not app.in_maintenance());

  insert into public.platform_settings (key, value, description)
  values ('maintenance_mode', '{"enabled": false, "message": ""}'::jsonb,
          'Show a maintenance banner and block writes');
end $$;

-- ---------------------------------------------------------------------
-- The fixture, built while the platform is open
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid;
  v_org   uuid;
  v_id    uuid;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Tutup Sementara Sdn Bhd', array[]::text[]);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-MAINT', 'Pelanggan Sdn Bhd', 'customer')
  returning id into v_id;

  create temporary table fixture on commit drop as
  select v_org as org, v_owner as owner, v_id as contact;
end $$;

-- ---------------------------------------------------------------------
-- Shut
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;

  update public.platform_settings
     set value = jsonb_build_object('enabled', true, 'message', '')
   where key = 'maintenance_mode';

  perform pg_temp.check_true('the switch is read at all', app.in_maintenance());

  perform pg_temp.sign_in_as(f.owner);

  -- The two guards this schema uses for "may change things". Against
  -- every version before `0564` both answer true here and the setting
  -- is decoration.
  perform pg_temp.check_true('nobody may write', not app.can_write(f.org));
  perform pg_temp.check_true('not even the company''s owner',
    not app.can_admin(f.org));

  set local role authenticated;

  -- THE ASSERTION THIS FILE EXISTS FOR. A policy refusing an UPDATE
  -- touches no rows and raises nothing, which is what a refusal looks
  -- like from here.
  update public.contacts set name = 'Changed' where id = f.contact;
  perform pg_temp.check_eq('and a write changes nothing',
    (select name from public.contacts where id = f.contact),
    'Pelanggan Sdn Bhd');

  -- Reads are untouched, deliberately. Somebody who was looking at an
  -- invoice when the shutter came down goes on looking at it.
  perform pg_temp.check_eq('but the books are still readable',
    (select count(*) from public.contacts where id = f.contact), 1::bigint);
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- And every other door, which `0564` left open
--
-- `0564` said gating `can_write` and `can_admin` gated the writes,
-- because "every policy that guards a write already asks one of them".
-- It does not. `can_write_module` alone guards 162 policies and asks
-- neither -- so with the shutter down a till kept selling, a journal
-- could be posted, a payroll run could be approved and an employee
-- record could be changed, while invoices and settings stopped.
--
-- Asserted as a rule over the schema rather than as a list, so a
-- guard added later fails this file until somebody decides which it
-- is: a write, and gated, or a read, and named below.
-- ---------------------------------------------------------------------
do $$
declare
  f       record;
  v_open  text;
begin
  select * into f from fixture;

  update public.platform_settings
     set value = jsonb_build_object('enabled', true, 'message', '')
   where key = 'maintenance_mode';
  perform pg_temp.sign_in_as(f.owner);

  perform pg_temp.check_true('the ledger is shut', not app.can_post(f.org));
  perform pg_temp.check_true('and every module''s write permission',
    not app.can_write_module(f.org, 'pos'));
  perform pg_temp.check_true('and payroll',
    not app.can_run_payroll(f.org));
  perform pg_temp.check_true('and personnel records',
    not app.can_manage_hr(f.org));
  perform pg_temp.check_true('and the till''s void',
    not app.can_void_pos(f.org));
  perform pg_temp.check_true('and its discount',
    not app.can_discount_pos(f.org));
  perform pg_temp.check_true('and standing up another company',
    not app.can_add_company());

  -- Reads are untouched, which is `0564`'s own rule and the reason
  -- this is a list of exceptions rather than "gate everything".
  perform pg_temp.check_true('but the ledger is still readable',
    app.can_read_ledger(f.org));

  -- THE ASSERTION THIS BLOCK EXISTS FOR, and it is the one that would
  -- have caught `0564`. Every `app.can_*` guard either asks
  -- `in_maintenance` or is named here as a read. A ninth guard added
  -- next year fails this line rather than silently staying open.
  select string_agg(p.proname, ', ' order by p.proname) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname like 'can\_%'
     and pg_get_functiondef(p.oid) not like '%in_maintenance%'
     and p.proname not in (
       -- Reads. Somebody looking at an invoice when the shutter comes
       -- down goes on looking at it.
       'can_read_ledger', 'can_read_module', 'can_read_attachment',
       -- `0460`'s bug-report path is deliberately open: maintenance is
       -- when people file them, and the rest of this function already
       -- routes through `can_write`.
       'can_attach_to');

  perform pg_temp.check_eq(
    'and no other write guard stays open with the shutter down',
    coalesce(v_open, ''), '');

  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '')
   where key = 'maintenance_mode';
end $$;

-- ---------------------------------------------------------------------
-- And the switch can always be reached
-- ---------------------------------------------------------------------
do $$
declare v_staff uuid;
begin
  v_staff := pg_temp.another_user('ops@iakauntan.test');
  insert into public.platform_admins (user_id) values (v_staff)
  on conflict do nothing;
  perform pg_temp.sign_in_as(v_staff);

  -- The property that stops this being a way to brick the platform
  -- with one press. `platform_settings` is guarded by
  -- `is_platform_admin` alone, and `0564` does not gate that.
  perform pg_temp.check_true('platform staff are not locked out',
    app.is_platform_admin());

  set local role authenticated;
  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '')
   where key = 'maintenance_mode';
  reset role;

  perform pg_temp.check_true('so the shutter can be raised again',
    not app.in_maintenance());
end $$;

-- ---------------------------------------------------------------------
-- And writes come back
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  select * into f from fixture;
  perform pg_temp.sign_in_as(f.owner);
  set local role authenticated;

  update public.contacts set name = 'Changed' where id = f.contact;
  perform pg_temp.check_eq('a write lands once it is over',
    (select name from public.contacts where id = f.contact), 'Changed');
  reset role;
end $$;

-- ---------------------------------------------------------------------
-- What a visitor is told
-- ---------------------------------------------------------------------
do $$
declare v_notice jsonb;
begin
  update public.platform_settings
     set value = jsonb_build_object('enabled', true,
                                    'message', 'Back at six.')
   where key = 'maintenance_mode';

  -- The person who most needs this is the one at the sign-in page
  -- wondering why their password stopped working.
  set local role anon;
  v_notice := public.maintenance_notice();
  reset role;

  perform pg_temp.check_eq('a stranger is told why',
    v_notice ->> 'message', 'Back at six.');

  -- Blank falls back rather than drawing an empty banner.
  update public.platform_settings
     set value = jsonb_build_object('enabled', true, 'message', '   ')
   where key = 'maintenance_mode';
  set local role anon;
  v_notice := public.maintenance_notice();
  reset role;
  perform pg_temp.check_true('and told something when nobody wrote words',
    v_notice ->> 'message' like '%being worked on%');

  update public.platform_settings
     set value = jsonb_build_object('enabled', false, 'message', '')
   where key = 'maintenance_mode';
  set local role anon;
  v_notice := public.maintenance_notice();
  reset role;
  -- Null rather than `{"enabled": false}`, so a client cannot draw an
  -- empty banner from a field that is always populated.
  perform pg_temp.check_true('and nothing at all when it is over',
    v_notice is null);
end $$;

-- ---------------------------------------------------------------------
-- And the guards are still reachable
-- ---------------------------------------------------------------------
do $$
begin
  -- `0165` strips EXECUTE from PUBLIC on every CREATE FUNCTION, and a
  -- REPLACE fires it. Both of these predate `0165` and had no grant of
  -- their own, so restating them took away the only one they had and
  -- every write policy in the schema began refusing everybody. Asserted
  -- here because the failure is total and the cause is three migrations
  -- away from the change that triggers it.
  perform pg_temp.check_true('authenticated can still call can_write',
    has_function_privilege('authenticated', 'app.can_write(uuid)', 'execute'));
  perform pg_temp.check_true('and can_admin',
    has_function_privilege('authenticated', 'app.can_admin(uuid)', 'execute'));
  perform pg_temp.check_true('and anon cannot',
    not has_function_privilege('anon', 'app.can_write(uuid)', 'execute'));

  -- `0568` restated eight more, four of which had no grant of their
  -- own either. Same trap, same assertion.
  perform pg_temp.check_true('and the eight 0568 restated are reachable too',
    has_function_privilege('authenticated', 'app.can_post(uuid)', 'execute')
    and has_function_privilege('authenticated',
      'app.can_write_module(uuid,text)', 'execute')
    and has_function_privilege('authenticated',
      'app.can_run_payroll(uuid)', 'execute')
    and has_function_privilege('authenticated',
      'app.can_manage_hr(uuid)', 'execute')
    and has_function_privilege('authenticated',
      'app.can_void_pos(uuid)', 'execute')
    and has_function_privilege('authenticated',
      'app.can_discount_pos(uuid)', 'execute')
    and has_function_privilege('authenticated',
      'app.can_add_company()', 'execute')
    and has_function_privilege('authenticated',
      'app.can_manage_firm(uuid)', 'execute'));
end $$;

rollback;
