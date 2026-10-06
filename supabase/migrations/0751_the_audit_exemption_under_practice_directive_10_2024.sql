-- =====================================================================
-- 0751 :: the audit exemption under Practice Directive 10/2024
--
-- `fs_audit_exemption` (0172) tested the threshold ground under Practice
-- Directive 3/2018: revenue not above RM100,000, total assets not above
-- RM300,000 and no more than five employees, ALL THREE, in the current
-- financial year and the two before it.
--
-- SSM's Practice Directive 10/2024 (announced 16 December 2024) replaced
-- that ground for financial years commencing on or after 1 January
-- 2025: a private company qualifies if it meets ANY TWO of the three,
-- with the limits phased in --
--
--     FY commencing in 2025          RM1,000,000   RM1,000,000   10
--     FY commencing in 2026          RM2,000,000   RM2,000,000   20
--     FY commencing 2027 onwards     RM3,000,000   RM3,000,000   30
--
-- -- each tested over the current year and the two before it. Every
-- filing in production when this was written (seven) commenced in 2025
-- or later, so every one was being tested against a rule that no longer
-- governed it. The old test is strictly harder than the new one, so the
-- error ran one way: a company inside the new limits was told an audit
-- was required.
--
-- What is an interpretation, and should be checked against the
-- directive's own text (asked of the user, 6 October; a firm's
-- commentary on the transition could not be read from here):
--
--   * the phase is chosen by when the financial year being filed
--     COMMENCED, and the same limits are applied to its two preceding
--     years;
--   * the dormant and zero-revenue grounds are unchanged -- the
--     directive is about the threshold ground.
--
-- Years commencing before 2025 keep PD 3/2018's test exactly.
-- =====================================================================

-- The limits, by the commencement of the financial year. One place, so
-- the screen, the test and the next phase are one edit.
create or replace function app.audit_exemption_thresholds(p_fy_start date)
returns table (directive text, revenue numeric, assets numeric,
               staff integer, any_two boolean)
language sql
immutable
set search_path = pg_catalog
as $$
  select * from (values
    ('Practice Directive 3/2018',  100000::numeric,  300000::numeric,  5, false),
    ('Practice Directive 10/2024', 1000000::numeric, 1000000::numeric, 10, true),
    ('Practice Directive 10/2024', 2000000::numeric, 2000000::numeric, 20, true),
    ('Practice Directive 10/2024', 3000000::numeric, 3000000::numeric, 30, true))
    as v(directive, revenue, assets, staff, any_two)
  offset case when p_fy_start < date '2025-01-01' then 0
              when p_fy_start < date '2026-01-01' then 1
              when p_fy_start < date '2027-01-01' then 2
              else 3 end
  limit 1;
$$;

revoke all on function app.audit_exemption_thresholds(date) from public, anon;
grant execute on function app.audit_exemption_thresholds(date) to authenticated;

-- RM1,000,000, the way the directive writes it.
create or replace function app.ringgit(p_amount numeric)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select 'RM' || to_char(p_amount, 'FM999,999,999,990');
$$;

revoke all on function app.ringgit(numeric) from public, anon;
grant execute on function app.ringgit(numeric) to authenticated;

create or replace function public.fs_audit_exemption(p_filing_id uuid)
returns table (ground text, qualifies boolean, reason text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_start date; v_end date;
  v_rev numeric; v_assets numeric; v_staff integer;
  v_max_rev numeric := 0; v_max_assets numeric := 0; v_max_staff integer := 0;
  v_any_movement boolean := false;
  v_staff_known boolean := true;
  i integer;
  t record;
  v_rev_ok boolean; v_assets_ok boolean; v_staff_ok boolean;
  v_met integer;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  -- This year and the two before it.
  for i in 0..2 loop
    v_start := (f.fy_start - (i || ' years')::interval)::date;
    v_end := (f.fy_end - (i || ' years')::interval)::date;

    select coalesce(sum(p.amount), 0) into v_rev
      from public.report_profit_loss(f.org_id, v_start, v_end) p
     where p.account_type = 'revenue';

    select coalesce(sum(b.balance), 0) into v_assets
      from public.report_balance_sheet(f.org_id, v_end) b
     where b.account_type = 'asset';

    -- Dormancy is about *any* accounting transaction, not about revenue.
    -- A company that paid a filing fee out of its bank account had a
    -- transaction and is not dormant.
    if exists (select 1 from public.gl_entries e
                where e.org_id = f.org_id and e.status = 'posted'
                  and e.entry_date between v_start and v_end) then
      v_any_movement := true;
    end if;

    -- Headcount comes off each year's own filing row. Guessing it from
    -- today's employee list would answer a question about 2023 with a
    -- fact about 2026.
    select g.employee_count into v_staff
      from public.fs_filings g
     where g.org_id = f.org_id and g.fy_end = v_end;
    if v_staff is null then v_staff_known := false;
                       else v_max_staff := greatest(v_max_staff, v_staff);
    end if;

    v_max_rev := greatest(v_max_rev, v_rev);
    v_max_assets := greatest(v_max_assets, v_assets);
  end loop;

  -- 0751. Which directive governs is decided by when the financial year
  -- being filed COMMENCED, and the same limits are applied to all three
  -- years: the test is whether the company stayed within them for the
  -- current year and the two before it.
  select * into t from app.audit_exemption_thresholds(f.fy_start);
  v_rev_ok    := v_max_rev <= t.revenue;
  v_assets_ok := v_max_assets <= t.assets;
  v_staff_ok  := v_staff_known and v_max_staff <= t.staff;
  v_met := v_rev_ok::integer + v_assets_ok::integer + v_staff_ok::integer;

  return query values
    ('dormant',
     not v_any_movement,
     case when not v_any_movement
       then 'No accounting transaction in this financial year or the two '
            'before it.'
       else 'There were accounting transactions in the three years to '
            || f.fy_end || '.' end),

    ('zero_revenue',
     v_max_rev = 0 and v_max_assets <= 300000,
     case when v_max_rev = 0 and v_max_assets <= 300000
       then 'No revenue in any of the three years, and total assets never '
            'above RM300,000.'
       when v_max_rev > 0
       then 'Revenue reached ' || to_char(v_max_rev, 'FM999,999,999.00')
            || ' in one of the three years.'
       else 'Total assets reached '
            || to_char(v_max_assets, 'FM999,999,999.00')
            || ', above the RM300,000 ceiling.' end),

    ('threshold_qualified',
     case when t.any_two then v_met >= 2
          else v_staff_known and v_rev_ok and v_assets_ok and v_staff_ok end,
     case
       -- Practice Directive 10/2024: any two of the three.
       when t.any_two and v_met >= 2
       then 'Within ' || v_met || ' of the three limits of ' || t.directive
            || ' in each of the three years -- '
            || array_to_string(array_remove(array[
                 case when v_rev_ok then 'revenue under '
                      || app.ringgit(t.revenue) end,
                 case when v_assets_ok then 'total assets under '
                      || app.ringgit(t.assets) end,
                 case when v_staff_ok then 'headcount under '
                      || (t.staff + 1) end], null), ', ')
            || '. Two are enough.'
       -- The headcount is missing and it is the one that would decide.
       when t.any_two and not v_staff_known and v_met = 1
       then 'Cannot tell -- one of revenue and total assets is within '
            || t.directive || '''s limits, and the headcount at the year '
            'end, which would decide it, is missing on one of the three '
            'years. Record it on each filing.'
       when t.any_two
       then 'Within ' || v_met || ' of the three limits of ' || t.directive
            || ', and it takes two -- '
            || array_to_string(array_remove(array[
                 case when not v_rev_ok then 'revenue reached '
                      || app.ringgit(v_max_rev) || ' against '
                      || app.ringgit(t.revenue) end,
                 case when not v_assets_ok then 'total assets reached '
                      || app.ringgit(v_max_assets) || ' against '
                      || app.ringgit(t.assets) end,
                 case when not v_staff_known then 'the headcount is missing '
                      'on one of the three years'
                      when not v_staff_ok then 'headcount reached '
                      || v_max_staff || ' against ' || t.staff end], null), '; ')
            || '.'
       -- Practice Directive 3/2018: all three, as before 0751 -- except
       -- that a ceiling already crossed is said before "cannot tell".
       -- Under an all-three rule a revenue over RM100,000 decides it
       -- whatever the headcount was, and 0172 answered "cannot tell" to
       -- a question it could answer.
       when v_max_rev > t.revenue
       then 'Revenue reached ' || to_char(v_max_rev, 'FM999,999,999.00')
            || ', above the RM100,000 ceiling.'
       when v_max_assets > t.assets
       then 'Total assets reached '
            || to_char(v_max_assets, 'FM999,999,999.00')
            || ', above the RM300,000 ceiling.'
       when not v_staff_known
       then 'Cannot tell — the headcount at the year end is missing on '
            'one of the three years. Record it on each filing.'
       when v_max_staff > t.staff
       then 'Headcount reached ' || v_max_staff || ', above the five '
            'employee ceiling.'
       else 'Revenue, total assets and headcount were all within the '
            'thresholds in each of the three years.' end);
end $$;
