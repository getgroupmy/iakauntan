-- =====================================================================
-- iAkauntan :: a billing run is undone by undoing it (0806)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/billing_runs.sql
--
-- A rent run and a strata charge run each refuse a period that overlaps
-- a run not voided, which is what keeps a tenant or an owner from being
-- billed twice; `void_rent_run` and `void_strata_charge_run` undo one,
-- voiding its invoices first. Before `0806` a client could write the
-- runs and their lines directly: a rent run stamped void by hand, its
-- invoices untouched, let the same month be raised again. Asked as the
-- owner, with the role `authenticated`, which is who the app is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_br (
  org uuid, site uuid, rent_run uuid, scheme uuid, strata_run uuid);
grant select on t_br to authenticated;

do $$
declare
  r      t_br;
  v_rsite uuid;
  v_t1 uuid; v_t2 uuid; v_u1 uuid; v_u2 uuid;
  v_c1 uuid; v_c2 uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Probe Billing Holdings',
                            array['property_strata', 'property_nonstrata']);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (r.org, 'property_strata', true, now()),
         (r.org, 'property_nonstrata', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');

  -- Two shoplots let, and January's rent raised.
  insert into public.property_sites (org_id, code, name, tenure)
  values (r.org, 'ROW1', 'Jalan Probe shoplots', 'non_strata')
  returning id into r.site;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'TEN1', 'Tenant of Lot 1', 'customer') returning id into v_t1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'TEN2', 'Tenant of Lot 2', 'customer') returning id into v_t2;
  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (r.org, r.site, 'LOT-1', 'shop') returning id into v_u1;
  insert into public.property_units (org_id, site_id, unit_no, unit_type)
  values (r.org, r.site, 'LOT-2', 'shop') returning id into v_u2;
  insert into public.tenancies
    (org_id, unit_id, tenant_contact_id, tenancy_no, start_date, end_date,
     monthly_rent, status)
  values (r.org, v_u1, v_t1, 'T-001', date '2025-06-01', date '2027-05-31', 3000, 'active'),
         (r.org, v_u2, v_t2, 'T-002', date '2025-06-01', date '2027-05-31', 2000, 'active');
  r.rent_run := public.raise_rent_invoices(
    r.site, date '2026-01-01', date '2026-01-31', date '2026-01-07');

  -- And a strata scheme of two parcels, its first quarter charged.
  insert into public.property_sites (org_id, code, name, tenure)
  values (r.org, 'PR1', 'Probe Residency', 'strata') returning id into v_rsite;
  insert into public.strata_schemes (org_id, site_id, stage, total_share_units)
  values (r.org, v_rsite, 'mc', 400) returning id into r.scheme;
  insert into public.strata_charge_rates
    (org_id, scheme_id, effective_from, rate_per_share_unit,
     sinking_fund_percent, late_interest_percent)
  values (r.org, r.scheme, date '2026-01-01', 0.35, 10, 10);
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'OWN1', 'Owner of A-1-1', 'customer') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'OWN2', 'Owner of A-1-2', 'customer') returning id into v_c2;
  insert into public.property_units
    (org_id, site_id, unit_no, unit_type, share_units, owner_contact_id)
  values (r.org, v_rsite, 'A-1-1', 'parcel', 300, v_c1),
         (r.org, v_rsite, 'A-1-2', 'parcel', 100, v_c2);
  r.strata_run := public.raise_strata_charges(
    r.scheme, date '2026-01-01', date '2026-03-31', date '2026-01-15');

  insert into t_br select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- A member reads all four
-- =====================================================================
do $$
declare d t_br;
begin
  select * into d from t_br;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_eq('the rent run and its two invoices are read',
    (select count(*)::integer from public.rent_run_lines where run_id = d.rent_run), 2);
  perform pg_temp.check_eq('and the strata run and its two',
    (select count(*)::integer from public.strata_charge_lines where run_id = d.strata_run), 2);
  perform pg_temp.check_true('each run is live',
    (select voided_at is null from public.rent_runs where id = d.rent_run)
    and (select voided_at is null from public.strata_charge_runs where id = d.strata_run));
end $$;

-- =====================================================================
-- None of them is written by hand
-- =====================================================================
do $$
declare
  d   t_br;
  v_t text;
begin
  select * into d from t_br;
  foreach v_t in array array['rent_runs', 'rent_run_lines',
    'strata_charge_runs', 'strata_charge_lines']
  loop
    perform pg_temp.check_refused(format('%s takes no insert', v_t),
      format('insert into public.%I (org_id) values (%L)', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
    perform pg_temp.check_refused(format('%s takes no update', v_t),
      format('update public.%I set org_id = org_id where org_id = %L', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
    perform pg_temp.check_refused(format('%s takes no delete', v_t),
      format('delete from public.%I where org_id = %L', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
  end loop;

  -- What was measured: the run stamped void by hand, its invoices left.
  perform pg_temp.check_refused('a rent run is not stamped void by hand',
    format('update public.rent_runs set voided_at = now(), void_reason = %L where id = %L',
           'by hand', d.rent_run),
    'permission denied for table rent_runs', '42501');
  perform pg_temp.check_refused('so January is not raised twice',
    format('select public.raise_rent_invoices(%L, %L, %L, %L)',
           d.site, date '2026-01-01', date '2026-01-31', date '2026-01-07'),
    'Rent for this site has already been raised for 2026-01-01 to 2026-01-31%', '23505');
  perform pg_temp.check_refused('nor a strata run stamped void by hand',
    format('update public.strata_charge_runs set voided_at = now() where id = %L',
           d.strata_run),
    'permission denied for table strata_charge_runs', '42501');
  perform pg_temp.check_refused('so the quarter is not charged twice',
    format('select public.raise_strata_charges(%L, %L, %L, %L)',
           d.scheme, date '2026-01-01', date '2026-03-31', date '2026-01-15'),
    'Charges for this scheme have already been raised for 2026-01-01 to 2026-03-31%', '23505');
  perform pg_temp.check_eq('and January holds two live rent invoices, not four',
    (select count(*)::integer from public.rent_run_lines l
       join public.sales_documents s on s.id = l.invoice_id
      where s.org_id = d.org and s.status <> 'void'), 2);
end $$;

-- =====================================================================
-- The functions are the road, and still run
-- =====================================================================
do $$
declare
  d     t_br;
  v_run uuid;
begin
  select * into d from t_br;
  perform pg_temp.check_eq('a client undoes the rent run through its function',
    public.void_rent_run(d.rent_run, 'wrong dates'), 2);
  perform pg_temp.check_true('which voids its invoices and stamps it',
    (select voided_at is not null from public.rent_runs where id = d.rent_run)
    and not exists (select 1 from public.rent_run_lines l
                      join public.sales_documents s on s.id = l.invoice_id
                     where l.run_id = d.rent_run and s.status <> 'void'));
  v_run := public.raise_rent_invoices(
    d.site, date '2026-01-01', date '2026-01-31', date '2026-01-07');
  perform pg_temp.check_eq('and January is raised again, once',
    (select count(*)::integer from public.rent_run_lines where run_id = v_run), 2);

  perform pg_temp.check_eq('the strata run is undone through its function too',
    public.void_strata_charge_run(d.strata_run, 'wrong rate'), 2);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the four',
    (select count(*)::integer from pg_policies
      where schemaname = 'public'
        and tablename in ('rent_runs', 'rent_run_lines',
                          'strata_charge_runs', 'strata_charge_lines')
        and cmd <> 'SELECT'), 0);
end $$;

rollback;
