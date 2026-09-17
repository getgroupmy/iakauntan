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
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-001', 'A matter', v_client, v_owner)
  returning id into v_matter;
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

  -- ------------------------------------------------------------------
  -- 4. The tax on the hours
  -- ------------------------------------------------------------------
  -- `0437`. `app.bill_time_internal` wrote `tax_rate => 0` and no tax
  -- code on every line of every fee note, for every organization. So a
  -- firm registered for service tax billed its hours and declared
  -- nothing on them -- Group G of the First Schedule to the Service Tax
  -- Regulations 2018 makes legal, accounting, consultancy, management
  -- and IT services taxable, and the shortfall is the registrant's to
  -- pay whether or not they collected it.
  --
  -- Nothing caught it because no registered tenant had ever billed
  -- time: `0436` was the first, and the identity it broke in
  -- `demo_rebuild.sql` was about the revenue account, not the tax.
  declare
    v_reg uuid; v_reg_client uuid; v_reg_proj uuid; v_reg_user uuid;
    v_note uuid; v_early uuid;
  begin
    v_reg := pg_temp.test_org('Probe Consulting (Registered)');
    v_reg_user := v_owner;
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
    values (v_reg, 'timesheets', true, now())
    on conflict (org_id, module_code) do update set is_enabled = true;
    perform public.create_fiscal_year(v_reg, date '2026-01-01');

    insert into public.tax_codes
      (org_id, code, name, tax_type_code, rate,
       sales_tax_account_id, purchase_tax_account_id)
    values (v_reg, 'ST8', 'Service Tax 8%', '02', 8,
            (select id from public.accounts where org_id = v_reg and code = '2130'),
            (select id from public.accounts where org_id = v_reg and code = '1410'));

    -- Registered from March. Everything before that is out of scope,
    -- which is the second half of what this section is for.
    perform public.set_sst_registration(
      v_reg, true, date '2026-03-01', 'W10-1808-31000999', 'ST8');

    insert into public.contacts (org_id, code, name, contact_type)
    values (v_reg, 'CL1', 'A client of a registered firm', 'customer')
    returning id into v_reg_client;
    insert into public.projects (org_id, code, name, contact_id)
    values (v_reg, 'P1', 'Systems review', v_reg_client)
    returning id into v_reg_proj;
    insert into public.billing_rates
      (org_id, user_id, effective_from, hourly_rate)
    values (v_reg, v_reg_user, date '2026-01-01', 500);

    -- Work done in April, after registration.
    insert into public.time_entries
      (org_id, project_id, user_id, entry_date, description, minutes,
       is_billable)
    values (v_reg, v_reg_proj, v_reg_user, date '2026-04-06',
            'Review and report', 120, true);
    v_note := public.bill_project_time(
      v_reg_proj, date '2026-04-01', date '2026-04-30');

    perform pg_temp.check_eq(
      'a registered firm charges service tax on the hours it bills',
      (select tax_amount from public.sales_documents where id = v_note),
      80.00);
    perform pg_temp.check_eq(
      'and the fee note totals the hours plus that tax',
      (select total_amount from public.sales_documents where id = v_note),
      1080.00);

    -- The rate has to be on the line, not merely the code: totals are
    -- recalculated from `sales_document_lines.tax_rate`, so a line
    -- naming ST8 without its 8 produces a fee note with a tax code on
    -- it and no tax in it.
    perform pg_temp.check_eq(
      'and the line carries both the code and its rate',
      (select count(*) from public.sales_document_lines
        where document_id = v_note
          and (tax_code_id is null or coalesce(tax_rate, 0) = 0)), 0);

    -- Work done in February, before the firm registered. Measured
    -- rather than assumed: a posting guard already refuses a document
    -- dated before registration that carries tax, so the failure this
    -- half prevents is not a wrong number -- it is a fee note that
    -- CANNOT BE RAISED AT ALL. Take the date test out of
    -- `app.default_sales_tax` and `bill_project_time` raises "This
    -- document is dated 2026-02-28, before SST registration took effect
    -- on 2026-03-01", and the firm has no way to bill work it did
    -- before it registered.
    insert into public.time_entries
      (org_id, project_id, user_id, entry_date, description, minutes,
       is_billable)
    values (v_reg, v_reg_proj, v_reg_user, date '2026-02-10',
            'Scoping, before we registered', 60, true);
    v_early := public.bill_project_time(
      v_reg_proj, date '2026-02-01', date '2026-02-28');

    perform pg_temp.check_eq(
      'and work billed before the firm registered carries none',
      (select tax_amount from public.sales_documents where id = v_early), 0);

    -- The control. Probe Consulting above is not registered, and its
    -- fee notes must still come out at nothing -- otherwise the fix
    -- would be charging tax nobody may collect.
    perform pg_temp.check_eq(
      'and an unregistered firm charges nothing on its hours',
      (select coalesce(sum(tax_amount), 0) from public.sales_documents
        where org_id = v_org and doc_type = 'invoice'), 0);
    perform pg_temp.check_true(
      'on fee notes it actually raised',
      (select count(*) from public.sales_documents
        where org_id = v_org and doc_type = 'invoice') > 0);
  end;

  -- ------------------------------------------------------------------
  -- 5. When the fee note falls due
  -- ------------------------------------------------------------------
  -- `0439`. `app.bill_time_internal` set `due_date := coalesce(p_due,
  -- p_to)` and never touched `payment_term_id`, so a fee note fell due
  -- on the day it was raised whatever the client had agreed. Measured
  -- on a client set to NET30: doc_date and due_date both the same day,
  -- and `report_ar_aging` -- which buckets on `coalesce(due_date,
  -- doc_date)` -- had them a month in arrears for a month they were
  -- promised.
  declare
    v_terms uuid; v_soon uuid; v_late uuid; v_p3 uuid; v_note uuid;
  begin
    -- `pg_temp.test_org` builds a bare company; the standard terms come
    -- from `create_organization`'s seed, which it does not run. Written
    -- here so the section tests the billing, not the bootstrap.
    insert into public.payment_terms (org_id, code, name, days, term_type)
    values (v_org, 'NET30', '30 Days', 30, 'net')
    on conflict (org_id, code) do update set days = 30
    returning id into v_terms;
    perform pg_temp.check_true('the standard terms are on file',
      v_terms is not null);

    update public.contacts set payment_term_id = v_terms where id = v_client;

    insert into public.projects (org_id, code, name, contact_id)
    values (v_org, 'P-DUE', 'A job for a client with terms', v_client)
    returning id into v_p3;
    insert into public.time_entries
      (org_id, project_id, user_id, entry_date, description, minutes,
       is_billable)
    values (v_org, v_p3, v_owner, date '2026-03-10', 'Work', 60, true);

    v_note := public.bill_project_time(
      v_p3, date '2026-03-01', date '2026-03-31');

    perform pg_temp.check_eq(
      'a fee note falls due on the terms the client agreed',
      (select due_date::text from public.sales_documents where id = v_note),
      '2026-04-30');
    perform pg_temp.check_eq(
      'and it is not due the day it was raised',
      (select doc_date::text from public.sales_documents where id = v_note),
      '2026-03-31');

    -- The document records WHICH terms, not only the date they produce.
    -- `settlement_discount_of` reads `payment_term_id` off the
    -- document, so a fee note with the right date and no term still
    -- cannot say whether an early-payment discount applies.
    perform pg_temp.check_eq(
      'and records the terms it was raised on',
      (select payment_term_id from public.sales_documents where id = v_note),
      v_terms);

    -- A date somebody negotiated still wins. The standard terms must
    -- not overwrite an agreement the software knows nothing about --
    -- which is the rule `app.document_due_date_guard` states and this
    -- has to keep.
    insert into public.time_entries
      (org_id, project_id, user_id, entry_date, description, minutes,
       is_billable)
    values (v_org, v_p3, v_owner, date '2026-04-10', 'More work', 60, true);
    v_late := public.bill_project_time(
      v_p3, date '2026-04-01', date '2026-04-30', date '2026-05-15');
    perform pg_temp.check_eq(
      'and a date the biller typed beats the standard terms',
      (select due_date::text from public.sales_documents where id = v_late),
      '2026-05-15');

    -- And a client with nothing on file falls back to where it was:
    -- due on the day, rather than a null the ageing would have to
    -- guess at.
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, 'CL-NOTERMS', 'A client with no terms agreed', 'customer')
    returning id into v_soon;
    insert into public.projects (org_id, code, name, contact_id)
    values (v_org, 'P-NOTERMS', 'A job for them', v_soon) returning id into v_p3;
    insert into public.time_entries
      (org_id, project_id, user_id, entry_date, description, minutes,
       is_billable)
    values (v_org, v_p3, v_owner, date '2026-05-10', 'Work', 60, true);
    v_note := public.bill_project_time(
      v_p3, date '2026-05-01', date '2026-05-31');
    perform pg_temp.check_eq(
      'and with no terms on file it falls due on the day, not on null',
      (select due_date::text from public.sales_documents where id = v_note),
      '2026-05-31');
  end;

  raise notice 'timesheets: 3 billable hours billed at two rates, 75%% utilised';
end $$;

rollback;
