-- =====================================================================
-- iAkauntan :: property management
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/property.sql
--
-- The three statutory rules this module exists to get right, and the
-- separation between the two halves of it.
--
--   1. The Charges are levied in proportion to allocated share units.
--      Not per parcel, not per square foot. Under the Strata Management
--      Act 2013 this is the rule a management corporation is audited
--      against, and the failure mode is not an error message — it is
--      every owner in the block paying the wrong amount, quietly, for
--      years.
--
--   2. The contribution to the sinking fund is at least ten per cent of
--      the Charges (SMA 2013 s.25(3) for a JMB, s.51(2) for an MC).
--
--   3. The late payment charge on arrears is capped at ten per cent per
--      annum and computed on a daily basis — the ceiling in the Third
--      Schedule of the Strata Management (Maintenance and Management)
--      Regulations 2015.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A scheme, priced the way an AGM prices one
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_site   uuid;
  v_scheme uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_u1 uuid; v_u2 uuid; v_u3 uuid;
  v_run uuid;
  v_maint1 numeric; v_maint2 numeric; v_maint3 numeric;
  v_sink1 numeric;
  v_parcels integer; v_total_maint numeric; v_total_sink numeric;
  v_invoiced numeric;
  v_interest numeric; v_arrears numeric;
  v_lines integer;
begin
  -- Strata only. The block below proves that a company holding strata
  -- is refused the non-strata rent engine, which is only a test if the
  -- fixture actually withholds the other module.
  v_org := pg_temp.test_org('Probe Management Corporation',
                            array['property_strata']);

  -- The module has to be bought. Every function in it refuses without
  -- the entitlement, so the fixture buys it — and `property_nonstrata`
  -- is deliberately *not* bought, which is what the last section here
  -- turns into an assertion.
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_strata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  -- A fiscal year, or nothing can post.
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'PR1', 'Probe Residency', 'strata') returning id into v_site;

  insert into public.strata_schemes
    (org_id, site_id, stage, total_share_units)
  values (v_org, v_site, 'mc', 600) returning id into v_scheme;

  -- 35 sen per share unit per month, and the statutory floor on the
  -- sinking fund.
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (v_org, v_scheme, date '2026-01-01', 0.35, 10, 10);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWN1', 'Owner of A-1-1', 'customer') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWN2', 'Owner of A-1-2', 'customer') returning id into v_c2;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWN3', 'Owner of A-2-1', 'customer') returning id into v_c3;

  -- 300, 100 and 200 share units. The first two are in a 3:1 ratio on
  -- purpose: whatever the rate is, the charges must come out in that
  -- same ratio or they are not proportional to share units.
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'A-1-1', 'parcel', 300, v_c1) returning id into v_u1;
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'A-1-2', 'parcel', 100, v_c2) returning id into v_u2;
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'A-2-1', 'parcel', 200, v_c3) returning id into v_u3;

  -- ------------------------------------------------------------------
  -- 1. Proportional to share units
  -- ------------------------------------------------------------------
  v_run := public.raise_strata_charges(
    v_scheme, date '2026-01-01', date '2026-03-31', date '2026-01-15');

  select maintenance_amount, sinking_amount into v_maint1, v_sink1
    from public.strata_charge_lines where run_id = v_run and unit_id = v_u1;
  select maintenance_amount into v_maint2
    from public.strata_charge_lines where run_id = v_run and unit_id = v_u2;
  select maintenance_amount into v_maint3
    from public.strata_charge_lines where run_id = v_run and unit_id = v_u3;

  -- 300 share units × RM0.35 × 3 months.
  perform pg_temp.check_eq('A-1-1 charges for the quarter', v_maint1, 315.00);
  perform pg_temp.check_eq('A-1-2 charges for the quarter', v_maint2, 105.00);
  perform pg_temp.check_eq('A-2-1 charges for the quarter', v_maint3, 210.00);

  -- The rule itself, stated as a ratio rather than as three numbers. If
  -- somebody changes the rate, the amounts above move and this does not.
  perform pg_temp.check_eq(
    'charges are in the ratio of the share units (300:100)',
    round(v_maint1 / v_maint2, 6), 3.000000);
  perform pg_temp.check_eq(
    'and again for 200:100',
    round(v_maint3 / v_maint2, 6), 2.000000);

  -- ------------------------------------------------------------------
  -- 2. The sinking fund floor
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'sinking fund is ten per cent of the charges', v_sink1, 31.50);

  -- And the floor is a floor. A scheme cannot resolve to contribute less
  -- than the Act requires, however the resolution is worded.
  begin
    insert into public.strata_charge_rates
      (org_id, scheme_id, effective_from, rate_per_share_unit,
       sinking_fund_percent)
    values (v_org, v_scheme, date '2027-01-01', 0.35, 9.5);
    raise exception
      'a sinking fund contribution below ten per cent of the Charges was '
      'accepted';
  exception
    when check_violation then
      raise notice 'ok   a sinking fund below ten per cent is refused';
  end;

  -- ------------------------------------------------------------------
  -- The run ties to the invoices it raised
  --
  -- Not decoration: the run's totals are what the committee is shown and
  -- the invoices are what the owners receive, and the two drifting apart
  -- is the kind of thing found a year later by an auditor.
  -- ------------------------------------------------------------------
  select parcels, total_maintenance, total_sinking
    into v_parcels, v_total_maint, v_total_sink
    from public.strata_charge_runs where id = v_run;

  perform pg_temp.check_eq('three parcels were billed', v_parcels, 3);
  perform pg_temp.check_eq('total charges', v_total_maint, 630.00);
  perform pg_temp.check_eq('total sinking fund', v_total_sink, 63.00);

  select sum(d.total_amount), count(*) into v_invoiced, v_lines
    from public.strata_charge_lines l
    join public.sales_documents d on d.id = l.invoice_id
   where l.run_id = v_run;

  perform pg_temp.check_eq(
    'the invoices raised come to the run total', v_invoiced, 693.00);
  perform pg_temp.check_eq(
    'one invoice per parcel, and every line has one', v_lines, 3);

  -- Each invoice carries the split. An owner asking what the money is
  -- for can read it off the invoice rather than off a policy document.
  select count(*) into v_lines
    from public.strata_charge_lines l
    join public.sales_document_lines dl on dl.document_id = l.invoice_id
   where l.run_id = v_run;
  perform pg_temp.check_eq(
    'two lines on each invoice: charges and sinking fund', v_lines, 6);

  -- ------------------------------------------------------------------
  -- 3. Late payment interest, ten per cent per annum, daily
  -- ------------------------------------------------------------------
  -- The unit function first, on a round number, so a failure says which
  -- half is wrong.
  perform pg_temp.check_eq(
    'a full year at ten per cent on RM1,000',
    app.strata_late_interest(1000, date '2026-01-01', date '2027-01-01', 10),
    100.00);
  perform pg_temp.check_eq(
    'nothing is charged before the due date',
    app.strata_late_interest(1000, date '2026-01-01', date '2026-01-01', 10),
    0);
  perform pg_temp.check_eq(
    'nor on the day after payment was due but before a day has passed',
    app.strata_late_interest(1000, date '2026-06-01', date '2026-01-01', 10),
    0);

  -- Then through the report. A-1-1 owes 315.00 + 31.50 = 346.50, due on
  -- 15 January and unpaid on 15 April — ninety days.
  select late_interest, total_due into v_interest, v_arrears
    from public.strata_arrears(v_scheme, date '2026-04-15')
   where unit_id = v_u1;

  -- 346.50 × 10% × 90/365 = 8.5438…
  perform pg_temp.check_eq(
    'ninety days of arrears on A-1-1', v_interest, 8.54);
  perform pg_temp.check_eq(
    'and what the owner owes with it', v_arrears, 355.04);

  -- The by-law caps the rate, and the table refuses a scheme that tries
  -- to resolve above it.
  begin
    insert into public.strata_charge_rates
      (org_id, scheme_id, effective_from, rate_per_share_unit,
       late_interest_percent)
    values (v_org, v_scheme, date '2028-01-01', 0.35, 12);
    raise exception
      'a late payment charge above ten per cent per annum was accepted';
  exception
    when check_violation then
      raise notice 'ok   a late payment charge above ten per cent is refused';
  end;

  -- ------------------------------------------------------------------
  -- A parcel with no share units cannot be billed
  --
  -- Because billing it means charging it something not proportional to
  -- its share units, and the only number available to charge it is one
  -- somebody made up.
  -- ------------------------------------------------------------------
  begin
    insert into public.property_units
      (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
    values (v_org, v_site, 'A-9-9', 'parcel', null, v_c1);
    raise exception 'a chargeable parcel with no share units was accepted';
  exception
    when check_violation then
      raise notice 'ok   a chargeable parcel needs allocated share units';
  end;

  -- ------------------------------------------------------------------
  -- The split between the two modules
  --
  -- This company bought strata and not non-strata. The rent engine must
  -- refuse it — otherwise the modules are one module with two names.
  -- ------------------------------------------------------------------
  begin
    perform public.raise_rent_invoices(
      v_site, date '2026-01-01', date '2026-01-31');
    raise exception
      'the rent engine ran for a company that has not bought the '
      'non-strata module';
  exception
    when insufficient_privilege then
      raise notice 'ok   rent invoicing refuses a strata-only company';
  end;

  -- And a strata site will not hold a shoplot.
  begin
    insert into public.property_units (org_id, site_id, unit_no, unit_type)
    values (v_org, v_site, 'SHOP-1', 'shop');
    raise exception 'a strata scheme accepted a shop unit';
  exception
    when check_violation then
      raise notice 'ok   a strata scheme holds parcels, not shoplots';
  end;

  raise notice 'strata: % parcels billed, charges % and sinking fund %',
    v_parcels, v_total_maint, v_total_sink;
end $$;

-- ---------------------------------------------------------------------
-- The non-strata half: tenancies and rent
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_site uuid;
  v_t1 uuid; v_t2 uuid; v_u1 uuid; v_u2 uuid;
  v_ten1 uuid; v_run uuid;
  v_full numeric; v_part numeric; v_months numeric;
  v_count integer; v_total numeric; v_invoiced numeric;
  v_due integer; v_overdue boolean;
  v_org2 uuid; v_site2 uuid; v_days integer;
begin
  v_org := pg_temp.test_org('Probe Property Holdings');

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_nonstrata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'ROW1', 'Jalan Probe shoplots', 'non_strata')
  returning id into v_site;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'TEN1', 'Tenant of Lot 1', 'customer') returning id into v_t1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'TEN2', 'Tenant of Lot 2', 'customer') returning id into v_t2;

  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (v_org, v_site, 'LOT-1', 'shop') returning id into v_u1;
  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (v_org, v_site, 'LOT-2', 'shop') returning id into v_u2;

  -- One tenancy running the whole month, one starting halfway through.
  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, security_deposit, utility_deposit, deposit_held, status)
  values (v_org, v_u1, v_t1, 'T-001', date '2025-06-01', date '2027-05-31',
          3000, 6000, 1500, 7500, 'active')
  returning id into v_ten1;

  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, status)
  values (v_org, v_u2, v_t2, 'T-002', date '2026-01-15', date '2027-01-14',
          2000, 'active');

  -- ------------------------------------------------------------------
  -- A tenant who moved in on the 15th owes part of a month
  -- ------------------------------------------------------------------
  select months, amount into v_months, v_part
    from public.rent_preview(v_site, date '2026-01-01', date '2026-01-31')
   where tenancy_no = 'T-002';
  select amount into v_full
    from public.rent_preview(v_site, date '2026-01-01', date '2026-01-31')
   where tenancy_no = 'T-001';

  perform pg_temp.check_eq('a whole month of rent is the rent', v_full, 3000.00);
  -- 17 days of January's 31, at RM2,000.
  perform pg_temp.check_eq(
    'seventeen days of January', v_months, 0.5484);
  perform pg_temp.check_eq(
    'and the rent for them', v_part, 1096.80);

  -- ------------------------------------------------------------------
  -- Raising it
  -- ------------------------------------------------------------------
  v_run := public.raise_rent_invoices(
    v_site, date '2026-01-01', date '2026-01-31', date '2026-01-07');

  select tenancies, total_rent into v_count, v_total
    from public.rent_runs where id = v_run;
  select sum(d.total_amount) into v_invoiced
    from public.rent_run_lines l
    join public.sales_documents d on d.id = l.invoice_id
   where l.run_id = v_run;

  perform pg_temp.check_eq('two tenancies billed', v_count, 2);
  perform pg_temp.check_eq('rent for the month', v_total, 4096.80);
  perform pg_temp.check_eq(
    'and the invoices agree with the run', v_invoiced, 4096.80);

  -- ------------------------------------------------------------------
  -- Raising it again, which used to bill everybody twice
  -- ------------------------------------------------------------------
  --
  -- The unique constraint on (site_id, period_from, period_to) already
  -- refused the SAME period. What it could not see was an overlapping
  -- one -- a different pair of dates is a different row -- so the
  -- fortnight in the middle was invoiced twice and nothing said so.
  -- `0584` is the check; these are the assertions that would fail if it
  -- were removed.
  perform pg_temp.check_refused(
    'the same period again is refused by name',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           v_site, date '2026-01-01', date '2026-01-31'),
    '%already been raised%');

  -- The one the constraint missed. Starts inside January and runs into
  -- February, so the middle fortnight would be billed a second time.
  perform pg_temp.check_refused(
    'and so is a period that merely overlaps it',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           v_site, date '2026-01-15', date '2026-02-15'),
    '%already been raised%');

  -- A period that ENDS the day the raised one begins touches nothing.
  -- Asserted because an overlap test written with the wrong bound
  -- refuses this too, and a property manager who cannot bill December
  -- after billing January has been handed a worse bug than the one
  -- being fixed.
  perform pg_temp.check_refused(
    'but the refusal names the run, so somebody can go and look',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           v_site, date '2026-01-20', date '2026-01-25'),
    '%run %');

  v_run := public.raise_rent_invoices(
    v_site, date '2026-02-01', date '2026-02-28', date '2026-02-07');
  perform pg_temp.check_true(
    'and the next month, which touches nothing, still raises',
    v_run is not null);

  -- ------------------------------------------------------------------
  -- The way back (0585)
  -- ------------------------------------------------------------------
  --
  -- 0584 refused a second raise and said plainly that it stopped short
  -- of an exclusion constraint because a wrong period could never be
  -- corrected. These assert the correction actually works.
  perform pg_temp.check_refused(
    'undoing a run without saying why is refused',
    format('select public.void_rent_run(%L)', v_run),
    '%Say why%');

  select count(*) into v_count
    from public.rent_run_lines where run_id = v_run;
  perform pg_temp.check_eq('February billed two tenancies', v_count, 2);

  perform pg_temp.check_eq(
    'and undoing it voids both invoices',
    public.void_rent_run(v_run, 'wrong dates'), 2);

  select count(*) into v_count
    from public.rent_run_lines l
    join public.sales_documents d on d.id = l.invoice_id
   where l.run_id = v_run and d.status = 'void';
  perform pg_temp.check_eq('both really are void', v_count, 2);

  perform pg_temp.check_refused(
    'and a run cannot be undone twice',
    format('select public.void_rent_run(%L, %L)', v_run, 'again'),
    '%already voided%');

  -- The whole point of the undo, and the assertion that would fail if
  -- either half of 0585 were missing -- the partial index or the
  -- voided_at clause in the overlap check.
  v_run := public.raise_rent_invoices(
    v_site, date '2026-02-01', date '2026-02-28', date '2026-02-07');
  perform pg_temp.check_true(
    'so the corrected period can be raised again', v_run is not null);

  -- And the refusal that keeps the undo from reintroducing the bug it
  -- exists to fix. One invoice paid, and the run will not come apart.
  update public.sales_documents d
     set paid_amount = 1.00
   where d.id = (select l.invoice_id from public.rent_run_lines l
                  where l.run_id = v_run limit 1);
  perform pg_temp.check_refused(
    'but a run with a paid invoice refuses to come apart at all',
    format('select public.void_rent_run(%L, %L)', v_run, 'too late'),
    '%have been paid%');

  select count(*) into v_count
    from public.rent_run_lines l
    join public.sales_documents d on d.id = l.invoice_id
   where l.run_id = v_run and d.status = 'void';
  perform pg_temp.check_eq(
    'and nothing was voided on the way to refusing', v_count, 0);

  -- `void_rent_run`, rule by rule. A mutation sweep
  -- (`mutants/void_rent_run.py`) found nothing above standing on the run
  -- that does not exist, who may undo one, an invoice LHDN accepted
  -- holding the run as a paid one does, the hold being THIS run's
  -- invoices and not another's, the invoices voided being this run's
  -- and nobody else's, what each voided invoice says about why, and who
  -- undid the run and why.
  declare
    v_mar uuid; v_mar_no text; v_held uuid;
  begin
    perform pg_temp.check_refused('a rent run that does not exist is said so',
      format('select public.void_rent_run(%L, %L)', gen_random_uuid(), 'gone'),
      'No such rent run.', 'P0002');

    perform pg_temp.sign_in_as(pg_temp.another_user('luar-sewa@example.test'));
    perform pg_temp.check_refused('somebody outside the company cannot undo its rent run',
      format('select public.void_rent_run(%L, %L)', v_run, 'not mine'),
      'Insufficient privileges to void a rent run', '42501');
    perform pg_temp.sign_in_as(pg_temp.test_user());

    -- Accepted by LHDN and unpaid holds the run exactly as paid does.
    select l.invoice_id into v_held from public.rent_run_lines l
     where l.run_id = v_run and exists (
       select 1 from public.sales_documents d
        where d.id = l.invoice_id and d.paid_amount > 0);
    update public.sales_documents
       set paid_amount = 0, einvoice_status = 'valid' where id = v_held;
    perform pg_temp.check_refused('an invoice LHDN accepted holds the run as a paid one does',
      format('select public.void_rent_run(%L, %L)', v_run, 'too late'),
      'This run cannot be undone: 1 of its invoices have been paid or accepted by LHDN.%',
      '23514');

    -- And it holds THIS run. March, raised beside it, comes apart while
    -- February stands -- and only March's two invoices go.
    v_mar := public.raise_rent_invoices(
      v_site, date '2026-03-01', date '2026-03-31', date '2026-03-07');
    select run_no into v_mar_no from public.rent_runs where id = v_mar;
    perform pg_temp.check_eq('another run''s accepted invoice does not hold this one',
      public.void_rent_run(v_mar, '  billed in the wrong month  '), 2);
    select count(*) into v_count
      from public.rent_run_lines l
      join public.sales_documents d on d.id = l.invoice_id
     where l.run_id <> v_mar and d.status = 'void'
       and d.org_id = v_org and l.run_id in (
         select id from public.rent_runs where site_id = v_site and voided_at is null);
    perform pg_temp.check_eq('and no other standing run lost an invoice', v_count, 0);
    perform pg_temp.check_eq('each voided invoice says which run and why',
      (select count(*)::integer from public.rent_run_lines l
         join public.sales_documents d on d.id = l.invoice_id
        where l.run_id = v_mar
          and d.internal_notes like '%Voided: Rent run ' || v_mar_no
                || ' voided: billed in the wrong month%'), 2);
    perform pg_temp.check_true('the run says who undid it, when, and why, without the spaces',
      (select voided_by = pg_temp.test_user() and voided_at = now()
              and void_reason = 'billed in the wrong month'
         from public.rent_runs where id = v_mar));
  end;

  -- ------------------------------------------------------------------
  -- One unit, one tenant, over any given day
  -- ------------------------------------------------------------------
  begin
    insert into public.tenancies
      (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
       monthly_rent, status)
    values (v_org, v_u1, v_t2, 'T-003', date '2026-03-01', date '2026-09-30',
            3200, 'active');
    raise exception 'the same unit was let to two tenants at once';
  exception
    when exclusion_violation then
      raise notice 'ok   a unit cannot be let twice over the same days';
  end;

  -- Re-letting after the first tenancy ends is fine, which is the
  -- control on the rule above: a constraint that refused every second
  -- tenancy would satisfy it too.
  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, status)
  values (v_org, v_u1, v_t2, 'T-004', date '2027-06-01', date '2028-05-31',
          3200, 'active');
  raise notice 'ok   and re-letting after it ends is allowed';

  -- ------------------------------------------------------------------
  -- Quit rent and assessment
  --
  -- Nothing is computed — the rates are state and local, and vary. What
  -- is asserted is the register: what is unpaid and due appears, what
  -- has been paid does not.
  -- ------------------------------------------------------------------
  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year, amount,
     due_date)
  values (v_org, v_site, 'quit_rent', 'Pejabat Tanah dan Galian',
          'QR-99', 2026, 1250.00, app.today() + 20);

  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year, period_half,
     amount, due_date)
  values (v_org, v_site, 'assessment', 'Majlis Bandaraya', 'AS-77',
          2026, 1, 880.00, app.today() - 10);

  -- Paid, so it must not appear however overdue it looks.
  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year, period_half,
     amount, due_date, paid_on, reference)
  values (v_org, v_site, 'assessment', 'Majlis Bandaraya', 'AS-77',
          2025, 2, 880.00, app.today() - 200, app.today() - 190,
          -- The receipt, because `0387` refuses a paid date with
          -- nothing behind it: paid at the counter is a real way to pay
          -- an assessment, but it has to name what paid it.
          'MBSA receipt 40218');

  select count(*) into v_due
    from public.property_statutory_due(v_org, 60);
  perform pg_temp.check_eq(
    'two bills outstanding, and the paid one is not among them', v_due, 2);

  select is_overdue into v_overdue
    from public.property_statutory_due(v_org, 60)
   where account_no = 'AS-77' and period = '2026 H1';
  perform pg_temp.check_true('the assessment is flagged overdue', v_overdue);

  -- The window is a window. A bill due in eighty days is not urgent and
  -- must not be reported as though it were.
  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year, amount,
     due_date)
  values (v_org, v_site, 'quit_rent', 'Pejabat Tanah dan Galian',
          'QR-98', 2027, 1250.00, app.today() + 80);
  select count(*) into v_due from public.property_statutory_due(v_org, 60);
  perform pg_temp.check_eq(
    'a bill beyond the window is not reported', v_due, 2);
  select count(*) into v_due from public.property_statutory_due(v_org, 120);
  perform pg_temp.check_eq('and is, when the window reaches it', v_due, 3);

  -- The window with nothing in it is sixty days, not for ever. The app
  -- passes a non-null integer, but the function is an RPC and anything
  -- holding a session can call it with no window at all; falling back
  -- to every bill on file would turn "what is due next" into the whole
  -- register.
  select count(*) into v_due from public.property_statutory_due(v_org, null);
  perform pg_temp.check_eq('no window given is sixty days', v_due, 2);

  -- The countdown itself, which is what the screen sorts and colours by
  -- and which nothing here read.
  --
  -- The fixture above dates from `app.today()`, not `current_date`,
  -- because that is what the function counts from. `app.today()` is
  -- `app.malaysian_day(now())`, and the CI runner is UTC: after 16:00
  -- UTC the two are different days, so a bill written `current_date +
  -- 20` read 19 and this file failed for eight hours out of every
  -- twenty-four. The clock was the only thing that changed. It is days until, not days since: a
  -- bill due in twenty days reads +20 and one missed ten days ago -10,
  -- and swapping them turns the urgent into the comfortable.
  select days_until into v_days
    from public.property_statutory_due(v_org, 60)
   where account_no = 'QR-99';
  perform pg_temp.check_eq('a bill due in twenty days counts down', v_days, 20);
  select days_until into v_days
    from public.property_statutory_due(v_org, 60)
   where account_no = 'AS-77' and period = '2026 H1';
  perform pg_temp.check_eq('and a missed one counts up past zero',
                           v_days, -10);

  -- And it is this company's register. A managing agent's own books and
  -- the schemes they manage sit in one login, so `is_org_member` passes
  -- for every company on the screen and is no help at all here: the
  -- only thing keeping one site's quit rent off another's report is the
  -- org_id in the where clause.
  v_org2 := pg_temp.test_org('Probe Estates');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org2, 'property_nonstrata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org2, 'ROW2', 'Somebody else''s shoplots', 'non_strata')
  returning id into v_site2;
  insert into public.property_statutory_charges
    (org_id, site_id, kind, authority, account_no, period_year, amount,
     due_date)
  values (v_org2, v_site2, 'quit_rent', 'Pejabat Tanah dan Galian',
          'QR-OTHER', 2026, 4000.00, app.today() + 5);

  select count(*) into v_due from public.property_statutory_due(v_org, 60);
  perform pg_temp.check_eq(
    'and another company''s bills are not on this one''s report', v_due, 2);
  select count(*) into v_due from public.property_statutory_due(v_org2, 60);
  perform pg_temp.check_eq('while its own company still sees it', v_due, 1);

  raise notice 'non-strata: % tenancies billed, rent %', v_count, v_total;
end $$;

-- ---------------------------------------------------------------------
-- The arrears list, rule by rule
--
-- A mutation sweep of `strata_arrears` killed 2 of 13 on this file: the
-- one read of it was one parcel's interest on one date. Five parcels
-- here, each invoice put in a different state, two quarters' runs so the
-- order means something, a second scheme in the same company, a date
-- before anything falls due, and the three refusals.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_site uuid; v_site2 uuid; v_scheme uuid; v_scheme2 uuid;
  v_u uuid[] := array[]::uuid[]; v_c uuid; v_unit uuid; i integer;
  v_q1 uuid; v_q2 uuid; v_other uuid; v_stranger uuid; v_order text;
  v_inv uuid[];
begin
  v_org := pg_temp.test_org('Tunggakan Peraturan MC', array['property_strata']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_strata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'TP1', 'Tunggakan Residency', 'strata') returning id into v_site;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (v_org, v_site, 'mc', 500) returning id into v_scheme;
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (v_org, v_scheme, date '2026-01-01', 0.35, 10, 10);

  for i in 1..5 loop
    insert into public.contacts (org_id, code, name, contact_type)
    values (v_org, 'T' || i, 'Pemilik ' || i, 'customer') returning id into v_c;
    insert into public.property_units
      (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
    values (v_org, v_site, 'B-' || i, 'parcel', 100, v_c) returning id into v_unit;
    v_u := v_u || v_unit;
  end loop;

  v_q1 := public.raise_strata_charges(
    v_scheme, date '2026-01-01', date '2026-03-31', date '2026-01-15');
  select array_agg(l.invoice_id order by u.unit_no) into v_inv
    from public.strata_charge_lines l
    join public.property_units u on u.id = l.unit_id
   where l.run_id = v_q1;
  -- B-2 voided, B-3 paid, B-4 deleted, B-5 back to draft.
  update public.sales_documents set status = 'void' where id = v_inv[2];
  update public.sales_documents set balance_amount = 0, status = 'completed'
   where id = v_inv[3];
  update public.sales_documents set deleted_at = now() where id = v_inv[4];
  update public.sales_documents set status = 'draft' where id = v_inv[5];

  perform pg_temp.check_eq(
    'only the unpaid, posted, live invoice is in arrears',
    (select string_agg(unit_no, ' ' order by unit_no)
       from public.strata_arrears(v_scheme, date '2026-03-31')), 'B-1');

  -- Before it falls due: owed, not yet late.
  perform pg_temp.check_eq('before the due date it is nought days late',
    (select days_overdue from public.strata_arrears(v_scheme, date '2026-01-10')
      where unit_no = 'B-1'), 0);
  perform pg_temp.check_eq('and five days after, five',
    (select days_overdue from public.strata_arrears(v_scheme, date '2026-01-20')
      where unit_no = 'B-1'), 5);

  -- A second quarter: B-1 owes twice, and B-2's new invoice is unpaid.
  v_q2 := public.raise_strata_charges(
    v_scheme, date '2026-04-01', date '2026-06-30', date '2026-04-15');
  -- So that parcel order and date order disagree: B-1 pays January, and
  -- B-5's January invoice is posted after all. By parcel, B-5's January
  -- debt is near the end; by date it would be first.
  update public.sales_documents set balance_amount = 0, status = 'completed'
   where id = v_inv[1];
  update public.sales_documents set status = 'posted' where id = v_inv[5];
  select string_agg(unit_no || '@' || to_char(due_date, 'MM'), ' ' order by ord)
    into v_order
    from (select unit_no, due_date, row_number() over () as ord
            from public.strata_arrears(v_scheme, date '2026-06-30')) x;
  perform pg_temp.check_eq('listed by parcel, then by when each fell due',
    v_order, 'B-1@04 B-2@04 B-3@04 B-4@04 B-5@01 B-5@04');

  -- Another scheme in the same company is its own list.
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'TP2', 'Another Residency', 'strata') returning id into v_site2;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (v_org, v_site2, 'mc', 100) returning id into v_scheme2;
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (v_org, v_scheme2, date '2026-01-01', 0.35, 10, 10);
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site2, 'Z-1', 'parcel', 100, v_c);
  perform public.raise_strata_charges(
    v_scheme2, date '2026-01-01', date '2026-03-31', date '2026-01-15');
  perform pg_temp.check_eq('another scheme''s parcels are not on this list',
    (select count(*)::integer from public.strata_arrears(v_scheme, date '2026-06-30')
      where unit_no = 'Z-1'), 0);

  -- The refusals.
  perform pg_temp.check_refused('a scheme that does not exist is said so',
    format('select * from public.strata_arrears(%L)', gen_random_uuid()),
    '%No such strata scheme%', 'P0002');
  v_stranger := pg_temp.another_user('orang.luar@strata.test');
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_refused('a stranger is refused',
    format('select * from public.strata_arrears(%L)', v_scheme),
    '%Not your scheme%', '42501');
  perform pg_temp.sign_in_as(
    (select created_by from public.organizations where id = v_org));
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'property_strata';
  perform pg_temp.check_refused('and so is a company that has given up the module',
    format('select * from public.strata_arrears(%L)', v_scheme),
    '%Not your scheme%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- `raise_rent_invoices`, rule by rule
--
-- A mutation sweep (`mutants/raise_rent_invoices.py`) left ten of its
-- rules with nothing above able to tell them from their absence. Three
-- were shadowed: `rent_preview` refuses a stranger and a company
-- without the module too, in other words ("Not your site"), so the
-- block above passed whichever guard did it. A VIEWER is the case that
-- separates them -- a member, so `rent_preview` lets them through, who
-- may not post. The rest were never asked: the due date either way,
-- what the invoice and its line say, the months on the run line, that
-- the invoices are posted, and a site with nobody to bill.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_viewer uuid := pg_temp.another_user('rent-viewer@iakauntan.test');
  v_org uuid; v_bare uuid; v_site uuid; v_empty uuid; v_bsite uuid;
  v_t1 uuid; v_t2 uuid; v_u1 uuid; v_u2 uuid;
  v_run uuid; v_inv uuid; v_inv2 uuid;
  v_runs integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Sewa Satu Persatu Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_nonstrata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_viewer, 'viewer', 'active', now());

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'ROW9', 'Jalan Sembilan', 'non_strata') returning id into v_site;
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'ROW0', 'Jalan Kosong', 'non_strata') returning id into v_empty;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'TEN9', 'Penyewa Sembilan', 'customer') returning id into v_t1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'TEN8', 'Penyewa Lapan', 'customer') returning id into v_t2;
  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (v_org, v_site, 'LOT-9', 'shop') returning id into v_u1;
  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (v_org, v_site, 'LOT-8', 'shop') returning id into v_u2;
  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, status)
  values (v_org, v_u1, v_t1, 'T-009', date '2025-06-01', date '2027-05-31',
          3000, 'active');
  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, status)
  values (v_org, v_u2, v_t2, 'T-008', date '2026-01-15', date '2027-01-14',
          2000, 'active');

  -- Who and where.
  perform pg_temp.check_refused('a site that does not exist is said so',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           gen_random_uuid(), date '2026-01-01', date '2026-01-31'),
    'No such site', 'P0002');

  perform pg_temp.sign_in_as(v_viewer);
  perform pg_temp.check_true('the viewer can see the site''s rent',
    (select count(*) from public.rent_preview(v_site, date '2026-01-01', date '2026-01-31')) = 2);
  perform pg_temp.check_refused('but may not raise it',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           v_site, date '2026-01-01', date '2026-01-31'),
    'Insufficient privileges to raise invoices', '42501');
  perform pg_temp.sign_in_as(v_owner);

  perform pg_temp.allow_many_companies();
  v_bare := pg_temp.test_org('Tiada Sewa Sdn Bhd', array['property_strata']);
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_bare, 'ROW1', 'Jalan Satu', 'non_strata') returning id into v_bsite;
  perform pg_temp.check_refused('a company without the module is told which module',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           v_bsite, date '2026-01-01', date '2026-01-31'),
    'The non-strata property module is not switched on for this company', '42501');

  -- Nobody to bill: refused, and no empty run left behind.
  perform pg_temp.check_refused('a site with nobody to bill raises nothing',
    format('select public.raise_rent_invoices(%L, %L, %L)',
           v_empty, date '2026-01-01', date '2026-01-31'),
    'No active tenancy at this site covers 2026-01-01 to 2026-01-31.', 'P0002');
  select count(*) into v_runs from public.rent_runs where site_id = v_empty;
  perform pg_temp.check_eq('and leaves no run behind', v_runs, 0);

  -- A due date asked for.
  v_run := public.raise_rent_invoices(
    v_site, date '2026-01-01', date '2026-01-31', date '2026-01-10');
  select l.invoice_id into v_inv from public.rent_run_lines l
    join public.tenancies t on t.id = l.tenancy_id
   where l.run_id = v_run and t.tenancy_no = 'T-009';
  select l.invoice_id into v_inv2 from public.rent_run_lines l
    join public.tenancies t on t.id = l.tenancy_id
   where l.run_id = v_run and t.tenancy_no = 'T-008';
  perform pg_temp.check_eq('the invoice falls due the day asked for',
    (select due_date::text from public.sales_documents where id = v_inv), '2026-01-10');
  perform pg_temp.check_eq('and is dated the first day of the period',
    (select doc_date::text from public.sales_documents where id = v_inv), '2026-01-01');
  perform pg_temp.check_eq('it names the unit',
    (select subject from public.sales_documents where id = v_inv), 'Rent — LOT-9');
  perform pg_temp.check_eq('and its line names the days',
    (select description from public.sales_document_lines where document_id = v_inv2),
    'Rent for LOT-8, 2026-01-15 to 2026-01-31');
  perform pg_temp.check_eq('the run line holds the part of a month billed',
    (select months from public.rent_run_lines where invoice_id = v_inv2), 0.5484::numeric);
  perform pg_temp.check_true('both invoices are posted, each with a journal',
    (select bool_and(d.status = 'posted' and d.gl_entry_id is not null)
       from public.rent_run_lines l join public.sales_documents d on d.id = l.invoice_id
      where l.run_id = v_run));
  perform pg_temp.check_eq('and the journal credits rent with the rent',
    (select sum(gl.credit) from public.gl_lines gl
       join public.sales_documents d on d.gl_entry_id = gl.entry_id
      where d.id = v_inv and gl.account_id = app.property_income_account(v_org, 'rent')),
    3000.00::numeric);

  -- No due date: it falls due when the period starts.
  v_run := public.raise_rent_invoices(v_site, date '2026-02-01', date '2026-02-28');
  perform pg_temp.check_eq('with no due date, rent falls due on the first day',
    (select min(d.due_date)::text || '/' || max(d.due_date)::text
       from public.rent_run_lines l join public.sales_documents d on d.id = l.invoice_id
      where l.run_id = v_run), '2026-02-01/2026-02-01');
end $$;

-- ---------------------------------------------------------------------
-- `raise_strata_charges`, rule by rule
--
-- A mutation sweep (`mutants/raise_strata_charges.py`) left thirteen of
-- its nineteen rules with nothing in this file to tell them from their
-- absence -- including that a period is not raised twice, which the
-- rent side has asserted since `0584` and this side never did. Each
-- refusal here has the case beside it that must still go through.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_viewer uuid := pg_temp.another_user('strata-viewer@iakauntan.test');
  v_org uuid; v_bare uuid; v_site uuid; v_bsite uuid; v_esite uuid; v_nsite uuid;
  v_scheme uuid; v_bscheme uuid; v_empty uuid; v_norate uuid; v_unowned uuid;
  v_jan_rate uuid;
  v_c1 uuid; v_c2 uuid; v_u1 uuid; v_u2 uuid;
  v_run uuid; v_inv uuid;
  v_runs integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Strata Satu Persatu', array['property_strata']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_strata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_viewer, 'viewer', 'active', now());

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'SR1', 'Residensi Satu', 'strata') returning id into v_site;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (v_org, v_site, 'mc', 300) returning id into v_scheme;
  -- Two rates: the AGM's for January, and a higher one from March. A
  -- quarter starting in January is charged at January's.
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (v_org, v_scheme, date '2026-01-01', 0.35, 10, 10)
  returning id into v_jan_rate;
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (v_org, v_scheme, date '2026-03-01', 0.40, 10, 10);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWB1', 'Pemilik B-1', 'customer') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWB2', 'Pemilik B-2', 'customer') returning id into v_c2;
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'B-1', 'parcel', 100, v_c1) returning id into v_u1;
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'B-2', 'parcel', 200, v_c2) returning id into v_u2;

  -- Who and where.
  perform pg_temp.check_refused('a scheme that does not exist is said so',
    format('select public.raise_strata_charges(%L, %L, %L)',
           gen_random_uuid(), date '2026-01-01', date '2026-03-31'),
    'No such strata scheme', 'P0002');

  perform pg_temp.sign_in_as(v_viewer);
  perform pg_temp.check_refused('a viewer may not raise charges',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_scheme, date '2026-01-01', date '2026-03-31'),
    'Insufficient privileges to raise charges', '42501');
  perform pg_temp.sign_in_as(v_owner);

  v_bare := pg_temp.test_org('Bukan Strata Sdn Bhd', array['property_nonstrata']);
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_bare, 'SR2', 'Residensi Dua', 'strata') returning id into v_bsite;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (v_bare, v_bsite, 'mc', 100) returning id into v_bscheme;
  perform pg_temp.check_refused('a company without the module is told which module',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_bscheme, date '2026-01-01', date '2026-03-31'),
    'The strata module is not switched on for this company', '42501');

  -- No rate in force, and nothing chargeable: refused, no run left.
  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'SR3', 'Residensi Tiga', 'strata') returning id into v_nsite;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (v_org, v_nsite, 'mc', 100) returning id into v_norate;
  perform pg_temp.check_refused('no rate in force, no charges',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_norate, date '2026-01-01', date '2026-03-31'),
    'No charge rate is in force on 2026-01-01.%', 'P0002');

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'SR4', 'Residensi Empat', 'strata') returning id into v_esite;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (v_org, v_esite, 'mc', 100) returning id into v_empty;
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit, sinking_fund_percent)
  values (v_org, v_empty, date '2026-01-01', 0.35, 10);
  perform pg_temp.check_refused('a scheme with nothing chargeable raises nothing',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_empty, date '2026-01-01', date '2026-03-31'),
    'No parcel in this scheme is chargeable.%', 'P0002');
  select count(*) into v_runs from public.strata_charge_runs
   where scheme_id in (v_norate, v_empty);
  perform pg_temp.check_eq('and neither left a run behind', v_runs, 0);

  -- The quarter, due on the 20th.
  v_run := public.raise_strata_charges(
    v_scheme, date '2026-01-01', date '2026-03-31', date '2026-01-20');
  perform pg_temp.check_eq('the run is at the rate in force when the period starts',
    (select rate_id from public.strata_charge_runs where id = v_run), v_jan_rate);
  perform pg_temp.check_eq('so B-1 is charged 100 units at 0.35 for three months',
    (select maintenance_amount from public.strata_charge_lines
      where run_id = v_run and unit_id = v_u1), 105.00::numeric);
  select invoice_id into v_inv from public.strata_charge_lines
   where run_id = v_run and unit_id = v_u1;
  perform pg_temp.check_eq('the invoice falls due the day asked for',
    (select due_date::text from public.sales_documents where id = v_inv), '2026-01-20');
  perform pg_temp.check_eq('it names the parcel',
    (select subject from public.sales_documents where id = v_inv),
    'Maintenance charges — B-1');
  perform pg_temp.check_eq('and the sinking fund is credited to the sinking fund',
    (select sum(gl.credit) from public.gl_lines gl
       join public.sales_documents d on d.gl_entry_id = gl.entry_id
      where d.id = v_inv
        and gl.account_id = app.property_income_account(v_org, 'sinking')),
    10.50::numeric);

  -- Not twice over the same days.
  perform pg_temp.check_refused('the same quarter again is refused',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_scheme, date '2026-01-01', date '2026-03-31'),
    'Charges for this scheme have already been raised for 2026-01-01 to 2026-03-31%',
    '23505');
  perform pg_temp.check_refused('and so is a period that merely overlaps it',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_scheme, date '2026-03-01', date '2026-05-31'),
    'Charges for this scheme have already been raised%', '23505');

  -- The next quarter touches nothing, and has no due date: it falls due
  -- when it starts.
  v_run := public.raise_strata_charges(v_scheme, date '2026-04-01', date '2026-06-30');
  perform pg_temp.check_eq('with no due date, charges fall due on the first day',
    (select min(d.due_date)::text || '/' || max(d.due_date)::text
       from public.strata_charge_lines l join public.sales_documents d on d.id = l.invoice_id
      where l.run_id = v_run), '2026-04-01/2026-04-01');

  -- Undone, the same quarter can be raised again.
  perform public.void_strata_charge_run(v_run, 'wrong quarter');
  v_run := public.raise_strata_charges(v_scheme, date '2026-04-01', date '2026-06-30');
  perform pg_temp.check_true('a voided run does not hold its period', v_run is not null);

  -- A chargeable parcel with nobody to invoice stops the whole run.
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units)
  values (v_org, v_esite, 'C-1', 'parcel', 100) returning id into v_unowned;
  perform pg_temp.check_refused('a parcel with no owner is named, not skipped',
    format('select public.raise_strata_charges(%L, %L, %L)',
           v_empty, date '2026-01-01', date '2026-03-31'),
    'Parcel C-1 has no owner on record%', '23502');
end $$;

rollback;
