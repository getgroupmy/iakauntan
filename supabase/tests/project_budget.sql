-- =====================================================================
-- iAkauntan :: the project budget, and the job closed with time on it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/project_budget.sql
--
-- `projects.budget_amount` has been a column since `0088` and the word
-- appears nowhere else in the repository. Nothing writes any column of
-- `projects` — the table has no front door at all — so the budget was
-- the visible end of that.
--
-- What is asserted:
--
--   * the two rules a project row has to obey;
--   * cost read from the ledger, not from the documents, so a journal
--     posted by hand counts the same as a bill line;
--   * unbilled time counted separately and added to neither side;
--   * and `0176`'s refusal one table over — a job does not close over
--     billable hours nobody invoiced, unless somebody says they are
--     being written off.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A posted journal touching one expense account, tagged to a project.
-- The shortest way to put a real cost in the ledger, and deliberately
-- through `create_gl_entry` rather than through a bill: the report
-- reads the ledger, and a hand-posted journal has to count the same.
--
-- The project code goes on the profit-and-loss line only. Tagging the
-- bank side as well would count the same job twice, which is the
-- mistake the report would then be built to match.
create or replace function pg_temp.pb_post(
  p_org uuid, p_code text, p_account text, p_debit numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  select public.create_gl_entry(
    p_org, current_date, 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', (select id from public.accounts
                        where org_id = p_org and code = p_account),
        'debit', p_debit, 'credit', 0, 'project_code', p_code),
      jsonb_build_object(
        'account_id', (select id from public.accounts
                        where org_id = p_org and code = '1110'),
        'debit', 0, 'credit', p_debit)),
    'Job cost') into v_entry;
end $$;

-- The same, handing back the entry so a fixture can take it out of
-- `posted` afterwards.
create or replace function pg_temp.pb_post_returning(
  p_org uuid, p_code text, p_account text, p_debit numeric)
returns uuid language plpgsql as $$
declare v_entry uuid;
begin
  select public.create_gl_entry(
    p_org, current_date, 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', (select id from public.accounts
                        where org_id = p_org and code = p_account),
        'debit', p_debit, 'credit', 0, 'project_code', p_code),
      jsonb_build_object(
        'account_id', (select id from public.accounts
                        where org_id = p_org and code = '1110'),
        'debit', 0, 'credit', p_debit)),
    'Unposted job cost') into v_entry;
  return v_entry;
end $$;

-- The other side: revenue on the job. Same shape, and the code goes on
-- the revenue line for the same reason.
create or replace function pg_temp.pb_revenue(
  p_org uuid, p_code text, p_account text, p_credit numeric)
returns void language plpgsql as $$
declare v_entry uuid;
begin
  select public.create_gl_entry(
    p_org, current_date, 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', (select id from public.accounts
                        where org_id = p_org and code = '1110'),
        'debit', p_credit, 'credit', 0),
      jsonb_build_object(
        'account_id', (select id from public.accounts
                        where org_id = p_org and code = p_account),
        'debit', 0, 'credit', p_credit, 'project_code', p_code)),
    'Job revenue') into v_entry;
end $$;

-- ---------------------------------------------------------------------
-- The rules a project row obeys
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Projek Sdn Bhd');
  v_said text;
begin
  begin
    insert into public.projects (org_id, code, name, budget_amount)
    values (v_org, 'P-BAD', 'Negative budget', -1);
    raise exception 'FAIL: a project was budgeted at less than nothing';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a budget is not negative',
    v_said like '%projects_budget_ck%');

  begin
    insert into public.projects
      (org_id, code, name, start_date, end_date)
    values (v_org, 'P-BAD2', 'Backwards', date '2026-06-01',
            date '2026-01-01');
    raise exception 'FAIL: a project ended before it started';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a job does not end before it starts',
    v_said like '%projects_dates_ck%');

  -- A project with no budget and no dates is ordinary and is allowed.
  insert into public.projects (org_id, code, name)
  values (v_org, 'P-OK', 'No budget yet');
  perform pg_temp.check_eq('a project without a budget is still a project',
    (select count(*)::integer from public.projects
      where org_id = v_org and code = 'P-OK'), 1);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The budget, beside what has been spent against it
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Kos Projek Sdn Bhd');
  v_cust uuid;
  v_proj uuid;
  v_bare uuid;
  v_draft uuid;
  v_row  record;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Klien Sdn Bhd', 'customer') returning id into v_cust;

  insert into public.projects
    (org_id, code, name, contact_id, budget_amount, start_date)
  values (v_org, 'JOB-1', 'Warehouse fit-out', v_cust, 50000,
          current_date - 60)
  returning id into v_proj;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-2', 'No budget on this one') returning id into v_bare;

  -- Cost from the ledger: a hand-posted journal counts exactly as a
  -- bill line would, which is the point of reading the ledger.
  perform pg_temp.pb_post(v_org, 'JOB-1', '5100', 12000);
  perform pg_temp.pb_post(v_org, 'JOB-1', '6240', 3000);
  -- Revenue on the same job.
  perform pg_temp.pb_revenue(v_org, 'JOB-1', '4100', 20000);
  -- And a cost on the other job, to prove the grouping is by project.
  perform pg_temp.pb_post(v_org, 'JOB-2', '5100', 800);

  -- A journal that was never posted. A draft may never be posted at
  -- all, so counting it would show a job over budget on a cost the
  -- company has not incurred — and somebody would go and explain an
  -- overrun that is not there.
  --
  -- Held in a variable first, deliberately: the same call written into
  -- the `where` clause is evaluated once per row scanned, and posted
  -- the journal four times before this line was fixed.
  v_draft := pg_temp.pb_post_returning(v_org, 'JOB-1', '5100', 9999);
  update public.gl_entries set status = 'draft' where id = v_draft;

  select * into v_row from public.report_project_budget(v_org)
   where code = 'JOB-1';
  perform pg_temp.check_eq('the budget is what was set',
    v_row.budget_amount, 50000);
  perform pg_temp.check_eq('cost is everything the ledger has against it',
    v_row.cost_to_date, 15000);
  perform pg_temp.check_true('and nothing it has not posted',
    v_row.cost_to_date < 20000);
  perform pg_temp.check_eq('revenue is the other side',
    v_row.revenue_to_date, 20000);
  perform pg_temp.check_eq('the variance is what is left',
    v_row.variance, 35000);
  perform pg_temp.check_eq('and how much of it has gone',
    v_row.percent_spent, 30.0);
  perform pg_temp.check_eq('the customer is named', v_row.customer,
    'Klien Sdn Bhd');

  -- The other job's cost is the other job's.
  select * into v_row from public.report_project_budget(v_org)
   where code = 'JOB-2';
  perform pg_temp.check_eq('costs are grouped by project',
    v_row.cost_to_date, 800);
  -- No budget is not a budget of nothing, and a job with none is not
  -- reported as exactly on budget or as infinitely overspent.
  perform pg_temp.check_true('a job with no budget has no variance',
    v_row.variance is null);
  perform pg_temp.check_true('and no percentage',
    v_row.percent_spent is null);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Closing a job with hours still on it
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tutup Projek Sdn Bhd');
  v_proj  uuid;
  v_clean uuid;
  v_said  text;
  v_row   record;
  v_n     integer;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', current_date)::date);
  insert into public.projects (org_id, code, name, budget_amount)
  values (v_org, 'JOB-1', 'Fit-out', 10000) returning id into v_proj;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-2', 'Nothing on it') returning id into v_clean;

  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), current_date - 5, 'Site work', 480,
          250, 2000, true, false);
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), current_date - 4, 'More site work',
          240, 250, 1000, true, false);
  -- Already invoiced, so not part of the question.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), current_date - 3, 'Billed already',
          60, 250, 250, true, true);
  -- Never billable, so also not part of it.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), current_date - 2, 'Internal', 60,
          0, 0, false, false);

  select * into v_row from public.report_project_budget(v_org)
   where code = 'JOB-1';
  perform pg_temp.check_eq('unbilled time is counted',
    v_row.unbilled_time, 3000);
  -- Neither cost nor revenue: it is revenue not yet raised, and adding
  -- it to either would flatter one of them.
  perform pg_temp.check_eq('and is not counted as cost',
    v_row.cost_to_date, 0);
  perform pg_temp.check_eq('nor as revenue', v_row.revenue_to_date, 0);

  begin
    perform public.close_project(v_proj);
    raise exception 'FAIL: a project closed over uninvoiced billable time';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the hours are named',
    v_said like '%3,000.00 of billable time%');
  perform pg_temp.check_true('and so is how many entries',
    v_said like '%across 2 entries%');
  perform pg_temp.check_true('the project is still open',
    (select is_active from public.projects where id = v_proj));

  -- A job with nothing outstanding closes without argument.
  perform public.close_project(v_clean);
  perform pg_temp.check_true('a job with nothing on it closes',
    not (select is_active from public.projects where id = v_clean));

  -- Writing it off is a decision, and it is recorded as one.
  perform public.close_project(v_proj, true);
  perform pg_temp.check_true('and one written off closes',
    not (select is_active from public.projects where id = v_proj));
  select count(*)::integer into v_n from public.time_entries
   where project_id = v_proj and is_billable and not is_billed;
  perform pg_temp.check_eq('with nothing left outstanding on it', v_n, 0);
  -- The hours were worked. Deleting them would take them out of the
  -- utilisation report, which counts what people did rather than what
  -- was charged.
  select count(*)::integer into v_n from public.time_entries
   where project_id = v_proj;
  perform pg_temp.check_eq('and the hours still recorded', v_n, 4);
  perform pg_temp.check_eq('the invoiced entry is untouched',
    (select count(*)::integer from public.time_entries
      where project_id = v_proj and is_billed and is_billable), 1);

  -- Closing it twice is not closing it.
  begin
    perform public.close_project(v_proj);
    raise exception 'FAIL: a closed project was closed again';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('already closed',
    v_said like '%already closed%');

  -- A closed job is out of the list unless it is asked for.
  select count(*)::integer into v_n from public.report_project_budget(v_org);
  perform pg_temp.check_eq('closed jobs are not in the open list', v_n, 0);
  select count(*)::integer into v_n
    from public.report_project_budget(v_org, true);
  perform pg_temp.check_eq('and are, when asked for', v_n, 2);

  -- Reopening does not undo the write-off: that was a decision.
  perform public.reopen_project(v_proj);
  perform pg_temp.check_true('a job can be reopened',
    (select is_active from public.projects where id = v_proj));
  select count(*)::integer into v_n from public.time_entries
   where project_id = v_proj and is_billable and not is_billed;
  perform pg_temp.check_eq(
    'and the written-off hours stay written off', v_n, 0);

  begin
    perform public.reopen_project(v_proj);
    raise exception 'FAIL: an open project was reopened';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('already open', v_said like '%already open%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Siapa Boleh Projek Sdn Bhd');
  v_proj uuid;
  v_out  uuid := pg_temp.another_user('outsider@pb.test');
  v_said text;
begin
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-1', 'Fit-out') returning id into v_proj;

  perform pg_temp.sign_in_as(v_out);
  begin
    perform count(*) from public.report_project_budget(v_org);
    raise exception 'FAIL: an outsider read the job costing';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not your company',
    v_said like '%Not your company%');

  begin
    perform public.close_project(v_proj);
    raise exception 'FAIL: an outsider closed a project';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not permitted to close',
    v_said like '%not permitted to close a project%');

  begin
    perform public.reopen_project(v_proj);
    raise exception 'FAIL: an outsider reopened a project';
  exception when sqlstate '42501' or sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor to reopen',
    v_said like '%not permitted to reopen a project%');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  begin
    perform public.close_project('00000000-0000-0000-0000-000000000000');
    raise exception 'FAIL: a project that does not exist was closed';
  exception when sqlstate 'P0002' or sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('no such project, said as such',
    v_said like '%No such project%');

  perform pg_temp.sign_out();
end $$;

rollback;
