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

rollback;
