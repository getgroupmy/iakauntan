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
end $$;

rollback;
