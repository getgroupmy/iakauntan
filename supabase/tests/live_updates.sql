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
    -- 0124. `claim_approvals` is the one that would be easy to leave
    -- out and would matter most: clearing an intermediate step writes
    -- there and nowhere else, so without it an approval queue would
    -- update at the end of a claim's life and never in the middle.
    'expense_claims', 'claim_approvals',
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

-- ---------------------------------------------------------------------
-- A claim is one person's business, and publishing it does not change
-- that
--
-- 0117 kept payslips out on the grounds that one employee's pay is not
-- the office's, and a claim is the same kind of thing. 0124 publishes it
-- anyway, which is only safe because Realtime decides who is sent a row
-- by asking row level security, and `expense_claims_select` is already
-- narrower than "a member of this company".
--
-- The check above — published tables have RLS on and at least one
-- policy — would pass a policy of `using (true)`. This is the one that
-- would not. It runs as `authenticated` because the connection is a
-- superuser and a superuser bypasses row level security entirely, which
-- would make the whole thing pass while proving nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Sulit Sdn Bhd');
  v_mine_user uuid := pg_temp.another_user('claimant@sulit.test');
  v_nosy_user uuid := pg_temp.another_user('colleague@sulit.test');
  v_mine uuid; v_nosy uuid; v_claim uuid;
  v_colleague_sees int;
  v_claimant_sees int;
  v_role text;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_mine_user, 'employee'), (v_org, v_nosy_user, 'employee')
  on conflict do nothing;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-1', 'Claimant', v_mine_user, current_date)
  returning id into v_mine;

  -- Same company, no relationship: not their manager, no HR role, not
  -- allowed to post. The ordinary colleague.
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-2', 'Colleague', v_nosy_user, current_date)
  returning id into v_nosy;

  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CLM-PRIVATE', v_mine, current_date, 'Clinic', 'submitted', 90)
  returning id into v_claim;

  perform pg_temp.sign_in_as(v_nosy_user);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_colleague_sees
      from public.expense_claims where id = v_claim;
  end;
  reset role;

  perform pg_temp.sign_in_as(v_mine_user);
  begin
    set local role authenticated;
    select count(*) into v_claimant_sees
      from public.expense_claims where id = v_claim;
  end;
  reset role;

  perform pg_temp.check_true('the claim test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'a colleague is not sent somebody else''s claim', v_colleague_sees = 0);
  -- The control. Without it, a policy that hid the row from everybody
  -- would read as a policy doing its job.
  perform pg_temp.check_true(
    'while the claimant still gets their own', v_claimant_sees = 1);
end $$;

rollback;
