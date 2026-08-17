-- Row level security for the property module, and the two charge
-- engines that raise money out of it.

-- ---------------------------------------------------------------------
-- Row level security
--
-- Three groups, because they gate on three different things:
--
--   spine     — readable and writable by a company holding *either*
--               property module.
--   strata    — `property_strata` only.
--   nonstrata — `property_nonstrata` only.
--
-- Each table gets the pair this schema has used since 0018: a permissive
-- policy that decides whether the row is yours and whether the company
-- is entitled to the module at all, and the restrictive `module_gate_*`
-- layer from 0127 that lets a company's own access types keep a member
-- out of a module they are not meant to be in.
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
  v_group text;
  v_entitled text;
  v_groups constant jsonb := jsonb_build_object(
    'spine', jsonb_build_array(
      'property_sites', 'property_units', 'property_statutory_charges'),
    'property_strata', jsonb_build_array(
      'strata_schemes', 'strata_charge_rates',
      'strata_charge_runs', 'strata_charge_lines'),
    'property_nonstrata', jsonb_build_array(
      'tenancies', 'rent_runs', 'rent_run_lines')
  );
begin
  for v_group in select jsonb_object_keys(v_groups) loop
    -- The spine has no module code of its own; holding either one opens
    -- it. The two extensions gate on themselves.
    v_entitled := case when v_group = 'spine'
      then 'app.has_property_module(org_id)'
      else format('app.has_module(org_id, %L)', v_group) end;

    for v_table in select jsonb_array_elements_text(v_groups -> v_group) loop
      execute format('alter table public.%I enable row level security', v_table);

      execute format(
        'create policy %I on public.%I for select to authenticated
           using (app.is_org_member(org_id) and %s)',
        v_table || '_select', v_table, v_entitled);

      execute format(
        'create policy %I on public.%I for insert to authenticated
           with check (app.can_write(org_id) and %s)',
        v_table || '_insert', v_table, v_entitled);

      execute format(
        'create policy %I on public.%I for update to authenticated
           using (app.can_write(org_id) and %s)
           with check (app.can_write(org_id) and %s)',
        v_table || '_update', v_table, v_entitled, v_entitled);

      execute format(
        'create policy %I on public.%I for delete to authenticated
           using (app.can_write(org_id) and %s)',
        v_table || '_delete', v_table, v_entitled);

      execute format(
        'grant select, insert, update, delete on public.%I to authenticated',
        v_table);

      -- The access-type gate. The spine answers to whichever module the
      -- member does hold, so a strata-only member can still see the
      -- building their parcels are in.
      if v_group = 'spine' then
        execute format(
          'create policy module_gate_select on public.%I
             as restrictive for select to authenticated
             using (app.can_read_module(org_id, ''property_strata'')
                 or app.can_read_module(org_id, ''property_nonstrata''))',
          v_table);
        execute format(
          'create policy module_gate_insert on public.%I
             as restrictive for insert to authenticated
             with check (app.can_write_module(org_id, ''property_strata'')
                      or app.can_write_module(org_id, ''property_nonstrata''))',
          v_table);
        execute format(
          'create policy module_gate_update on public.%I
             as restrictive for update to authenticated
             using (app.can_write_module(org_id, ''property_strata'')
                 or app.can_write_module(org_id, ''property_nonstrata''))
             with check (app.can_write_module(org_id, ''property_strata'')
                      or app.can_write_module(org_id, ''property_nonstrata''))',
          v_table);
        execute format(
          'create policy module_gate_delete on public.%I
             as restrictive for delete to authenticated
             using (app.can_write_module(org_id, ''property_strata'')
                 or app.can_write_module(org_id, ''property_nonstrata''))',
          v_table);
      else
        execute format(
          'create policy module_gate_select on public.%I
             as restrictive for select to authenticated
             using (app.can_read_module(org_id, %L))', v_table, v_group);
        execute format(
          'create policy module_gate_insert on public.%I
             as restrictive for insert to authenticated
             with check (app.can_write_module(org_id, %L))', v_table, v_group);
        execute format(
          'create policy module_gate_update on public.%I
             as restrictive for update to authenticated
             using (app.can_write_module(org_id, %L))
             with check (app.can_write_module(org_id, %L))',
          v_table, v_group, v_group);
        execute format(
          'create policy module_gate_delete on public.%I
             as restrictive for delete to authenticated
             using (app.can_write_module(org_id, %L))', v_table, v_group);
      end if;
    end loop;
  end loop;
end $$;

grant execute on function app.has_property_module(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The rate in force on a date
--
-- The most recent resolution not later than the date. A charge raised
-- for January is raised at January's rate, whatever the AGM has resolved
-- since.
-- ---------------------------------------------------------------------
create or replace function app.strata_rate_on(p_scheme_id uuid, p_on date)
returns public.strata_charge_rates
language sql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
  select * from public.strata_charge_rates
   where scheme_id = p_scheme_id and effective_from <= p_on
   order by effective_from desc
   limit 1;
$$;

-- ---------------------------------------------------------------------
-- What a period is worth, before anything is written
--
-- The screen shows this before the button is pressed, and the test
-- asserts it. Both read the same function, so what an owner is shown is
-- what an owner is billed.
--
-- Months are whole calendar months where the period is whole calendar
-- months, which is the ordinary case: a quarter is 3, not 92/30.4.
-- ---------------------------------------------------------------------
create or replace function app.months_between(p_from date, p_to date)
returns numeric language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case
    -- A whole number of calendar months: the period starts on the first
    -- of a month and ends on the last of one.
    when p_from = date_trunc('month', p_from)::date
     and p_to = (date_trunc('month', p_to) + interval '1 month'
                 - interval '1 day')::date
    then ((extract(year from age(date_trunc('month', p_to)::date,
                                 date_trunc('month', p_from)::date)) * 12
          + extract(month from age(date_trunc('month', p_to)::date,
                                   date_trunc('month', p_from)::date))) + 1)
         ::numeric
    -- Anything else is pro-rated on days against the length of the month
    -- the period starts in.
    else round((p_to - p_from + 1)::numeric
               / extract(day from (date_trunc('month', p_from)
                                   + interval '1 month'
                                   - interval '1 day'))::numeric, 4)
  end;
$$;

create or replace function public.strata_charge_preview(
  p_scheme_id uuid,
  p_period_from date,
  p_period_to date)
returns table (
  unit_id uuid,
  unit_no text,
  owner_contact_id uuid,
  owner_name text,
  share_units numeric,
  maintenance_amount numeric,
  sinking_amount numeric,
  total_amount numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
  v_months numeric;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.is_org_member(s.org_id)
     or not app.has_module(s.org_id, 'property_strata') then
    raise exception 'Not your scheme' using errcode = '42501';
  end if;
  if p_period_to < p_period_from then
    raise exception 'The period ends before it starts' using errcode = '22023';
  end if;

  r := app.strata_rate_on(p_scheme_id, p_period_from);
  if r.id is null then
    raise exception
      'No charge rate is in force on %. An AGM resolution sets the rate per '
      'share unit before charges can be raised.', p_period_from
      using errcode = 'P0002';
  end if;

  v_months := app.months_between(p_period_from, p_period_to);

  return query
    select u.id, u.unit_no, u.owner_contact_id, c.name,
           u.share_units,
           -- The Charges, in proportion to allocated share units. Every
           -- parcel is priced off the same rate, so the ratio between
           -- any two parcels' charges is the ratio of their share units
           -- — which is what the Act requires and what the test asserts.
           round(r.rate_per_share_unit * u.share_units * v_months, 2),
           -- The sinking fund contribution, on top and not out of it.
           round(round(r.rate_per_share_unit * u.share_units * v_months, 2)
                 * r.sinking_fund_percent / 100.0, 2),
           round(r.rate_per_share_unit * u.share_units * v_months, 2)
             + round(round(r.rate_per_share_unit * u.share_units * v_months, 2)
                     * r.sinking_fund_percent / 100.0, 2)
      from public.property_units u
      left join public.contacts c on c.id = u.owner_contact_id
     where u.site_id = s.site_id
       and u.is_active
       and u.is_chargeable
       and u.unit_type = 'parcel'
       and coalesce(u.share_units, 0) > 0
     order by u.unit_no;
end $$;

-- ---------------------------------------------------------------------
-- Raise the Charges
--
-- One invoice per parcel, two lines on it: the Charges and the sinking
-- fund contribution. Two lines rather than one because they are two
-- different funds — the Act requires the sinking fund to be held
-- separately — and an owner asking what they are paying for is entitled
-- to see the split on the invoice rather than in a policy document.
-- ---------------------------------------------------------------------
create or replace function public.raise_strata_charges(
  p_scheme_id uuid,
  p_period_from date,
  p_period_to date,
  p_due_date date default null)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
  v_run uuid;
  v_months numeric;
  v_line record;
  v_invoice uuid;
  v_due date;
  v_parcels integer := 0;
  v_maint numeric(18, 2) := 0;
  v_sink numeric(18, 2) := 0;
  v_maint_ac uuid;
  v_sink_ac uuid;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.can_post(s.org_id) then
    raise exception 'Insufficient privileges to raise charges'
      using errcode = '42501';
  end if;
  if not app.has_module(s.org_id, 'property_strata') then
    raise exception 'The strata module is not switched on for this company'
      using errcode = '42501';
  end if;

  r := app.strata_rate_on(p_scheme_id, p_period_from);
  if r.id is null then
    raise exception
      'No charge rate is in force on %. An AGM resolution sets the rate per '
      'share unit before charges can be raised.', p_period_from
      using errcode = 'P0002';
  end if;

  v_months := app.months_between(p_period_from, p_period_to);
  v_due := coalesce(p_due_date, p_period_from);

  v_maint_ac := app.property_income_account(s.org_id, 'maintenance');
  v_sink_ac := app.property_income_account(s.org_id, 'sinking');

  insert into public.strata_charge_runs
    (org_id, scheme_id, run_no, period_from, period_to, rate_id, months,
     raised_by)
  values (s.org_id, p_scheme_id,
          app.next_document_number_internal(s.org_id, 'strata_charge'),
          p_period_from, p_period_to, r.id, v_months, auth.uid())
  returning id into v_run;

  for v_line in
    select * from public.strata_charge_preview(
      p_scheme_id, p_period_from, p_period_to)
  loop
    if v_line.owner_contact_id is null then
      raise exception
        'Parcel % has no owner on record, so there is nobody to invoice. '
        'Set the owner before raising charges.', v_line.unit_no
        using errcode = '23502';
    end if;

    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      subject, reference, currency, exchange_rate, status)
    values (
      s.org_id, 'invoice',
      app.next_document_number_internal(s.org_id, 'invoice'),
      p_period_from, v_due, v_line.owner_contact_id,
      format('Maintenance charges — %s', v_line.unit_no),
      format('%s to %s', p_period_from, p_period_to),
      app.base_currency(s.org_id), 1, 'draft')
    returning id into v_invoice;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_rate)
    values
      (s.org_id, v_invoice, 1, 'item',
       format('Maintenance charges, %s share units at %s per unit per month',
              v_line.share_units, r.rate_per_share_unit),
       1, v_line.maintenance_amount, v_maint_ac, 0),
      (s.org_id, v_invoice, 2, 'item',
       format('Contribution to the sinking fund at %s%% of the charges',
              r.sinking_fund_percent),
       1, v_line.sinking_amount, v_sink_ac, 0);

    insert into public.strata_charge_lines
      (org_id, run_id, unit_id, share_units, maintenance_amount,
       sinking_amount, invoice_id)
    values (s.org_id, v_run, v_line.unit_id, v_line.share_units,
            v_line.maintenance_amount, v_line.sinking_amount, v_invoice);

    perform app.post_sales_document_internal(v_invoice);

    v_parcels := v_parcels + 1;
    v_maint := v_maint + v_line.maintenance_amount;
    v_sink := v_sink + v_line.sinking_amount;
  end loop;

  if v_parcels = 0 then
    raise exception
      'No parcel in this scheme is chargeable. A parcel needs allocated '
      'share units and an owner before it can be billed.'
      using errcode = 'P0002';
  end if;

  update public.strata_charge_runs
     set parcels = v_parcels, total_maintenance = v_maint, total_sinking = v_sink
   where id = v_run;

  return v_run;
end $$;

-- The income accounts this module needs, created on demand.
--
-- The seeded chart is a trading company's and has no line for any of
-- them. Built the way `app.disposal_account` is, for the same reason
-- that one exists: a posting routine that assumes an account is there
-- fails at the moment somebody is trying to bill four hundred parcels.
--
-- All three are `sales` rather than `other_income`. A management
-- corporation's Charges and a landlord's rent are the turnover of the
-- thing, not something below the line.
create or replace function app.property_income_account(
  p_org_id uuid, p_kind text)
returns uuid language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_id   uuid;
  v_code text := case p_kind
    when 'maintenance' then '4810'
    when 'sinking'     then '4820'
    when 'rent'        then '4830'
    end;
  v_name text := case p_kind
    when 'maintenance' then 'Maintenance Charges'
    when 'sinking'     then 'Sinking Fund Contributions'
    when 'rent'        then 'Rental Income'
    end;
  v_note text := case p_kind
    when 'maintenance' then
      'Charges levied under the SMA 2013 in proportion to allocated share '
      'units.'
    when 'sinking' then
      'Contributions to the sinking fund, at least ten per cent of the '
      'Charges. Held for capital expenditure and not for running costs.'
    when 'rent' then 'Rent receivable under a tenancy.'
    end;
begin
  if v_code is null then
    raise exception 'Unknown property income account "%"', p_kind
      using errcode = '22023';
  end if;

  select id into v_id from public.accounts
   where org_id = p_org_id and code = v_code and deleted_at is null;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts (
    org_id, code, name, description, account_type, account_subtype,
    parent_id, is_group, is_system, is_active, sort_order)
  values (
    p_org_id, v_code, v_name, v_note,
    'revenue'::app.account_type, 'sales'::app.account_subtype,
    (select id from public.accounts
      where org_id = p_org_id and code = '4000' and deleted_at is null),
    false, true, true, v_code::integer)
  returning id into v_id;

  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Arrears, and what the by-laws allow to be charged on them
--
-- Ten per cent per annum, on a daily basis — the ceiling set by the
-- Third Schedule of the Strata Management (Maintenance and Management)
-- Regulations 2015. A scheme may resolve to charge less, and the rate
-- table's check constraint stops it resolving to charge more.
--
-- Simple, not compounding. The by-law provides for a late payment
-- charge on the outstanding sum, not interest on interest.
-- ---------------------------------------------------------------------
create or replace function app.strata_late_interest(
  p_principal numeric,
  p_due_date date,
  p_as_at date,
  p_percent numeric)
returns numeric language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case
    when p_principal is null or p_principal <= 0 then 0
    when p_as_at <= p_due_date then 0
    else round(p_principal * coalesce(p_percent, 0) / 100.0
               * (p_as_at - p_due_date)::numeric / 365.0, 2)
  end;
$$;

create or replace function public.strata_arrears(
  p_scheme_id uuid,
  p_as_at date default current_date)
returns table (
  unit_id uuid,
  unit_no text,
  owner_name text,
  invoice_id uuid,
  doc_no text,
  due_date date,
  outstanding numeric,
  days_overdue integer,
  late_interest numeric,
  total_due numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.is_org_member(s.org_id)
     or not app.has_module(s.org_id, 'property_strata') then
    raise exception 'Not your scheme' using errcode = '42501';
  end if;

  r := app.strata_rate_on(p_scheme_id, p_as_at);

  return query
    select u.id, u.unit_no, c.name, d.id, d.doc_no, d.due_date,
           d.balance_amount,
           greatest(0, (p_as_at - d.due_date))::integer,
           app.strata_late_interest(d.balance_amount, d.due_date, p_as_at,
                                    coalesce(r.late_interest_percent, 0)),
           d.balance_amount
             + app.strata_late_interest(d.balance_amount, d.due_date, p_as_at,
                                        coalesce(r.late_interest_percent, 0))
      from public.strata_charge_lines l
      join public.strata_charge_runs run on run.id = l.run_id
      join public.property_units u on u.id = l.unit_id
      join public.sales_documents d on d.id = l.invoice_id
      left join public.contacts c on c.id = u.owner_contact_id
     where run.scheme_id = p_scheme_id
       and d.status not in ('void', 'draft')
       and d.balance_amount > 0
       and d.deleted_at is null
     order by u.unit_no, d.due_date;
end $$;

-- ---------------------------------------------------------------------
-- Rent
--
-- The non-strata engine. One invoice per tenancy for the period, with
-- the months pro-rated where a tenancy starts or ends inside it — a
-- tenant who moved in on the 15th owes half a month, and billing them
-- for the whole one is the complaint that arrives on day two.
-- ---------------------------------------------------------------------
create or replace function public.rent_preview(
  p_site_id uuid,
  p_period_from date,
  p_period_to date)
returns table (
  tenancy_id uuid,
  tenancy_no text,
  unit_no text,
  tenant_contact_id uuid,
  tenant_name text,
  charge_from date,
  charge_to date,
  months numeric,
  amount numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.property_sites where id = p_site_id;
  if v_org is null then
    raise exception 'No such site' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org)
     or not app.has_module(v_org, 'property_nonstrata') then
    raise exception 'Not your site' using errcode = '42501';
  end if;
  if p_period_to < p_period_from then
    raise exception 'The period ends before it starts' using errcode = '22023';
  end if;

  return query
    select t.id, t.tenancy_no, u.unit_no, t.tenant_contact_id, c.name,
           greatest(t.start_date, p_period_from),
           least(t.end_date, p_period_to),
           app.months_between(greatest(t.start_date, p_period_from),
                              least(t.end_date, p_period_to)),
           round(t.monthly_rent
                 * app.months_between(greatest(t.start_date, p_period_from),
                                      least(t.end_date, p_period_to)), 2)
      from public.tenancies t
      join public.property_units u on u.id = t.unit_id
      left join public.contacts c on c.id = t.tenant_contact_id
     where u.site_id = p_site_id
       and t.status = 'active'
       -- Overlaps the period at all. A tenancy that ended last month is
       -- not billed for this one, and one starting next month is not
       -- billed early.
       and t.start_date <= p_period_to
       and t.end_date >= p_period_from
     order by u.unit_no, t.tenancy_no;
end $$;

create or replace function public.raise_rent_invoices(
  p_site_id uuid,
  p_period_from date,
  p_period_to date,
  p_due_date date default null)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_org uuid;
  v_run uuid;
  v_line record;
  v_invoice uuid;
  v_due date;
  v_count integer := 0;
  v_total numeric(18, 2) := 0;
  v_rent_ac uuid;
begin
  select org_id into v_org from public.property_sites where id = p_site_id;
  if v_org is null then
    raise exception 'No such site' using errcode = 'P0002';
  end if;
  if not app.can_post(v_org) then
    raise exception 'Insufficient privileges to raise invoices'
      using errcode = '42501';
  end if;
  if not app.has_module(v_org, 'property_nonstrata') then
    raise exception
      'The non-strata property module is not switched on for this company'
      using errcode = '42501';
  end if;

  v_due := coalesce(p_due_date, p_period_from);
  v_rent_ac := app.property_income_account(v_org, 'rent');

  insert into public.rent_runs
    (org_id, site_id, run_no, period_from, period_to, raised_by)
  values (v_org, p_site_id,
          app.next_document_number_internal(v_org, 'rent_run'),
          p_period_from, p_period_to, auth.uid())
  returning id into v_run;

  for v_line in
    select * from public.rent_preview(p_site_id, p_period_from, p_period_to)
  loop
    insert into public.sales_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id,
      subject, reference, currency, exchange_rate, status)
    values (
      v_org, 'invoice',
      app.next_document_number_internal(v_org, 'invoice'),
      p_period_from, v_due, v_line.tenant_contact_id,
      format('Rent — %s', v_line.unit_no),
      format('%s to %s', v_line.charge_from, v_line.charge_to),
      app.base_currency(v_org), 1, 'draft')
    returning id into v_invoice;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, account_id, tax_rate)
    values (v_org, v_invoice, 1, 'item',
            format('Rent for %s, %s to %s',
                   v_line.unit_no, v_line.charge_from, v_line.charge_to),
            1, v_line.amount, v_rent_ac, 0);

    insert into public.rent_run_lines
      (org_id, run_id, tenancy_id, months, amount, invoice_id)
    values (v_org, v_run, v_line.tenancy_id, v_line.months, v_line.amount,
            v_invoice);

    perform app.post_sales_document_internal(v_invoice);

    v_count := v_count + 1;
    v_total := v_total + v_line.amount;
  end loop;

  if v_count = 0 then
    raise exception
      'No active tenancy at this site covers % to %.',
      p_period_from, p_period_to using errcode = 'P0002';
  end if;

  update public.rent_runs
     set tenancies = v_count, total_rent = v_total
   where id = v_run;

  return v_run;
end $$;

-- ---------------------------------------------------------------------
-- What the authorities are owed, and when
--
-- Nothing computed: quit rent is a state charge and assessment a local
-- one, both set by rates this system has no business guessing. What it
-- answers is the question a managing agent with forty sites actually
-- has — which bill falls due next, and which one has already been
-- missed.
-- ---------------------------------------------------------------------
create or replace function public.property_statutory_due(
  p_org_id uuid,
  p_within_days integer default 60)
returns table (
  charge_id uuid,
  site_id uuid,
  site_name text,
  kind app.statutory_property_charge,
  authority text,
  account_no text,
  period text,
  amount numeric,
  due_date date,
  days_until integer,
  is_overdue boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id)
     or not app.has_property_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select ch.id, s.id, s.name, ch.kind, ch.authority, ch.account_no,
           case when ch.period_half is null then ch.period_year::text
                else ch.period_year::text || ' H' || ch.period_half::text end,
           ch.amount, ch.due_date,
           (ch.due_date - current_date)::integer,
           ch.due_date < current_date
      from public.property_statutory_charges ch
      join public.property_sites s on s.id = ch.site_id
     where ch.org_id = p_org_id
       and ch.paid_on is null
       and ch.due_date <= current_date + coalesce(p_within_days, 60)
     order by ch.due_date, s.name;
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
grant execute on function public.strata_charge_preview(uuid, date, date)
  to authenticated;
grant execute on function public.raise_strata_charges(uuid, date, date, date)
  to authenticated;
grant execute on function public.strata_arrears(uuid, date) to authenticated;
grant execute on function public.rent_preview(uuid, date, date)
  to authenticated;
grant execute on function public.raise_rent_invoices(uuid, date, date, date)
  to authenticated;
grant execute on function public.property_statutory_due(uuid, integer)
  to authenticated;
