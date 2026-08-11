-- =====================================================================
-- iAkauntan :: 0063 the deadlines SSM actually imposes
--
-- A secretarial firm's whole risk is a missed date, so none of these
-- are typed in. Each is computed from the company's own incorporation
-- date or year end against the section that imposes it.
-- =====================================================================

insert into public.corp_filing_types
  (code, name, statute_ref, legacy_form, trigger_kind, days_allowed, applies_to,
   description, sort_order)
values
  ('annual_return', 'Annual Return', 'CA 2016 s.68', 'Form 24 / AR',
   'anniversary', 30,
   array['sdn_bhd','berhad','clbg','foreign']::app.corp_entity_type[],
   'Lodged within 30 days of the anniversary of incorporation. Note this '
   'runs from the incorporation date, not the financial year end — the '
   'single most common reason a company is late.', 10),

  ('financial_statements', 'Financial statements and reports',
   'CA 2016 s.258 and s.259', null, 'fye', 210,
   array['sdn_bhd','clbg']::app.corp_entity_type[],
   'A private company circulates to members within six months of the '
   'financial year end (s.258) and lodges within thirty days of '
   'circulation (s.259) — 180 + 30 days at the outside.', 20),

  ('financial_statements_public', 'Financial statements laid at AGM',
   'CA 2016 s.340 and s.259', null, 'fye', 210,
   array['berhad']::app.corp_entity_type[],
   'A public company lays its accounts at the AGM within six months of '
   'the year end and lodges within thirty days of that meeting.', 25),

  ('agm', 'Annual general meeting', 'CA 2016 s.340', null, 'fye', 180,
   array['berhad','clbg']::app.corp_entity_type[],
   'Public companies only. The 2016 Act removed the requirement for a '
   'private company to hold an AGM at all.', 30),

  ('change_of_officers', 'Change in particulars of officers',
   'CA 2016 s.58', 'Form 49', 'event', 14,
   array['sdn_bhd','berhad','clbg','foreign']::app.corp_entity_type[],
   'Appointment, resignation or change of particulars of a director, '
   'manager or secretary — fourteen days.', 40),

  ('change_registered_office', 'Change of registered office',
   'CA 2016 s.46(3)', 'Form 44', 'event', 14,
   array['sdn_bhd','berhad','clbg','foreign']::app.corp_entity_type[],
   'Fourteen days from the change taking effect.', 50),

  ('return_of_allotment', 'Return of allotment of shares',
   'CA 2016 s.78', 'Form 24', 'event', 14,
   array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
   'Fourteen days from the allotment.', 60),

  ('register_of_charges', 'Registration of a charge',
   'CA 2016 s.352', 'Form 34', 'event', 30,
   array['sdn_bhd','berhad','clbg','foreign']::app.corp_entity_type[],
   'Thirty days from creation of the charge. Miss it and the charge is '
   'void against the liquidator.', 70),

  ('beneficial_ownership', 'Beneficial ownership notification',
   'CA 2016 s.60B', null, 'event', 14,
   array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
   'In force since 1 April 2024. Fourteen days from the company '
   'obtaining the information.', 80),

  ('change_of_name', 'Change of company name', 'CA 2016 s.28', 'Form 11',
   'event', 14, array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
   'Lodged with the special resolution approving it.', 90),

  ('appointment_of_auditor', 'Appointment of auditor', 'CA 2016 s.271',
   null, 'event', 30, array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
   'Not required of a company that qualifies for audit exemption under '
   'the Registrar''s practice directive.', 100)
on conflict (code) do update set
  name = excluded.name, statute_ref = excluded.statute_ref,
  legacy_form = excluded.legacy_form, trigger_kind = excluded.trigger_kind,
  days_allowed = excluded.days_allowed, applies_to = excluded.applies_to,
  description = excluded.description, sort_order = excluded.sort_order;


-- The financial year end as a date in a given year, tolerant of a
-- 31 February typed by somebody in a hurry.
create or replace function app.corp_fye(p_entity public.corp_entities, p_year integer)
returns date
language sql immutable
set search_path = pg_catalog, public, pg_temp as $$
  select case
    when p_entity.financial_year_end_month is null then null
    else least(
      make_date(p_year, p_entity.financial_year_end_month,
                least(coalesce(p_entity.financial_year_end_day, 31),
                      extract(day from (
                        date_trunc('month',
                          make_date(p_year, p_entity.financial_year_end_month, 1))
                        + interval '1 month - 1 day'))::integer)),
      make_date(p_year, 12, 31))
  end;
$$;

-- The recurring obligations, computed. Nothing is stored until a filing
-- is actually opened, so a change to the rules shows up immediately
-- rather than in whatever was written down last year.
--
-- The anniversary is done with interval arithmetic rather than by
-- rebuilding the date from parts: clamping the day to dodge 29 February
-- quietly moves every company incorporated after the 28th of a month
-- two or three days early, and a statutory date that is wrong in the
-- safe direction is still wrong.
create or replace function public.corp_upcoming_filings(
  p_org_id uuid, p_within_days integer default 120)
returns table (
  entity_id uuid,
  entity_name text,
  filing_type text,
  filing_name text,
  statute_ref text,
  legacy_form text,
  trigger_date date,
  due_date date,
  period_label text,
  status app.corp_filing_status,
  filing_id uuid)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id using errcode = '42501';
  end if;

  return query
  with anniversaries as (
    select e.id, e.name, t.code, t.name as tname, t.statute_ref, t.legacy_form,
           d.trigger_date,
           (d.trigger_date + t.days_allowed)::date as due_date,
           to_char(d.trigger_date, 'YYYY') as period_label
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind = 'anniversary'
       and e.entity_type = any (t.applies_to)
      cross join lateral (
        select (e.incorporated_on + (n || ' years')::interval)::date as trigger_date
          from generate_series(
                 greatest(extract(year from current_date)::int
                          - extract(year from e.incorporated_on)::int - 1, 0),
                 extract(year from current_date)::int
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
           to_char(d.trigger_date, 'YYYY') as period_label
      from public.corp_entities e
      join public.corp_filing_types t on t.trigger_kind in ('fye', 'agm')
       and e.entity_type = any (t.applies_to)
      cross join lateral (
        select app.corp_fye(e, y) as trigger_date
          from generate_series(extract(year from current_date)::int - 1,
                               extract(year from current_date)::int) y) d
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
           case when c.due_date < current_date then 'due'
                else 'not_due' end::app.corp_filing_status),
         f.id
    from computed c
    left join public.corp_filings f
      on f.entity_id = c.id and f.filing_type = c.code
     and f.trigger_date = c.trigger_date
   where c.due_date between current_date - 365
                        and current_date + coalesce(p_within_days, 120)
     -- The first Annual Return is only due once there has been an
     -- anniversary at all.
     and c.trigger_date > (select e2.incorporated_on
                             from public.corp_entities e2 where e2.id = c.id)
     and coalesce(f.status, 'due') not in ('lodged', 'approved', 'not_applicable')
   order by c.due_date, c.name;
end;
$$;

-- Opening a filing freezes the computed obligation into a row that can
-- be worked on, so the dashboard and the file agree.
create or replace function public.corp_open_filing(
  p_entity_id uuid, p_filing_type text, p_trigger_date date)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_entity public.corp_entities;
  v_type public.corp_filing_types;
  v_id uuid;
begin
  select * into v_entity from public.corp_entities where id = p_entity_id;
  if v_entity.id is null then
    raise exception 'Entity not found' using errcode = 'P0002';
  end if;
  if not app.can_write(v_entity.org_id) then
    raise exception 'Not permitted to open a filing' using errcode = '42501';
  end if;

  select * into v_type from public.corp_filing_types where code = p_filing_type;
  if v_type.code is null then
    raise exception 'Unknown filing type %', p_filing_type using errcode = '22023';
  end if;
  -- An AGM filing against a Sdn Bhd is not a typo to be tidied later; it
  -- is a company being told to do something the Act does not require.
  if not (v_entity.entity_type = any (v_type.applies_to)) then
    raise exception '% does not apply to a %', v_type.name, v_entity.entity_type
      using errcode = '22023';
  end if;

  insert into public.corp_filings
    (org_id, entity_id, filing_type, trigger_date, due_date, status)
  values (v_entity.org_id, p_entity_id, p_filing_type, p_trigger_date,
          (p_trigger_date + coalesce(v_type.days_allowed, 30))::date,
          'in_preparation')
  on conflict (entity_id, filing_type, trigger_date)
    do update set status = case
      when public.corp_filings.status in ('lodged', 'approved')
        then public.corp_filings.status
      else 'in_preparation' end
  returning id into v_id;

  return v_id;
end;
$$;
