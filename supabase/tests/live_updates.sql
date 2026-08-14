-- =====================================================================
-- iAkauntan :: what leaves the database over a socket
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/live_updates.sql
--
-- Publishing a table to `supabase_realtime` is a decision about who can
-- see a row the moment it is written, and it is made in one line of SQL
-- that looks like configuration. This is the check on that line.
--
-- The property that matters is the third one. Realtime applies
-- row-level security to decide which subscriber receives which row — so
-- a published table *without* RLS is broadcast to every signed-in user
-- of every organization, and it would look exactly like a working
-- feature while doing it. Anything added to the publication later has to
-- pass this or fail CI.
--
-- Asserted:
--
--   * every table the app subscribes to is published, so the feature
--     works rather than silently doing nothing;
--   * each of them keeps full replica identity, without which a DELETE
--     carries only its primary key, cannot be matched against RLS, and
--     is dropped — a document deleted by a colleague would stay on
--     screen;
--   * every published table has RLS enabled and at least one policy;
--   * nothing holding a secret or one person's private business is
--     published at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The app's subscriptions have something to subscribe to
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
  v_published boolean;
  v_identity "char";
begin
  foreach v_table in array array[
    'organizations', 'sales_documents', 'purchase_documents', 'receipts',
    'purchase_payments', 'contacts', 'items', 'expenses', 'gl_entries',
    'org_credits'
  ]
  loop
    select exists (
      select 1
        from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public'
         and c.relname = v_table
    ) into v_published;
    perform pg_temp.check_true(
      format('%s is published for live updates', v_table), v_published);

    select c.relreplident into v_identity
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = v_table;
    perform pg_temp.check_true(
      format('%s keeps full rows, so a delete can be filtered', v_table),
      v_identity = 'f');
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Nothing is published that RLS is not guarding
-- ---------------------------------------------------------------------
do $$
declare
  v_row record;
begin
  for v_row in
    select c.relname,
           c.relrowsecurity as rls,
           (select count(*) from pg_policies pol
             where pol.schemaname = 'public' and pol.tablename = c.relname)
             as policies
      from pg_publication_rel pr
      join pg_publication p on p.oid = pr.prpubid
      join pg_class c on c.oid = pr.prrelid
      join pg_namespace n on n.oid = c.relnamespace
     where p.pubname = 'supabase_realtime' and n.nspname = 'public'
  loop
    -- Without this, every row written to the table is delivered to every
    -- subscriber, whichever organization they belong to.
    perform pg_temp.check_true(
      format('%s is published and has RLS on', v_row.relname), v_row.rls);
    perform pg_temp.check_true(
      format('%s is published and has a policy', v_row.relname),
      v_row.policies > 0);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- And nothing private is published at all
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
  v_published boolean;
begin
  -- Keys, one person's pay, and the platform's own books. None of these
  -- change often enough for live updates to be worth widening what
  -- leaves the database.
  foreach v_table in array array[
    'einvoice_credentials', 'org_ocr_credentials', 'org_ocr_settings',
    'payslips', 'payroll_runs', 'platform_settings', 'platform_invoices',
    'profiles'
  ]
  loop
    select exists (
      select 1
        from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public'
         and c.relname = v_table
    ) into v_published;
    perform pg_temp.check_true(
      format('%s is not broadcast', v_table), not v_published);
  end loop;
end $$;

rollback;
