-- =====================================================================
-- iAkauntan :: which parcels the Charges are levied on
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/strata_preview.sql
--
-- property.sql already asserts the arithmetic: that the Charges are in
-- proportion to allocated share units, that the sinking fund is at
-- least ten per cent of them, and what the totals come to. It does that
-- through raise_strata_charges, which fills strata_charge_lines from
-- strata_charge_preview, so the sums are covered and are not repeated
-- here.
--
-- What nothing covers is the other half of the same function: which
-- rows it returns at all. The preview filters on four things --
--
--   u.is_active and u.is_chargeable
--   and u.unit_type = 'parcel'
--   and coalesce(u.share_units, 0) > 0
--
-- -- and two of those are the difference between a lawful demand and an
-- unlawful one. An accessory parcel is a car park bay or a store, and
-- its share is already inside its principal parcel's; charge it
-- separately and that owner pays twice. A parcel the management
-- corporation has resolved is not chargeable -- its own office, the
-- guard house -- charged anyway is money demanded from somebody with no
-- obligation to pay it. Neither shows up as an error. Both show up as
-- an invoice.
--
-- The other two filters sit behind the trigger in 0162, which refuses a
-- chargeable parcel with no share units at insert and refuses a shop on
-- a strata site outright, so the fixture cannot even build those rows.
-- They are asserted in property.sql where the trigger is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_owner   uuid := pg_temp.test_user();
  v_site    uuid;
  v_scheme  uuid;
  v_c1      uuid;
  v_c2      uuid;
  v_parcel  uuid;
  v_bay     uuid;
  v_office  uuid;
  v_gone    uuid;
  v_orphan  uuid;
  v_other   uuid;
  v_msg     text;
  r         record;
  v_n       integer;
begin
  v_org := pg_temp.test_org('Menara Probe MC', array['property_strata']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'property_strata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);

  insert into public.property_sites (org_id, code, name, tenure)
  values (v_org, 'MP1', 'Menara Probe', 'strata') returning id into v_site;
  insert into public.strata_schemes
    (org_id, site_id, stage, total_share_units)
  values (v_org, v_site, 'mc', 1000) returning id into v_scheme;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWN1', 'Owner of B-1-1', 'customer') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'OWN2', 'Owner of B-1-2', 'customer') returning id into v_c2;

  -- The one parcel that should be charged.
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'B-1-1', 'parcel', 200, v_c1)
  returning id into v_parcel;

  -- A car park bay. It carries share units of its own in the Schedule
  -- of Parcels, and it is still not billed separately: the Charges
  -- follow the principal parcel it is tied to.
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id,
     principal_unit_id)
  values (v_org, v_site, 'CP-14', 'accessory', 20, v_c1, v_parcel)
  returning id into v_bay;

  -- The management corporation's own office, resolved not chargeable.
  -- It has share units like any other parcel -- the Schedule of Parcels
  -- allocates them whatever the MC later resolves -- so is_chargeable
  -- is the only thing keeping it off the demand. Giving it none would
  -- make the assertion below pass on the share units filter instead,
  -- and the rule it is aimed at would go untested.
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id,
     is_chargeable)
  values (v_org, v_site, 'MC-OFFICE', 'parcel', 120, null, false)
  returning id into v_office;

  -- A parcel that has been deactivated.
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id,
     is_active)
  values (v_org, v_site, 'B-9-9', 'parcel', 150, v_c2, false)
  returning id into v_gone;

  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (v_org, v_scheme, date '2026-01-01', 0.50, 10, 10);

  -- ==================================================================
  -- Who is on the demand
  -- ==================================================================
  select count(*) into v_n from public.strata_charge_preview(
    v_scheme, date '2026-01-01', date '2026-01-31');
  perform pg_temp.check_eq('one parcel in four is chargeable', v_n, 1);

  select * into r from public.strata_charge_preview(
    v_scheme, date '2026-01-01', date '2026-01-31');
  perform pg_temp.check_eq('and it is the parcel', r.unit_no, 'B-1-1');
  perform pg_temp.check_eq('with its owner named', r.owner_name,
    'Owner of B-1-1');
  perform pg_temp.check_eq('and its share units', r.share_units, 200);
  -- 200 share units at 50 sen for one month.
  perform pg_temp.check_eq('the Charges for the month',
    r.maintenance_amount, 100.00);
  perform pg_temp.check_eq('the sinking fund on top', r.sinking_amount, 10.00);
  perform pg_temp.check_eq('and the total is the two of them',
    r.total_amount, r.maintenance_amount + r.sinking_amount);

  -- Each exclusion named, so a failure says which rule moved rather
  -- than only that the count is wrong.
  perform pg_temp.check_eq('a car park bay is not billed separately',
    (select count(*) from public.strata_charge_preview(
       v_scheme, date '2026-01-01', date '2026-01-31')
      where unit_id = v_bay), 0);
  perform pg_temp.check_eq('nor is a parcel resolved not chargeable',
    (select count(*) from public.strata_charge_preview(
       v_scheme, date '2026-01-01', date '2026-01-31')
      where unit_id = v_office), 0);
  perform pg_temp.check_eq('nor a deactivated parcel',
    (select count(*) from public.strata_charge_preview(
       v_scheme, date '2026-01-01', date '2026-01-31')
      where unit_id = v_gone), 0);

  -- The preview is a preview. Looking at what would be raised must not
  -- raise it.
  perform pg_temp.check_eq('previewing raises no charge run',
    (select count(*) from public.strata_charge_runs where org_id = v_org), 0);
  perform pg_temp.check_eq('and no invoice',
    (select count(*) from public.sales_documents where org_id = v_org), 0);

  -- ==================================================================
  -- A parcel nobody owns
  --
  -- It belongs on the preview, because the manager needs to see the
  -- gap; it cannot be billed, because there is nobody to bill.
  -- ==================================================================
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (v_org, v_site, 'B-2-2', 'parcel', 100, null)
  returning id into v_orphan;

  select * into r from public.strata_charge_preview(
    v_scheme, date '2026-01-01', date '2026-01-31')
   where unit_id = v_orphan;
  perform pg_temp.check_eq('an unowned parcel is still on the preview',
    r.unit_no, 'B-2-2');
  perform pg_temp.check_true('with no owner against it',
    r.owner_contact_id is null and r.owner_name is null);
  perform pg_temp.check_eq('and its charge worked out all the same',
    r.maintenance_amount, 50.00);

  begin
    perform public.raise_strata_charges(
      v_scheme, date '2026-01-01', date '2026-01-31');
    raise exception 'FAIL: charges were raised against a parcel with no owner';
  exception when sqlstate '23502' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('but raising them names the parcel to fix',
      v_msg like '%B-2-2%');
    raise notice 'ok   and cannot be billed to nobody';
  end;

  -- Nothing was left half raised behind the refusal.
  perform pg_temp.check_eq('and the refusal left no invoices behind',
    (select count(*) from public.sales_documents where org_id = v_org), 0);

  delete from public.property_units where id = v_orphan;

  -- ==================================================================
  -- What the preview refuses
  -- ==================================================================
  begin
    perform public.strata_charge_preview(
      gen_random_uuid(), date '2026-01-01', date '2026-01-31');
    raise exception 'FAIL: a scheme that does not exist was previewed';
  exception when sqlstate 'P0002' then
    raise notice 'ok   there has to be a scheme';
  end;

  begin
    perform public.strata_charge_preview(
      v_scheme, date '2026-03-31', date '2026-01-01');
    raise exception 'FAIL: a period that ends before it starts was previewed';
  exception when sqlstate '22023' then
    raise notice 'ok   the period has to end after it starts';
  end;

  -- The rate comes from an AGM resolution, and there was no AGM before
  -- 2026. Nothing can be demanded for a period with no rate in force.
  begin
    perform public.strata_charge_preview(
      v_scheme, date '2025-06-01', date '2025-06-30');
    raise exception 'FAIL: charges were previewed with no rate in force';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and a rate the owners resolved on';
  end;

  -- ==================================================================
  -- Somebody else's building
  -- ==================================================================
  v_other := pg_temp.another_user('stranger@example.test');
  perform pg_temp.sign_in_as(v_other);
  begin
    perform public.strata_charge_preview(
      v_scheme, date '2026-01-01', date '2026-01-31');
    raise exception 'FAIL: a stranger previewed the charges';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot see what the block is charged';
  end;

  -- And a member of a company that never bought the module is refused
  -- on the same line, because the entitlement is checked beside
  -- membership rather than after it.
  perform pg_temp.sign_in_as(v_owner);
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'property_strata';
  begin
    perform public.strata_charge_preview(
      v_scheme, date '2026-01-01', date '2026-01-31');
    raise exception 'FAIL: the strata module was switched off and it still ran';
  exception when sqlstate '42501' then
    raise notice 'ok   nor a company that has not bought strata';
  end;
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'property_strata';

  perform pg_temp.sign_out();
end $$;

rollback;
