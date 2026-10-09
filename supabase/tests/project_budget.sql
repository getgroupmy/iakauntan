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
--   * `0176`'s refusal one table over — a job does not close over
--     billable hours nobody invoiced, unless somebody says they are
--     being written off;
--   * and, since `0778`, the same refusal by the table's own door, for
--     a member who closes the job with an UPDATE instead.
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
    p_org, pg_temp.today(), 'manual'::app.journal_source,
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
    p_org, pg_temp.today(), 'manual'::app.journal_source,
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
    p_org, pg_temp.today(), 'manual'::app.journal_source,
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
    date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Klien Sdn Bhd', 'customer') returning id into v_cust;

  insert into public.projects
    (org_id, code, name, contact_id, budget_amount, start_date)
  values (v_org, 'JOB-1', 'Warehouse fit-out', v_cust, 50000,
          pg_temp.today() - 60)
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
  v_other uuid;
  v_org2  uuid;
  v_said  text;
  v_row   record;
  v_n     integer;
begin
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);
  insert into public.projects (org_id, code, name, budget_amount)
  values (v_org, 'JOB-1', 'Fit-out', 10000) returning id into v_proj;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-2', 'Nothing on it') returning id into v_clean;
  -- An hour on ANOTHER job, still to bill -- in another company, so it
  -- stays out of this one's lists: writing JOB-1 off is not a decision
  -- about it.
  perform pg_temp.allow_many_companies();
  v_org2 := pg_temp.test_org('Projek Jiran Sdn Bhd');
  insert into public.projects (org_id, code, name)
  values (v_org2, 'JOB-3', 'Still going') returning id into v_other;
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org2, v_other, auth.uid(), pg_temp.today() - 5, 'Survey', 60,
          250, 250, true, false);

  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), pg_temp.today() - 5, 'Site work', 480,
          250, 2000, true, false);
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), pg_temp.today() - 4, 'More site work',
          240, 250, 1000, true, false);
  -- Already invoiced, so not part of the question.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), pg_temp.today() - 3, 'Billed already',
          60, 250, 250, true, true);
  -- Never billable, so also not part of it.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_proj, auth.uid(), pg_temp.today() - 2, 'Internal', 60,
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
  perform pg_temp.check_true('and another job''s hour is still there to bill',
    (select is_billable from public.time_entries where project_id = v_other));
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
  perform pg_temp.check_refused('and reopening one that does not exist is said so too',
    format('select public.reopen_project(%L)', gen_random_uuid()),
    'No such project.', 'P0002');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- And by the table's own door  (`0778`)
--
-- `close_project`'s refusal, asked of an UPDATE straight on `projects`
-- by a member who may write but not post -- the road `projects_update`
-- leaves open. Before `0778` this closed a job holding RM3,000 of
-- unbilled time. What is not refused: a job whose only time is billed,
-- or never billable, or that has none of its own; editing a closed job;
-- editing an open one; reopening; and `close_project` writing the time
-- off, which empties the question before it closes.
-- ---------------------------------------------------------------------
create temporary table t_pc
  (held uuid, billed uuid, internal uuid, empty uuid, shut uuid);
grant select on t_pc to authenticated;

do $$
declare
  v_org      uuid := pg_temp.test_org('Pintu Projek Sdn Bhd');
  v_clerk    uuid;
  v_held     uuid;
  v_billed   uuid;
  v_internal uuid;
  v_empty    uuid;
  v_shut     uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-1', 'Fit-out') returning id into v_held;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-2', 'Invoiced already') returning id into v_billed;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-3', 'Internal only') returning id into v_internal;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-4', 'Nothing on it') returning id into v_empty;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-5', 'Written off') returning id into v_shut;

  -- JOB-1: two entries to bill, one billed, one never billable.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values
    (v_org, v_held, auth.uid(), pg_temp.today() - 5, 'Site work', 480,
     250, 2000, true, false),
    (v_org, v_held, auth.uid(), pg_temp.today() - 4, 'More site work', 240,
     250, 1000, true, false),
    (v_org, v_held, auth.uid(), pg_temp.today() - 3, 'Billed already', 60,
     250, 250, true, true),
    (v_org, v_held, auth.uid(), pg_temp.today() - 2, 'Internal', 60,
     0, 0, false, false),
  -- JOB-2: billed, all of it.
    (v_org, v_billed, auth.uid(), pg_temp.today() - 5, 'Invoiced', 60,
     250, 250, true, true),
  -- JOB-3: none of it was ever to be charged.
    (v_org, v_internal, auth.uid(), pg_temp.today() - 5, 'Training', 60,
     0, 0, false, false),
  -- JOB-5: one entry, written off below and then made billable again by
  -- hand, so a CLOSED job holds unbilled time.
    (v_org, v_shut, auth.uid(), pg_temp.today() - 5, 'Snagging', 120,
     250, 500, true, false);

  perform public.close_project(v_shut, true);
  -- Made billable again past `0783`, which would now refuse it: the
  -- point is a closed job already holding time, as one could before.
  alter table public.time_entries disable trigger time_not_onto_a_closed_project;
  update public.time_entries set is_billable = true
   where project_id = v_shut;
  alter table public.time_entries enable trigger time_not_onto_a_closed_project;

  v_clerk := pg_temp.another_user('kerani@pintuprojek.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'sales', 'active');
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('the clerk may write projects but not post',
    app.can_write(v_org) and not app.can_post(v_org));

  insert into t_pc values (v_held, v_billed, v_internal, v_empty, v_shut);
end $$;

set local role authenticated;

do $$
declare
  c     record;
  v_msg text;
begin
  select * into c from t_pc;

  begin
    update public.projects set is_active = false where id = c.held;
    v_msg := null;
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_eq('a job with time to bill is not closed by hand either',
    v_msg,
    'This project still has 3,000.00 of billable time nobody has '
    'invoiced, across 2 entries. Bill it, or close the project writing '
    'the time off, which says the decision was taken. Hours left on a '
    'closed job are hours nobody is looking at.');

  -- Each of these is not refused, and the checks after `reset role`
  -- say they took.
  update public.projects set is_active = false where id = c.billed;
  update public.projects set is_active = false where id = c.internal;
  update public.projects set is_active = false where id = c.empty;
  update public.projects set name = 'Fit-out, level 2', is_active = true
   where id = c.held;
  update public.projects set name = 'Written off, then not',
         is_active = false
   where id = c.shut;
  update public.projects set is_active = true where id = c.shut;

  -- Open again, with its one entry still to bill: one is enough.
  begin
    update public.projects set is_active = false where id = c.shut;
    v_msg := null;
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_eq('one entry to bill is enough to refuse',
    v_msg,
    'This project still has 500.00 of billable time nobody has '
    'invoiced, across 1 entries. Bill it, or close the project writing '
    'the time off, which says the decision was taken. Hours left on a '
    'closed job are hours nobody is looking at.');
end $$;

reset role;

do $$
declare c record;
begin
  select * into c from t_pc;
  perform pg_temp.check_true('the job with time to bill is still open',
    (select is_active from public.projects where id = c.held));
  perform pg_temp.check_eq('and its other edit took',
    (select name from public.projects where id = c.held), 'Fit-out, level 2');
  perform pg_temp.check_true('a job whose time is all billed closes by hand',
    not (select is_active from public.projects where id = c.billed));
  perform pg_temp.check_true('so does one whose time was never billable',
    not (select is_active from public.projects where id = c.internal));
  perform pg_temp.check_true(
    'and one with no time of its own, beside a job that has some',
    not (select is_active from public.projects where id = c.empty));
  perform pg_temp.check_eq(
    'a closed job holding time is edited, reopened, and not closed again',
    (select name || ' / ' || is_active::text from public.projects
      where id = c.shut),
    'Written off, then not / true');

  -- `close_project` writing the time off still closes: it marks the
  -- time non-billable before it asks the table.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform public.close_project(c.held, true);
  perform pg_temp.check_true('and close_project writing it off still closes it',
    not (select is_active from public.projects where id = c.held));
  perform pg_temp.check_eq(
    'the two to bill written off, beside the one never billable',
    (select count(*)::integer from public.time_entries
      where project_id = c.held and not is_billable and not is_billed), 3);
  perform pg_temp.check_eq('and none of the four deleted',
    (select count(*)::integer from public.time_entries
      where project_id = c.held), 4);
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A closed job takes no billable time  (`0783`)
--
-- The other half of `0778`: billable, uninvoiced time cannot ARRIVE on
-- a closed project by any change to the time entries -- logged, moved
-- onto it, made billable or un-billed again, raised. Non-billable time
-- and anything that lowers the figure are not refused.
-- ---------------------------------------------------------------------
create temporary table t_tc
  (shut uuid, open uuid, written uuid, billed uuid, moving uuid, legacy uuid,
   legacy_job uuid);
grant select on t_tc to authenticated;

do $$
declare
  v_org     uuid := pg_temp.test_org('Masa Tutup Sdn Bhd');
  v_clerk   uuid;
  v_shut    uuid;
  v_open    uuid;
  v_old     uuid;
  v_written uuid;
  v_billed  uuid;
  v_moving  uuid;
  v_legacy  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-C', 'Finished') returning id into v_shut;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-O', 'Still going') returning id into v_open;
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-L', 'Closed before 0783') returning id into v_old;

  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_shut, auth.uid(), pg_temp.today() - 9, 'Written off',
          60, 250, 250, true, false)
  returning id into v_written;
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_shut, auth.uid(), pg_temp.today() - 8, 'Invoiced',
          60, 250, 250, true, true)
  returning id into v_billed;
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_open, auth.uid(), pg_temp.today() - 7, 'On the open job',
          60, 250, 250, true, false)
  returning id into v_moving;
  perform public.close_project(v_shut, true);

  -- A job closed with time still to bill, as a database from before
  -- `0778` could hold one. Built past the two guards that would now
  -- refuse it, which is the point: what it holds is not added to here.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_old, auth.uid(), pg_temp.today() - 30, 'Left behind',
          120, 250, 500, true, false)
  returning id into v_legacy;
  alter table public.projects disable trigger projects_close_only_when_billed;
  update public.projects set is_active = false where id = v_old;
  alter table public.projects enable trigger projects_close_only_when_billed;

  v_clerk := pg_temp.another_user('kerani@masatutup.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'sales', 'active');
  perform pg_temp.sign_in_as(v_clerk);
  insert into t_tc values (v_shut, v_open, v_written, v_billed, v_moving,
                           v_legacy, v_old);
end $$;

set local role authenticated;

do $$
declare
  c     record;
  v_msg text;
  v_org uuid;
  v_n   integer := 0;
  v_try text;
begin
  select * into c from t_tc;
  select org_id into v_org from public.projects where id = c.shut;

  foreach v_try in array array[
    -- An hour logged.
    format('insert into public.time_entries (org_id, project_id, user_id, '
           'entry_date, description, minutes, hourly_rate, amount, '
           'is_billable, is_billed) values (%L, %L, auth.uid(), %L, '
           '''Late hours'', 120, 250, 500, true, false)',
           v_org, c.shut, pg_temp.today()),
    -- An hour at no rate yet: still one somebody should bill.
    format('insert into public.time_entries (org_id, project_id, user_id, '
           'entry_date, description, minutes, hourly_rate, amount, '
           'is_billable, is_billed) values (%L, %L, auth.uid(), %L, '
           '''Unpriced'', 60, 0, 0, true, false)',
           v_org, c.shut, pg_temp.today()),
    -- The written-off hour made billable again.
    format('update public.time_entries set is_billable = true where id = %L',
           c.written),
    -- The invoiced hour un-billed.
    format('update public.time_entries set is_billed = false where id = %L',
           c.billed),
    -- An hour moved from the open job.
    format('update public.time_entries set project_id = %L where id = %L',
           c.shut, c.moving),
    -- The left-behind hour on the old closed job, raised.
    format('update public.time_entries set minutes = 180, amount = 750 '
           'where id = %L', c.legacy)]
  loop
    begin
      execute v_try;
      v_msg := null;
    exception when check_violation then
      get stacked diagnostics v_msg = message_text;
    end;
    v_n := v_n + 1;
    perform pg_temp.check_eq(
      format('billable time does not reach a closed job, road %s', v_n),
      v_msg,
      format('Project %s is closed. Reopen it before logging billable '
             'time to it.',
             case when v_n = 6 then 'JOB-L' else 'JOB-C' end));
  end loop;

  -- Not refused: non-billable time, the left-behind hour edited without
  -- raising it, and lowered, and the hour on the open job edited.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     hourly_rate, amount, is_billable, is_billed)
  values (v_org, c.shut, auth.uid(), pg_temp.today(), 'Handover notes',
          30, 0, 0, false, false);
  update public.time_entries set description = 'Left behind, chased'
   where id = c.legacy;
  update public.time_entries set minutes = 60, amount = 250
   where id = c.legacy;
  update public.time_entries set description = 'Open job, renamed'
   where id = c.moving;
  -- An invoiced hour on the closed job is still somebody's to annotate,
  -- and the hour left behind is still somebody's to invoice.
  update public.time_entries set description = 'Invoiced, on INV-9'
   where id = c.billed;
  update public.time_entries set is_billed = true where id = c.legacy;
end $$;

reset role;

do $$
declare c record;
begin
  select * into c from t_tc;
  perform pg_temp.check_eq('the closed job holds nothing to bill',
    (select count(*)::integer from public.time_entries
      where project_id = c.shut and is_billable and not is_billed), 0);
  perform pg_temp.check_eq('but has the non-billable hour logged',
    (select count(*)::integer from public.time_entries
      where project_id = c.shut and not is_billable
        and description = 'Handover notes'), 1);
  perform pg_temp.check_eq('the left-behind hour was edited, lowered and invoiced',
    (select description || ' ' || amount || ' ' || is_billed
       from public.time_entries where id = c.legacy),
    'Left behind, chased 250.00 true');
  perform pg_temp.check_eq('and the invoiced one annotated',
    (select description from public.time_entries where id = c.billed),
    'Invoiced, on INV-9');
  perform pg_temp.check_eq('and the open job''s hour stayed where it was',
    (select project_id from public.time_entries where id = c.moving), c.open);

  -- Reopened, the same hour is taken.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform public.reopen_project(c.shut);
  update public.time_entries set project_id = c.shut where id = c.moving;
  perform pg_temp.check_eq('reopened, the job takes its time again',
    (select count(*)::integer from public.time_entries
      where project_id = c.shut and is_billable and not is_billed), 1);
  perform pg_temp.sign_out();
end $$;

rollback;
