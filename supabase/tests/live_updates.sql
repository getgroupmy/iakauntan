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
    'org_credits',
    -- 0302. What the platform console edits. These belong to no company
    -- and so carry no `org_id` to filter on; what decides who is sent a
    -- row is the policy on the table, which is asserted below.
    'platform_modules', 'platform_settings',
    'landing_page', 'landing_sections', 'landing_app_links',
    -- 0317. The three that ship empty. A testimonial withdrawn is a
    -- delete, which is the change most worth delivering and the one
    -- `replica identity full` exists for.
    'landing_stats', 'landing_testimonials', 'landing_logos'
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
  --
  -- `platform_settings` was on this list until 0302 and is not any more.
  -- The reason is the same one that let 0124 publish `expense_claims`:
  -- Realtime asks row level security who may be sent a row, and 0298
  -- already narrows this table to one key for anybody who is not a
  -- platform admin. An admin receives what an admin could already
  -- select. That argument is only worth as much as the policy holding,
  -- so the policy is asserted below rather than assumed.
  foreach v_table in array array[
    'einvoice_credentials', 'org_ocr_credentials', 'org_ocr_settings',
    'payslips', 'payroll_runs', 'platform_invoices',
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

-- ---------------------------------------------------------------------
-- Publishing the platform's settings does not publish the platform's
-- settings
--
-- 0302 put `platform_settings` on the wire so that grouping the side
-- menu regroups it for everybody rather than for whoever reloads first.
-- That is only safe because Realtime asks row level security which rows
-- a subscriber may be sent, and 0298 narrowed this table to a single
-- key for anybody who is not a platform admin.
--
-- So this is the load-bearing assertion under that decision, and it is
-- deliberately behavioural rather than a reading of the policy text: a
-- policy can be rewritten a dozen ways that all still say
-- `is_platform_admin() or key = 'nav_grouping'`, and one way that does
-- not. What must stay true is that an ordinary member selecting this
-- table gets `nav_grouping` and nothing else — because whatever they can
-- select is what the socket will send them.
--
-- Run as `authenticated`. The connection is a superuser and a superuser
-- bypasses row level security entirely, which would make the whole
-- thing pass while proving nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Biasa Sdn Bhd');
  v_member uuid := pg_temp.another_user('member@biasa.test');
  v_role text;
  v_rows int;
  v_grouping int;
  v_secretish int;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_member, 'employee')
  on conflict do nothing;

  -- A key that is none of an ordinary member's business, standing in
  -- for whatever gets added to this table next. The check below is
  -- worth nothing without a row that ought to be refused.
  insert into public.platform_settings (key, value, description)
  values ('billing_provider',
          '{"account": "acct_live_should_not_travel"}',
          'Stand-in for a setting that is not everybody''s')
  on conflict (key) do update set value = excluded.value;

  perform pg_temp.sign_in_as(v_member);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_rows from public.platform_settings;
    select count(*) into v_grouping
      from public.platform_settings where key = 'nav_grouping';
    select count(*) into v_secretish
      from public.platform_settings where key = 'billing_provider';
  end;
  reset role;

  perform pg_temp.check_true(
    'the settings test ran under row level security',
    v_role = 'authenticated');

  -- The control first. A policy that hid every row would satisfy every
  -- refusal below while breaking the feature 0302 exists for.
  perform pg_temp.check_eq(
    'a member is sent the menu grouping switch', v_grouping::numeric, 1);
  perform pg_temp.check_eq(
    'and nothing else from the platform settings',
    v_secretish::numeric, 0);
  perform pg_temp.check_eq(
    'so one row is all that can reach them over the socket',
    v_rows::numeric, 1);
end $$;

-- ---------------------------------------------------------------------
-- The console's other tables are readable by everybody on purpose
--
-- The check further up — published tables have RLS on and at least one
-- policy — passes a policy of `using (true)`, and for these that is the
-- right policy: the module catalogue and the landing page are the same
-- for every company on the platform. Asserted anyway, because "public by
-- design" and "somebody forgot to write a policy" look identical in
-- `pg_policies`, and only one of them is a decision.
--
-- Each table gets a row written first. Counting what a member can see
-- without knowing there is anything to see would pass against a table
-- that is simply empty, which is the shape of assertion this file
-- exists to avoid.
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.another_user('reader@biasa.test');
  v_role text;
  v_modules int;
  v_sections int;
  v_links int;
begin
  insert into public.landing_sections (title, body, sort_order)
  values ('Kept in the open', 'Every company sees the same page.', 900);
  insert into public.landing_app_links (store_code, label, url, sort_order)
  values ('play', 'Android', 'https://example.test/android', 900);

  perform pg_temp.sign_in_as(v_user);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_modules from public.platform_modules;
    select count(*) into v_sections
      from public.landing_sections where sort_order = 900;
    select count(*) into v_links
      from public.landing_app_links where sort_order = 900;
  end;
  reset role;

  perform pg_temp.check_true(
    'the catalogue test ran under row level security',
    v_role = 'authenticated');

  -- The catalogue is seeded by 0018 and added to by every module since,
  -- so "more than nothing" is the honest assertion; naming a count here
  -- would break on the next module rather than on a policy change.
  perform pg_temp.check_true(
    'a signed-in member is sent the module catalogue', v_modules > 0);
  perform pg_temp.check_eq(
    'and the landing sections', v_sections::numeric, 1);
  perform pg_temp.check_eq(
    'and the store links', v_links::numeric, 1);
end $$;

rollback;
