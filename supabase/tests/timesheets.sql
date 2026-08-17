-- =====================================================================
-- iAkauntan :: timesheets
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/timesheets.sql
--
-- Selling hours has three ways to lose money, and this asserts all
-- three.
--
--   1. **The wrong rate.** A senior billed at a junior's rate for six
--      months is invisible on a timesheet — every entry looks right.
--      The resolution order is one function and it is asserted here.
--
--   2. **Time that is never billed.** Until `0164` nothing in this
--      database set `time_entries.is_billed` or `invoice_id`; the
--      columns existed and only a report read them. A firm could record
--      a year of chargeable time and had no way to invoice a minute of
--      it.
--
--   3. **Time billed twice.** The opposite failure, and the more
--      expensive one, because the client is the one who finds it.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid; v_owner uuid; v_other uuid;
  v_client uuid; v_proj uuid; v_proj2 uuid; v_matter uuid;
  v_inv uuid; v_total numeric; v_billed integer; v_lines integer;
  v_hours numeric; v_util numeric; v_unbilled numeric; v_billed_amt numeric;
begin
  v_org := pg_temp.test_org('Probe Consulting');
  v_owner := pg_temp.test_user();

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'timesheets', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'A client that buys hours', 'customer')
  returning id into v_client;
  insert into public.projects (org_id, code, name, contact_id)
  values (v_org, 'P1', 'Systems review', v_client) returning id into v_proj;

  -- ------------------------------------------------------------------
  -- 1. Which rate applies
  -- ------------------------------------------------------------------
  insert into public.billing_rates
    (org_id, user_id, effective_from, hourly_rate)
  values (v_org, v_owner, date '2026-01-01', 300);
  insert into public.billing_rates
    (org_id, user_id, project_id, effective_from, hourly_rate)
  values (v_org, v_owner, v_proj, date '2026-01-01', 450);

  perform pg_temp.check_eq(
    'a project rate beats the person''s default',
    app.billing_rate_for(v_org, v_owner, v_proj, null, date '2026-02-01'),
    450.00);
  perform pg_temp.check_eq(
    'and off that project the default is what applies',
    app.billing_rate_for(v_org, v_owner, null, null, date '2026-02-01'),
    300.00);

  -- A rate resolved as of the entry's date, not today's. Backdating a
  -- rise must not reprice work already done at the old one.
  insert into public.billing_rates
    (org_id, user_id, effective_from, hourly_rate)
  values (v_org, v_owner, date '2026-07-01', 350);
  perform pg_temp.check_eq(
    'a later rise does not reach back',
    app.billing_rate_for(v_org, v_owner, null, null, date '2026-02-01'),
    300.00);
  perform pg_temp.check_eq(
    'and does apply after it takes effect',
    app.billing_rate_for(v_org, v_owner, null, null, date '2026-08-01'),
    350.00);

  -- ------------------------------------------------------------------
  -- Recording time does not require knowing the rate
  -- ------------------------------------------------------------------
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     is_billable)
  values (v_org, v_proj, v_owner, date '2026-02-10', 'Review', 90, true);
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     is_billable)
  values (v_org, v_proj, v_owner, date '2026-02-11', 'More review', 30, true);
  insert into public.time_entries
    (org_id, user_id, entry_date, description, minutes, is_billable)
  values (v_org, v_owner, date '2026-02-12', 'Internal admin', 60, false);

  -- 90 minutes at RM450 an hour. The trigger that fills the rate is
  -- named `apply_billing_rate` so it sorts before `calc_amount`, which
  -- multiplies; the other way round every entry would come out at zero.
  select amount into v_hours from public.time_entries
   where project_id = v_proj and minutes = 90;
  perform pg_temp.check_eq(
    'ninety minutes at the project rate', v_hours, 675.00);

  -- ------------------------------------------------------------------
  -- 2. Billing it — which nothing could do before
  -- ------------------------------------------------------------------
  v_inv := public.bill_project_time(
    v_proj, date '2026-02-01', date '2026-02-28');

  select total_amount into v_total
    from public.sales_documents where id = v_inv;
  -- Two hours at RM450.
  perform pg_temp.check_eq('the invoice is the hours', v_total, 900.00);

  select count(*) into v_billed from public.time_entries
   where invoice_id = v_inv and is_billed;
  perform pg_temp.check_eq(
    'both billable entries are marked and linked', v_billed, 2);

  -- The non-billable hour is not on it, and is not marked.
  select count(*) into v_billed from public.time_entries
   where org_id = v_org and not is_billable and is_billed;
  perform pg_temp.check_eq(
    'non-billable time is not swept in', v_billed, 0);

  -- One line per person rather than per entry, so a client reading it
  -- sees who and how many hours rather than a diary.
  select count(*) into v_lines
    from public.sales_document_lines where document_id = v_inv;
  perform pg_temp.check_eq('one line per fee earner', v_lines, 1);

  -- ------------------------------------------------------------------
  -- 3. And not twice
  -- ------------------------------------------------------------------
  begin
    perform public.bill_project_time(
      v_proj, date '2026-02-01', date '2026-02-28');
    raise exception 'the same time was billed a second time';
  exception when no_data_found then
    raise notice 'ok   there is nothing left to bill the second time';
  end;

  -- The positive control on that refusal: new time on the same project
  -- still bills. Without this, a function that always refused would pass.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     is_billable)
  values (v_org, v_proj, v_owner, date '2026-02-20', 'Follow-up', 60, true);
  v_inv := public.bill_project_time(
    v_proj, date '2026-02-01', date '2026-02-28');
  select total_amount into v_total
    from public.sales_documents where id = v_inv;
  perform pg_temp.check_eq(
    'but time recorded since does', v_total, 450.00);

  -- ------------------------------------------------------------------
  -- What the report says
  -- ------------------------------------------------------------------
  select billable_hours, utilisation_percent, billed_amount, unbilled_amount
    into v_hours, v_util, v_billed_amt, v_unbilled
    from public.report_timesheet(v_org, date '2026-02-01', date '2026-02-28');

  perform pg_temp.check_eq('three billable hours', v_hours, 3.00);
  -- 180 billable minutes of 240 recorded.
  perform pg_temp.check_eq('utilisation', v_util, 75.0);
  perform pg_temp.check_eq('all of it billed', v_billed_amt, 1350.00);
  perform pg_temp.check_eq('none of it outstanding', v_unbilled, 0);

  -- ------------------------------------------------------------------
  -- The rules that stop a timesheet becoming nonsense
  -- ------------------------------------------------------------------
  begin
    insert into public.time_entries
      (org_id, user_id, entry_date, description, minutes, is_billable)
    values (v_org, v_owner, date '2026-03-01', 'Chargeable to nobody', 60,
            true);
    raise exception 'billable time with nothing to bill it to was accepted';
  exception when check_violation then
    raise notice 'ok   billable time needs a matter or a project';
  end;

  -- Non-billable time may float free, which is the only way utilisation
  -- means anything.
  insert into public.time_entries
    (org_id, user_id, entry_date, description, minutes, is_billable)
  values (v_org, v_owner, date '2026-03-01', 'Training', 120, false);
  raise notice 'ok   and non-billable time may float free';

  insert into public.projects (org_id, code, name, contact_id)
  values (v_org, 'P2', 'Another job', v_client) returning id into v_proj2;
  -- A matter of this company's own, so the assertion below is about the
  -- rule and not about whether a fixture happened to leave one lying
  -- around.
  insert into public.matters (org_id, matter_no, name, client_id)
  values (v_org, 'M-001', 'A matter', v_client) returning id into v_matter;
  begin
    insert into public.time_entries
      (org_id, project_id, matter_id, user_id, entry_date, description,
       minutes, is_billable)
    values (v_org, v_proj2, v_matter, v_owner, date '2026-03-02',
            'Both at once', 60, true);
    raise exception 'an hour was booked to a project and a matter at once';
  exception when check_violation then
    raise notice 'ok   an hour belongs to one engagement';
  end;

  -- A project with no client cannot be invoiced, and says so rather than
  -- raising an invoice addressed to nobody.
  insert into public.projects (org_id, code, name)
  values (v_org, 'P3', 'Internal R&D') returning id into v_proj2;
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, minutes,
     is_billable)
  values (v_org, v_proj2, v_owner, date '2026-02-15', 'Research', 60, true);
  begin
    perform public.bill_project_time(
      v_proj2, date '2026-02-01', date '2026-02-28');
    raise exception 'an invoice was raised for a project with no client';
  exception when not_null_violation then
    raise notice 'ok   a project with no client cannot be invoiced';
  end;

  raise notice 'timesheets: 3 billable hours billed at two rates, 75%% utilised';
end $$;

rollback;
