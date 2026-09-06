-- =====================================================================
-- iAkauntan :: the feed that tells every screen what moved
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/live_change_feed.sql
--
-- `0547` put a statement trigger on every table carrying an `org_id`,
-- so any write anywhere appends (org_id, table_name) to
-- `live_changes` and the app re-reads what it shows. Three things have
-- to hold or the feed is worse than none:
--
--   1. EVERY org-scoped table is on it. One table quietly without a
--      trigger is one screen quietly stale, and nothing else in the
--      product would say so.
--   2. A statement appends ONE row per company, not one per row. A
--      payroll run writing four hundred payslip lines must not append
--      four hundred notices.
--   3. Another company cannot read the feed, and a clerk cannot read
--      that payroll moved. The row carries no data, but a table name
--      and a timestamp are still something.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- 1. Every org-scoped table is on the feed
-- ---------------------------------------------------------------------
do $$
declare
  v_missing text[];
begin
  select coalesce(array_agg(c.relname order by c.relname), '{}')
    into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relname <> 'live_changes'
     and exists (
       select 1 from information_schema.columns col
        where col.table_schema = 'public'
          and col.table_name = c.relname
          and col.column_name = 'org_id'
     )
     and not exists (
       select 1 from pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgname = 'live_change_insert'
     );

  perform pg_temp.check_eq(
    'every table with an org_id appends to the feed',
    array_to_string(v_missing, ', '),
    ''
  );
end $$;

-- The company's own row is the exception, and has to have its own
-- trigger rather than none: `organizations` is keyed by `id`, so a
-- trigger reading `org_id` off it would find no such column.
do $$
begin
  perform pg_temp.check_true(
    'the company row is on the feed too',
    exists (
      select 1 from pg_trigger
       where tgrelid = 'public.organizations'::regclass
         and not tgisinternal
         and tgname = 'live_change_update'
    )
  );
end $$;

-- Insert, update and delete. A screen showing a list is as wrong about a
-- row that has gone as about one that arrived.
do $$
declare
  v_missing text[];
begin
  select coalesce(array_agg(c.relname || ':' || w.want order by c.relname), '{}')
    into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   cross join (values ('live_change_insert'), ('live_change_update'),
                     ('live_change_delete')) as w(want)
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relname <> 'live_changes'
     and exists (
       select 1 from information_schema.columns col
        where col.table_schema = 'public'
          and col.table_name = c.relname
          and col.column_name = 'org_id'
     )
     and not exists (
       select 1 from pg_trigger t
        where t.tgrelid = c.oid and not t.tgisinternal and t.tgname = w.want
     );

  perform pg_temp.check_eq(
    'and on all three of insert, update and delete',
    array_to_string(v_missing, ', '),
    ''
  );
end $$;

-- ---------------------------------------------------------------------
-- 2. One notice per statement, not one per row
-- ---------------------------------------------------------------------
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_n     integer;
  v_at    timestamptz;
begin
  v_org := pg_temp.test_org('Kedai Suapan Langsung Sdn Bhd');

  delete from public.live_changes where org_id = v_org;

  -- Five warehouses in ONE statement.
  insert into public.warehouses (org_id, code, name)
  select v_org, 'W' || g, 'Store ' || g from generate_series(1, 5) g;

  select count(*) into v_n
    from public.live_changes
   where org_id = v_org and table_name = 'warehouses';
  perform pg_temp.check_eq(
    'five rows in one statement is one notice', v_n::numeric, 1);

  -- An update over all five, likewise.
  update public.warehouses set name = name || ' (main)' where org_id = v_org;
  select count(*) into v_n
    from public.live_changes
   where org_id = v_org and table_name = 'warehouses';
  perform pg_temp.check_eq(
    'and the update that follows is the second', v_n::numeric, 2);

  -- And a delete, which is the one a list screen most needs.
  delete from public.warehouses where org_id = v_org and code = 'W5';
  select count(*) into v_n
    from public.live_changes
   where org_id = v_org and table_name = 'warehouses';
  perform pg_temp.check_eq(
    'a row that has gone is news as well', v_n::numeric, 3);

  -- The company row itself.
  delete from public.live_changes where org_id = v_org;
  update public.organizations set tin = 'C1234567890' where id = v_org;
  select count(*) into v_n
    from public.live_changes
   where org_id = v_org and table_name = 'organizations';
  perform pg_temp.check_eq(
    'the company row reports under its own name', v_n::numeric, 1);

  -- The notice carries a company and a table name and nothing else:
  -- there is no column on it that could hold a row.
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'live_changes';
  perform pg_temp.check_eq(
    'the notice has four columns and no payload', v_n::numeric, 4);
end $$;

-- ---------------------------------------------------------------------
-- 3. Who may read that something moved
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq(
    'a key changing is an administrator''s business',
    app.live_change_audience('einvoice_credentials'), 'admin');
  perform pg_temp.check_eq(
    'and so is a payment gateway',
    app.live_change_audience('org_payment_gateways'), 'admin');
  perform pg_temp.check_eq(
    'one employee''s pay is not the office''s',
    app.live_change_audience('payslips'), 'payroll');
  perform pg_temp.check_eq(
    'nor is what a payroll run paid out',
    app.live_change_audience('payroll_runs'), 'payroll');
  perform pg_temp.check_eq(
    'an invoice, though, is everybody''s work',
    app.live_change_audience('sales_documents'), 'member');
  -- A table nobody classified is a member table, which is the safe
  -- default only because the restricted list is asserted above by name.
  perform pg_temp.check_eq(
    'and so is a table added tomorrow',
    app.live_change_audience('a_table_nobody_has_written_yet'), 'member');
end $$;

-- The policy, as a member of another company and as a clerk in this one.
do $$
declare
  v_me     uuid := pg_temp.test_user();
  v_org    uuid;
  v_other  uuid;
  v_clerk  uuid;
  v_n      integer;
begin
  v_org := pg_temp.test_org('Kilang Berita Langsung Sdn Bhd');

  delete from public.live_changes where org_id = v_org;
  insert into public.live_changes (org_id, table_name)
  values (v_org, 'sales_documents'), (v_org, 'payslips'),
         (v_org, 'einvoice_credentials');

  -- Counted by name throughout, and not as "how many rows are there".
  -- Setting this test up is itself work on the company -- adding the
  -- clerk writes `org_members`, and that writes an audit row -- and
  -- both land on the feed, correctly, while the reader is looking.
  v_clerk := pg_temp.another_user('kerani@berita.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accounts_clerk', 'active', now())
  on conflict (org_id, user_id) do update
    set role = 'accounts_clerk', status = 'active';

  -- The owner sees all three: they administer the company and may run
  -- payroll.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_me, 'role', 'authenticated')::text, true);
  select count(*) into v_n
    from public.live_changes
   where org_id = v_org
     and table_name in
         ('sales_documents', 'payslips', 'einvoice_credentials');
  perform pg_temp.check_eq(
    'the owner is told about all three', v_n::numeric, 3);
  reset role;

  -- A clerk sees the invoice and neither of the other two.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_clerk, 'role', 'authenticated')::text, true);
  select count(*) into v_n
    from public.live_changes
   where org_id = v_org and table_name = 'sales_documents';
  perform pg_temp.check_eq(
    'a clerk is told the invoice moved', v_n::numeric, 1);
  select count(*) into v_n
    from public.live_changes
   where org_id = v_org and table_name in ('payslips', 'einvoice_credentials');
  perform pg_temp.check_eq(
    'and is not told that payroll or a key moved', v_n::numeric, 0);
  reset role;

  -- Somebody from another company sees nothing at all.
  v_other := pg_temp.another_user('orang.luar@berita.test');
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_other, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.live_changes where org_id = v_org;
  perform pg_temp.check_eq(
    'another company is told nothing', v_n::numeric, 0);
  reset role;
end $$;

-- The feed is not a thing a client may write. Somebody who could append
-- here could make every other screen in the company refetch on command.
do $$
declare
  v_me  uuid := pg_temp.test_user();
  v_org uuid;
begin
  v_org := pg_temp.test_org('Kedai Tulis Suapan Sdn Bhd');

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_me, 'role', 'authenticated')::text, true);

  perform pg_temp.check_refused(
    'a member cannot append to the feed by hand',
    format('insert into public.live_changes (org_id, table_name)
            values (%L, %L)', v_org, 'sales_documents'),
    '%',
    null
  );
  reset role;
end $$;

rollback;
