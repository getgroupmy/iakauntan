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
-- 1. Every org-scoped table is on the feed, but three
-- ---------------------------------------------------------------------
-- All three are receipts for a READ, and they are the exception that the
-- blanket rule could not survive.
--
-- `security_events` and `payslip_access_log` are written BY reads:
-- `audit_trail` calls `note_read` calls `record_security_event`, and
-- `audit_list_payslips` / `audit_view_payslip` write the access log. Put
-- them on the feed and a screen showing either one refreshes, reads,
-- writes a receipt for the read, and is told to refresh again -- an
-- endless reload, which is what happened in production.
--
-- `ssm_api_log` (0604) is the third, and it is the same shape for a
-- different reason. A row is written when somebody LOOKS a company up
-- in SSM's register -- a read, and one that costs money, which is why
-- it is recorded at all. Two things make the trigger wrong rather than
-- merely unnecessary:
--
--   * Nobody may read the table. It is service-role only, like the
--     other two SSM tables `0589` created, so a notice on the feed
--     would wake every client watching that company to tell them a
--     table they cannot select from has moved.
--   * A search is several calls. `searchAll` follows up to ten pages
--     and each one logs, so one person typing one name would append ten
--     notices about nothing anybody can see.
--
-- So the rule is not "every org-scoped table" but "every org-scoped
-- table whose writes are changes that the company may see". A glance is
-- not a change, a lookup is not either, and a closure is a change the
-- company is specifically not being shown. The list below is the exception in full, and it
-- is a list rather than a pattern so that adding to it takes a
-- decision.
-- ONE list, in a function, because this file needs it TWICE -- once to
-- say these tables have no trigger, and again to say they are not
-- missing one. Two copies of a decision is two copies that drift, and
-- this one did: `ocr_provider_keys` was added to the first and the
-- second went on demanding a trigger for it.
create or replace function pg_temp.feed_exempt() returns text[]
language sql immutable as $fn$ select array[
    'security_events', 'payslip_access_log', 'ssm_api_log',
    -- 0619, and the fourth for a reason of its own. `account_closures`
    -- records that a company, a login or a ledger account has been
    -- closed, and NOBODY may read the table: row level security with no
    -- policy, the same shape as the credentials tables. A feed notice
    -- would wake every client watching that company to say a table they
    -- cannot select from has moved -- and in the one case that matters,
    -- to announce the company's own closure to the members who are in
    -- the same instant losing access to it.
    'account_closures',
    -- 0675, and the fifth. `ocr_provider_keys` is a pool of reader
    -- keys, RLS on with no policies and grants revoked, so the first
    -- half of the `ssm_api_log` argument applies unchanged: a notice
    -- would wake every client watching that company to say a table they
    -- cannot select from has moved.
    --
    -- The second half is worse here than anywhere else on this list.
    -- The counters that decide whether a key has anything left are ON
    -- THE ROW, and `app.claim_ocr_key` updates them as part of the
    -- claim -- so with the trigger attached, EVERY SCAN THE PLATFORM
    -- RUNS would append a change notice and wake every client watching
    -- that organization, for ever, about a number nobody can read.
    --
    -- Its two nearest neighbours, `org_ocr_credentials` and
    -- `ai_provider_credentials`, do carry the trigger: 0547 attached it
    -- to everything with an `org_id` that existed at the time, and
    -- neither is written often enough for anybody to have noticed. That
    -- is not a precedent to follow, and it is written down here rather
    -- than quietly diverged from.
    'ocr_provider_keys'] $fn$;

do $$
declare
  v_missing text[];
  v_receipts text[] := pg_temp.feed_exempt();
  v_wrongly_on text[];
begin
  select coalesce(array_agg(c.relname order by c.relname), '{}')
    into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relname <> 'live_changes'
     and not (c.relname = any (v_receipts))
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

  -- And the exception holds in the other direction. A future migration
  -- that re-runs 0547's attach block over everything with an org_id
  -- would put these two back and restore the reload loop, which is
  -- exactly what one nearly did.
  select coalesce(array_agg(r order by r), '{}') into v_wrongly_on
    from unnest(v_receipts) r
   where exists (
     select 1 from pg_trigger t
      where t.tgrelid = ('public.' || r)::regclass
        and not t.tgisinternal
        and t.tgname like 'live_change_%'
   );

  perform pg_temp.check_eq(
    'and a read-receipt table wakes nobody',
    array_to_string(v_wrongly_on, ', '),
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
     -- The same four tables the block above excuses, for the same
     -- reasons: three are written by reads, and a screen that refreshed
     -- on them would read again and never stop -- or, for
     -- `ssm_api_log`, would be told to re-read a table it may not
     -- select from. `account_closures` (0619) is the fourth: nobody may
     -- select from it either, and the change it records is a company's
     -- own closure, which is not news to push at the members who are
     -- losing access to it in the same instant.
     and not (c.relname = any (pg_temp.feed_exempt()))
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
