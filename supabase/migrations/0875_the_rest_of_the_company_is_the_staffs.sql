-- =====================================================================
-- iAkauntan :: 0875 the rest of the company is the staff's
--
-- The last domain of `0873`: the corporate register and filings, the
-- property and strata previews, the timesheet report, the member list,
-- the chat links, the AI's tool list, the scan inbox, custom field
-- lookups, a document's approval state -- and two that needed more
-- than the one substitution.
--
-- Measured on 13 October 2026, locally, after `0874`, as an `employee`
-- member with no access type, with the role `authenticated`:
-- `org_team` gave her the member list, all three; `next_document_number`
-- advanced the invoice sequence for her, to INV-2026-00001; and
-- `attachments_of` listed the scan on an invoice she may not open.
--
-- Production held no `employee` member on 13 October.
--
-- As in `0873`, each body below is the live one as `pg_get_functiondef`
-- gave it, with `app.is_staff_member(` in place of `app.is_org_member(`
-- and nothing else changed -- except:
--
--   * `attachments_of` asks `can_read_attachment` of the record, the
--     question the `attachments` table and the bucket already ask. She
--     lists the receipts on her own claim and on nobody's invoice. So
--     does anybody else: a View Only member, who could list an
--     invoice's files and open none of them, lists none now.
--   * `next_document_number` answers anybody in the company for
--     `expense_claim` and `leave_request` -- filing her own claim takes
--     one from the app, and `submit_leave_request` takes one as her --
--     and staff for everything else: an invoice number she burned would
--     be a gap in the company's sequence. The first run of the full
--     suite after this was written found the leave: `request_decisions`
--     files leave as an employee.
--
-- That empties `employee_definers.sql`'s list of what is not yet done.
-- =====================================================================

-- corp_issued_capital: 1 membership check
CREATE OR REPLACE FUNCTION public.corp_issued_capital(p_entity_id uuid)
 RETURNS TABLE(share_class text, shares numeric, consideration numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.corp_entities where id = p_entity_id;
  if v_org is null or not app.is_staff_member(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select sc.name,
         coalesce(sum(case when e.event_type = 'allotment' then e.quantity
                           when e.event_type = 'cancellation' then -e.quantity
                           else 0 end), 0),
         coalesce(sum(case when e.event_type = 'allotment'
                           then e.total_consideration else 0 end), 0)
    from public.corp_share_classes sc
    left join public.corp_share_events e on e.share_class_id = sc.id
   where sc.entity_id = p_entity_id
   group by sc.id, sc.name
   order by sc.name;
end;
$function$;

-- corp_register_of_members: 1 membership check
CREATE OR REPLACE FUNCTION public.corp_register_of_members(p_entity_id uuid)
 RETURNS TABLE(person_id uuid, member_name text, nric text, registration_no text, share_class_id uuid, share_class text, shares numeric, percent numeric, first_acquired date, last_movement date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.corp_entities where id = p_entity_id;
  if v_org is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org) then
    raise exception 'Not a member of organization %', v_org using errcode = '42501';
  end if;

  return query
  with movements as (
    select e.to_person_id as pid, e.share_class_id, e.quantity as qty, e.event_date
      from public.corp_share_events e
     where e.entity_id = p_entity_id and e.to_person_id is not null
    union all
    select e.from_person_id, e.share_class_id, -e.quantity, e.event_date
      from public.corp_share_events e
     where e.entity_id = p_entity_id and e.from_person_id is not null
  ),
  positions as (
    select m.pid, m.share_class_id,
           sum(m.qty) as shares,
           min(m.event_date) filter (where m.qty > 0) as first_acquired,
           max(m.event_date) as last_movement
      from movements m
     group by m.pid, m.share_class_id
    having sum(m.qty) <> 0
  ),
  totals as (
    select p.share_class_id, sum(p.shares) as total from positions p
     group by p.share_class_id
  )
  select p.pid, pr.full_name, pr.nric, pr.registration_no,
         p.share_class_id, sc.name, p.shares,
         round(p.shares * 100.0 / nullif(t.total, 0), 4),
         p.first_acquired, p.last_movement
    from positions p
    join public.corp_persons pr on pr.id = p.pid
    join public.corp_share_classes sc on sc.id = p.share_class_id
    join totals t on t.share_class_id = p.share_class_id
   order by p.shares desc, pr.full_name;
end;
$function$;

-- corp_template_placeholders: 1 membership check
CREATE OR REPLACE FUNCTION public.corp_template_placeholders(p_entity_id uuid, p_template_code text)
 RETURNS TABLE(placeholder text, value text, is_filled boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  e public.corp_entities;
  t public.corp_templates;
  v_values jsonb;
begin
  select * into e from public.corp_entities where id = p_entity_id;
  if e.id is null or not app.is_staff_member(e.org_id) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into t from public.corp_templates
   where code = p_template_code and is_active
     and (org_id = e.org_id or org_id is null)
   order by org_id nulls last limit 1;
  if t.id is null then
    raise exception 'No template %', p_template_code using errcode = 'P0002';
  end if;

  v_values := app.corp_merge_context(p_entity_id);

  return query
  select m.name,
         nullif(v_values ->> m.name, ''),
         coalesce(nullif(v_values ->> m.name, ''), '') <> ''
    from (select distinct (regexp_matches(t.body, '\{\{([a-z0-9_]+)\}\}', 'g'))[1] as name) m
   order by m.name;
end;
$function$;

-- corp_upcoming_filings: 1 membership check
CREATE OR REPLACE FUNCTION public.corp_upcoming_filings(p_org_id uuid, p_within_days integer DEFAULT 120)
 RETURNS TABLE(entity_id uuid, entity_name text, filing_type text, filing_name text, statute_ref text, legacy_form text, trigger_date date, due_date date, period_label text, status app.corp_filing_status, filing_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  -- The Act's dates are Malaysian dates. Named once rather than read
  -- seven times, so every window in this query is bounded by the same
  -- day even if the query runs across midnight.
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;

  return query
  with anniversaries as (
    select e.id, e.name, t.code, t.name as tname, t.statute_ref, t.legacy_form,
           d.trigger_date,
           (d.trigger_date + t.days_allowed)::date as due_date,
           to_char(d.trigger_date, 'YYYY') as period_label,
           t.trigger_kind as kind
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind = 'anniversary'
       and e.entity_type = any (t.applies_to)
      -- Which anniversaries are still outstanding.
      --
      -- The *date* is the Act's: section 68 puts the annual return
      -- thirty days from the anniversary of incorporation, and that
      -- never moves. What was wrong was the *series*: it started one
      -- year back from today, so a company two years behind on its
      -- annual return was shown one filing and told nothing about the
      -- other. A secretary works from the last return lodged, and so
      -- does this now.
      cross join lateral (
        select (e.incorporated_on + (n || ' years')::interval)::date
                 as trigger_date
          from generate_series(
                 -- Every anniversary there has been. The ones already
                 -- lodged are removed further down by the join to
                 -- `corp_filings`, so what is left is precisely what is
                 -- still owed -- including a year skipped in the middle,
                 -- which anchoring on the *last* lodged return would
                 -- hide. See the header.
                 1,
                 extract(year from v_today)::int
                          - extract(year from e.incorporated_on)::int + 1) n) d
     where e.org_id = p_org_id
       and e.incorporated_on is not null
       and e.status in ('incorporated', 'dormant')
       and e.disengaged_on is null
  ),
  year_ends as (
    select e.id, e.name, t.code, t.name as tname, t.statute_ref, t.legacy_form,
           d.trigger_date,
           (d.trigger_date + t.days_allowed)::date as due_date,
           to_char(d.trigger_date, 'YYYY') as period_label,
           t.trigger_kind as kind
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind in ('fye', 'agm')
       and e.entity_type = any (t.applies_to)
      cross join lateral (
        select app.corp_fye(e, y) as trigger_date
          from generate_series(extract(year from v_today)::int - 1,
                               extract(year from v_today)::int) y) d
     where e.org_id = p_org_id
       and e.financial_year_end_month is not null
       and e.status in ('incorporated', 'dormant')
       and e.disengaged_on is null
       and d.trigger_date is not null
       -- Nothing is due for a year the company had not been incorporated for.
       and d.trigger_date >= e.incorporated_on
  ),
  computed as (
    select * from anniversaries union all select * from year_ends
  )
  select c.id, c.name, c.code, c.tname, c.statute_ref, c.legacy_form,
         c.trigger_date, c.due_date, c.period_label,
         coalesce(f.status,
           case when c.due_date < v_today then 'due'
                else 'not_due' end::app.corp_filing_status),
         f.id
    from computed c
    left join public.corp_filings f
      on f.entity_id = c.id and f.filing_type = c.code
     and f.trigger_date = c.trigger_date
   where c.due_date <= v_today + coalesce(p_within_days, 120)
     -- No lower bound on an anniversary filing. Something two years
     -- overdue is not less overdue for being old, and a list that
     -- quietly drops it is how a company finds out from SSM instead.
     -- The other kinds keep the year's window: a financial statement
     -- from four years ago is history, not a task.
     and (c.kind = 'anniversary' or c.due_date >= v_today - 365)
     -- The first Annual Return is only due once there has been an
     -- anniversary at all.
     and c.trigger_date > (select e2.incorporated_on
                             from public.corp_entities e2 where e2.id = c.id)
     and coalesce(f.status, 'due') not in ('lodged', 'approved', 'not_applicable')
   order by c.due_date, c.name;
end;
$function$;

-- fs_deadlines: 1 membership check
CREATE OR REPLACE FUNCTION public.fs_deadlines(p_filing_id uuid)
 RETURNS TABLE(circulate_by date, lodge_by date, outside_limit date, circulated_on date, lodged_on date, days_left integer, is_late boolean, basis text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  f public.fs_filings;
  v_public boolean;
  v_circulate date;
  v_lodge date;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  -- 0607. Was `o.entity_type = 'bhd'`.
  select t.is_public_company into v_public
    from public.organizations o
    join public.entity_types t on t.code = o.entity_type
   where o.id = f.org_id;

  v_circulate := (f.fy_end + interval '6 months')::date;

  -- Thirty days from what actually happened, falling back to thirty days
  -- from the deadline when it has not happened yet. The rule itself is
  -- in `app.fs_lodge_by`, which the nightly notification pass also
  -- calls -- see 0497.
  v_lodge := app.fs_lodge_by(f.fy_end, f.circulated_on);

  return query select
    v_circulate,
    v_lodge,
    (v_circulate + 30)::date,
    f.circulated_on,
    f.lodged_on,
    (v_lodge - app.today())::integer,
    f.lodged_on is null and app.today() > v_lodge,
    case when coalesce(v_public, false)
      then 'CA 2016 s.340 — laid at the AGM within six months of the year '
           'end — and s.259, lodged within thirty days of that meeting.'
      else 'CA 2016 s.258 — circulated to members within six months of the '
           'year end — and s.259, lodged within thirty days of circulation.'
    end;
end $function$;

-- report_fs_deadlines: 1 membership check
CREATE OR REPLACE FUNCTION public.report_fs_deadlines(p_org_id uuid, p_within_days integer DEFAULT 60)
 RETURNS TABLE(filing_id uuid, company text, registration_no text, fy_end date, status app.fs_filing_status, approved_on date, circulated_on date, lodged_on date, circulate_by date, lodge_by date, days_left integer, is_late boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) or not app.has_module(p_org_id, 'mbrs')
  then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select f.id,
           -- The entity when one is named, and the organization's own
           -- name when it is not: a company keeping its own books here
           -- has no `corp_entities` row and its accounts are still its
           -- accounts.
           coalesce(e.name, o.name),
           e.registration_no,
           f.fy_end, f.status,
           f.directors_approval_date, f.circulated_on, f.lodged_on,
           d.circulate_by, d.lodge_by, d.days_left, d.is_late
      from public.fs_filings f
      join public.organizations o on o.id = f.org_id
      left join public.corp_entities e on e.id = f.corp_entity_id
      cross join lateral public.fs_deadlines(f.id) d
     where f.org_id = p_org_id
       and f.status <> 'lodged'
       and d.lodge_by <= app.today() + coalesce(p_within_days, 60)
     order by d.lodge_by, coalesce(e.name, o.name);
end $function$;

-- property_statutory_due: 1 membership check
CREATE OR REPLACE FUNCTION public.property_statutory_due(p_org_id uuid, p_within_days integer DEFAULT 60)
 RETURNS TABLE(charge_id uuid, site_id uuid, site_name text, kind app.statutory_property_charge, authority text, account_no text, period text, amount numeric, due_date date, days_until integer, is_overdue boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id)
     or not app.has_property_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select ch.id, s.id, s.name, ch.kind, ch.authority, ch.account_no,
           case when ch.period_half is null then ch.period_year::text
                else ch.period_year::text || ' H' || ch.period_half::text end,
           ch.amount, ch.due_date,
           (ch.due_date - app.today())::integer,
           ch.due_date < app.today()
      from public.property_statutory_charges ch
      join public.property_sites s on s.id = ch.site_id
     where ch.org_id = p_org_id
       and ch.paid_on is null
       and ch.due_date <= app.today() + coalesce(p_within_days, 60)
     order by ch.due_date, s.name;
end $function$;

-- rent_preview: 1 membership check
CREATE OR REPLACE FUNCTION public.rent_preview(p_site_id uuid, p_period_from date, p_period_to date)
 RETURNS TABLE(tenancy_id uuid, tenancy_no text, unit_no text, tenant_contact_id uuid, tenant_name text, charge_from date, charge_to date, months numeric, amount numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_org uuid;
begin
  select org_id into v_org from public.property_sites where id = p_site_id;
  if v_org is null then
    raise exception 'No such site' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(v_org)
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
end $function$;

-- strata_arrears: 1 membership check
CREATE OR REPLACE FUNCTION public.strata_arrears(p_scheme_id uuid, p_as_at date DEFAULT app.today())
 RETURNS TABLE(unit_id uuid, unit_no text, owner_name text, invoice_id uuid, doc_no text, due_date date, outstanding numeric, days_overdue integer, late_interest numeric, total_due numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(s.org_id)
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
end $function$;

-- strata_charge_preview: 1 membership check
CREATE OR REPLACE FUNCTION public.strata_charge_preview(p_scheme_id uuid, p_period_from date, p_period_to date)
 RETURNS TABLE(unit_id uuid, unit_no text, owner_contact_id uuid, owner_name text, share_units numeric, maintenance_amount numeric, sinking_amount numeric, total_amount numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  s public.strata_schemes;
  r public.strata_charge_rates;
  v_months numeric;
begin
  select * into s from public.strata_schemes where id = p_scheme_id;
  if not found then
    raise exception 'No such strata scheme' using errcode = 'P0002';
  end if;
  if not app.is_staff_member(s.org_id)
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
end $function$;

-- report_statutory_charges: 1 membership check
CREATE OR REPLACE FUNCTION public.report_statutory_charges(p_org_id uuid, p_year integer DEFAULT NULL::integer)
 RETURNS TABLE(charge_id uuid, site_name text, kind app.statutory_property_charge, period text, authority text, account_no text, amount numeric, due_date date, paid_on date, settled_by text, bill_id uuid, bill_no text, reference text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id)
     or not app.has_property_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select ch.id, s.name, ch.kind,
           case when ch.period_half is null then ch.period_year::text
                else ch.period_year::text || ' H'
                     || ch.period_half::text end,
           ch.authority, ch.account_no, ch.amount, ch.due_date, ch.paid_on,
           case when ch.bill_document_id is not null then 'bill'
                when ch.paid_on is not null then 'outside the books'
                else 'unpaid' end,
           ch.bill_document_id, b.doc_no, ch.reference
      from public.property_statutory_charges ch
      join public.property_sites s on s.id = ch.site_id
      left join public.purchase_documents b on b.id = ch.bill_document_id
     where ch.org_id = p_org_id
       and (p_year is null or ch.period_year = p_year)
     order by ch.period_year desc, s.name, ch.kind, ch.period_half;
end $function$;

-- report_timesheet: 1 membership check
CREATE OR REPLACE FUNCTION public.report_timesheet(p_org_id uuid, p_from date, p_to date)
 RETURNS TABLE(user_id uuid, who text, billable_hours numeric, non_billable_hours numeric, utilisation_percent numeric, billed_amount numeric, unbilled_amount numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_staff_member(p_org_id) or not app.has_time_module(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select t.user_id,
           coalesce(p.full_name, p.email, 'Unknown'),
           round(sum(t.minutes) filter (where t.is_billable)::numeric
                 / 60.0, 2),
           round(sum(t.minutes) filter (where not t.is_billable)::numeric
                 / 60.0, 2),
           -- Billable as a share of everything recorded. Nothing
           -- recorded is nothing to divide by, and 0/0 is not 0% — it is
           -- "this person did not fill in a timesheet", which is a
           -- different thing to say.
           case when coalesce(sum(t.minutes), 0) = 0 then null
                else round(100.0
                  * coalesce(sum(t.minutes) filter (where t.is_billable), 0)
                  / sum(t.minutes), 1) end,
           coalesce(sum(t.amount) filter (where t.is_billed), 0),
           coalesce(sum(t.amount) filter
                    (where t.is_billable and not t.is_billed), 0)
      from public.time_entries t
      left join public.profiles p on p.id = t.user_id
     where t.org_id = p_org_id
       and t.entry_date between p_from and p_to
     group by t.user_id, p.full_name, p.email
     order by 2;
end $function$;

-- org_team: 1 membership check
CREATE OR REPLACE FUNCTION public.org_team(p_org_id uuid)
 RETURNS TABLE(member_id uuid, user_id uuid, email text, full_name text, role app.member_role, status app.member_status, invited_email text, joined_at timestamp with time zone, created_at timestamp with time zone, access_type_id uuid, access_type_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select m.id, m.user_id, coalesce(p.email::text, m.invited_email::text),
         p.full_name, m.role, m.status, m.invited_email::text,
         m.joined_at, m.created_at,
         m.access_type_id, a.name
    from public.org_members m
    left join public.profiles p on p.id = m.user_id
    left join public.access_types a on a.id = m.access_type_id
   where m.org_id = p_org_id
     and app.is_staff_member(p_org_id)
   order by m.created_at;
$function$;

-- chat_links_for: 1 membership check
CREATE OR REPLACE FUNCTION public.chat_links_for(p_org_id uuid)
 RETURNS TABLE(id uuid, other_org_id uuid, other_org_name text, kind text, status text, we_asked boolean, awaiting_us boolean, note text, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select l.id,
         case when l.org_a = p_org_id then l.org_b else l.org_a end,
         o.name,
         l.kind::text,
         l.status::text,
         l.requested_by_org = p_org_id,
         l.status = 'pending' and l.requested_by_org <> p_org_id,
         l.note,
         l.created_at
    from public.chat_links l
    join public.organizations o
      on o.id = case when l.org_a = p_org_id then l.org_b else l.org_a end
   where (l.org_a = p_org_id or l.org_b = p_org_id)
     and app.is_staff_member(p_org_id)
   order by (l.status = 'pending') desc, l.created_at desc;
$function$;

-- ai_tool_catalogue: 1 membership check
CREATE OR REPLACE FUNCTION public.ai_tool_catalogue(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', t.name,
           'description', t.description,
           'arguments', t.arguments) order by t.name), '[]'::jsonb)
    from public.ai_tools t
   where t.is_active
     and app.is_staff_member(p_org_id)
     and app.has_module(p_org_id, 'ai');
$function$;

-- scan_inbox: 2 membership checks
CREATE OR REPLACE FUNCTION public.scan_inbox(p_org_id uuid, p_limit integer DEFAULT 100, p_only text DEFAULT 'all'::text)
 RETURNS TABLE(scan_id uuid, attachment_id uuid, file_name text, storage_path text, mime_type text, scanned_at timestamp with time zone, provider text, status text, error text, log_ref text, document_kind text, kind_label text, target text, posted_table text, posted_id uuid, posted_at timestamp with time zone, posted_label text, posted_date date, reviewed_at timestamp with time zone, corrected boolean, readings integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  select s.id,
         s.attachment_id,
         -- The attachment's name, falling back to the object's. A
         -- document deleted later takes its attachment with it --
         -- `delete_attachments_of_row` -- and `ocr_scans.attachment_id`
         -- is `on delete set null`, so the scan survives with nothing
         -- to name it. `storage_path` is on the SCAN, so the last
         -- segment is still the file somebody photographed.
         coalesce(a.file_name,
                  nullif(split_part(s.storage_path, '/', -1), '')),
         -- The LIVE key, not the one the reader was handed. `0697`.
         -- `refileAttachment` moves the object onto the record once
         -- that record exists and updates the ATTACHMENT's path; the
         -- scan keeps the placeholder key it was read under. So the
         -- scan's own path is a historical note, and opening it 404s
         -- for every scan that became something -- which was every
         -- scan that worked.
         coalesce(a.storage_path, s.storage_path),
         a.mime_type,
         s.created_at,
         s.provider,
         s.status,
         s.error,
         s.log_ref,
         s.document_kind,
         k.label,
         s.extracted ->> 'target',
         s.posted_table,
         s.posted_id,
         s.posted_at,
         -- One left join per destination, and a null label where the
         -- record has since been deleted: "this became a bill that no
         -- longer exists" is the answer, and dropping the row would
         -- read as a scan that never happened.
         case s.posted_table
           when 'sales_documents'    then sd.doc_no
           when 'purchase_documents' then pd.doc_no
           when 'expenses'           then e.expense_no
           when 'contacts'           then c.name
           when 'bank_transactions'  then 'Statement lines'
           else null
         end,
         case s.posted_table
           when 'sales_documents'    then sd.doc_date
           when 'purchase_documents' then pd.doc_date
           when 'expenses'           then e.expense_date
           else null
         end,
         s.reviewed_at,
         s.corrected is not null,
         greatest(s.readings, 1)
    from (
           -- One per sheet of paper. `distinct on` needs the group in
           -- front of its own ORDER BY, so the choice is made here and
           -- the list's own ordering happens at the bottom.
           --
           -- A scan with no attachment left cannot be grouped with
           -- anything -- `0702` nulls it when the document goes -- so
           -- it is grouped by its own id, which is to say not at all.
           select distinct on (coalesce(s2.attachment_id::text, s2.id::text))
                  s2.*,
                  (select count(*)::integer from public.ocr_scans s3
                    where s3.attachment_id is not null
                      and s3.attachment_id = s2.attachment_id) as readings
             from public.ocr_scans s2
            where s2.org_id = p_org_id
            order by coalesce(s2.attachment_id::text, s2.id::text),
                     -- What it BECAME outranks what was last asked of
                     -- it: a sheet read into a bill and then re-read
                     -- would otherwise lose the bill off the list.
                     (s2.posted_table is not null) desc,
                     s2.created_at desc
         ) s
    left join public.attachments a on a.id = s.attachment_id
    left join public.scan_document_kinds k on k.code = s.document_kind
    left join public.sales_documents sd
           on s.posted_table = 'sales_documents' and sd.id = s.posted_id
    left join public.purchase_documents pd
           on s.posted_table = 'purchase_documents' and pd.id = s.posted_id
    left join public.expenses e
           on s.posted_table = 'expenses' and e.id = s.posted_id
    left join public.contacts c
           on s.posted_table = 'contacts' and c.id = s.posted_id
   where s.org_id = p_org_id
     and app.is_staff_member(p_org_id)
     and case p_only
           when 'posted'   then s.posted_table is not null
           when 'unposted' then s.posted_table is null
           else true
         end
   union all

  -- A file kept and not read. `0714`.
  --
  -- Every column the scan half fills from `ocr_scans` is NULL here, and
  -- deliberately: there is no scan, no provider, no status and nothing
  -- was charged. `scanned_at` is `kept_at`, so it sorts into the pile
  -- at the moment somebody put it there.
  select null::uuid,
         a.id,
         a.file_name,
         a.storage_path,
         a.mime_type,
         a.kept_at,
         null::text, null::text, null::text, null::text, null::text,
         null::text, null::text,
         null::text, null::uuid, null::timestamptz, null::text,
         null::date,
         null::timestamptz,
         false,
         0
    from public.attachments a
   where a.org_id = p_org_id
     and a.kept_at is not null
     and app.is_staff_member(p_org_id)
     -- Read since, and the scan row is the better record of it. Both
     -- would put one sheet of paper in the list twice.
     and not exists (select 1 from public.ocr_scans s2
                      where s2.attachment_id = a.id)
     -- A kept file has become nothing by definition, so it belongs
     -- under `unposted` and never under `posted`.
     and p_only is distinct from 'posted'

   order by 6 desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$function$;

-- document_scan_totals: 1 membership check
CREATE OR REPLACE FUNCTION public.document_scan_totals(p_org_id uuid, p_table text, p_record_id uuid)
 RETURNS TABLE(scan_id uuid, read_at timestamp with time zone, file_name text, subtotal numeric, tax_amount numeric, total numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select s.id,
         coalesce(s.finished_at, s.created_at),
         a.file_name,
         -- `jsonb` to numeric through text, because a figure the reader
         -- returned as a JSON number and one it returned as a string
         -- are the same figure to everybody except a cast.
         nullif(s.extracted ->> 'subtotal', '')::numeric,
         nullif(s.extracted ->> 'tax_amount', '')::numeric,
         nullif(s.extracted ->> 'total_amount', '')::numeric
    from public.ocr_scans s
    join public.attachments a
      on a.id = s.attachment_id and a.org_id = s.org_id
   where app.is_staff_member(p_org_id)
     and s.org_id = p_org_id
     and a.entity_table = p_table
     and a.entity_id = p_record_id
     and s.status = 'ok'
     and s.extracted is not null
   -- The newest reading wins. A document read twice -- which `0698`
   -- made ordinary -- is described by what the second reader said, not
   -- by whatever the first one got wrong.
   order by coalesce(s.finished_at, s.created_at) desc
   limit 1;
$function$;

-- custom_field_lookup_options: 1 membership check
CREATE OR REPLACE FUNCTION public.custom_field_lookup_options(p_org_id uuid, p_target_entity text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_ent public.custom_field_entities;
begin
  if not app.is_staff_member(p_org_id) then
    raise exception 'not a member of this company' using errcode = '42501';
  end if;
  select * into v_ent from public.custom_field_entities
   where entity = p_target_entity;
  if v_ent.entity is null or not v_ent.can_target then
    raise exception 'Nothing points at a %.', coalesce(p_target_entity, 'nothing')
      using errcode = 'P0002';
  end if;

  return query execute format(
    'select t.id, t.%I::text from public.%I t'
    ' where t.org_id = $1 %s'
    '   and ($2 is null or t.%I::text ilike ''%%'' || $2 || ''%%'')'
    ' order by t.%I limit $3',
    v_ent.label_column, v_ent.table_name,
    case when v_ent.deleted_column is null then ''
         else format('and t.%I is null', v_ent.deleted_column) end,
    v_ent.label_column, v_ent.label_column)
    using p_org_id, nullif(btrim(coalesce(p_search, '')), ''),
          greatest(coalesce(p_limit, 50), 1);
end;
$function$;

-- approval_state: 1 membership check
CREATE OR REPLACE FUNCTION public.approval_state(p_kind app.approval_entity, p_entity_id uuid)
 RETURNS TABLE(is_required boolean, is_approved boolean, request_id uuid, request_status app.approval_status, awaiting_step smallint, awaiting_who text, awaiting_me boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid;
  v_type text;
  v_amount numeric;
begin
  if p_kind = 'sales_document' then
    select d.org_id, d.doc_type::text, d.total_amount
      into v_org, v_type, v_amount
      from public.sales_documents d where d.id = p_entity_id;
  elsif p_kind = 'purchase_document' then
    select d.org_id, d.doc_type::text, d.total_amount
      into v_org, v_type, v_amount
      from public.purchase_documents d where d.id = p_entity_id;
  else
    select e.org_id, e.source::text,
           (select coalesce(sum(l.debit), 0) from public.gl_lines l
             where l.entry_id = e.id)
      into v_org, v_type, v_amount
      from public.gl_entries e where e.id = p_entity_id;
  end if;

  -- A document nobody may see is not a document that needs approving.
  -- Returning no row rather than raising: the editor asks this on every
  -- load, and an exception on a row the caller cannot read would turn a
  -- permission answer into an error banner.
  if v_org is null or not app.is_staff_member(v_org) then
    return;
  end if;

  return query
    select
      app.approval_required(v_org, p_kind, v_type, v_amount),
      app.is_approved(v_org, p_kind, p_entity_id),
      q.id,
      q.status,
      s.step_no,
      coalesce(
        (select coalesce(pr.full_name, pr.email) from public.profiles pr
          where pr.id = s.approver_user_id),
        case when s.approver_role is null then null
             else 'an ' || replace(s.approver_role::text, '_', ' ') end),
      coalesce(s.approver_user_id = auth.uid()
               or (s.approver_user_id is null
                   and app.has_org_role(v_org, array[s.approver_role])),
               false)
        -- Nobody signs their own, so it is never waiting on the raiser
        -- even when they hold the role. `decide_approval` refuses it and
        -- `my_approvals` hides it; a button that offered it here would
        -- be a button that fails.
        and q.requested_by is distinct from auth.uid()
      from (select 1) one
      left join public.approval_requests q
        on q.org_id = v_org and q.entity_kind = p_kind
       and q.entity_id = p_entity_id and q.status = 'pending'
      left join lateral (
        select s2.* from public.approval_steps s2
         where s2.request_id = q.id and s2.status = 'pending'
         order by s2.step_no limit 1) s on true;
end $function$;

-- attachments_of: the record's own question, not the company's
CREATE OR REPLACE FUNCTION public.attachments_of(p_org_id uuid, p_table text, p_record_id uuid)
 RETURNS TABLE(id uuid, file_name text, storage_path text, mime_type text, file_size bigint, created_at timestamp with time zone, is_evidence boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select a.id, a.file_name, a.storage_path, a.mime_type,
         a.file_size::bigint, a.created_at,
         app.attachment_is_evidence(a.id)
    from public.attachments a
   -- 0875. The question the table and the bucket already ask of this
   -- record, rather than whether the caller is in the company at all:
   -- an employee lists the receipts on her own claim and nobody's
   -- invoice, and nobody lists what they could not open.
   where app.can_read_attachment(p_org_id, p_table, p_record_id)
     and a.org_id = p_org_id
     and a.entity_table = p_table
     and a.entity_id = p_record_id
   order by a.created_at desc;
$function$;

-- next_document_number: staff, or a claim's or leave's number for anybody in the company
CREATE OR REPLACE FUNCTION public.next_document_number(p_org_id uuid, p_doc_type text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
begin
  -- 0875. Filing her own claim takes a number, and so does her leave
  -- (`submit_leave_request` asks as her), and those are the only
  -- counters self-service may advance: an invoice number she burned
  -- would be a gap in the company's sequence.
  if not (app.is_staff_member(p_org_id)
          or (p_doc_type in ('expense_claim', 'leave_request')
              and app.is_org_member(p_org_id))) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;
  return app.next_document_number_internal(p_org_id, p_doc_type);
end; $function$;
