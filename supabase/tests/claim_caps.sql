-- =====================================================================
-- iAkauntan :: the claim cap that was only a number
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/claim_caps.sql
--
-- `claim_types.per_claim_cap`, `monthly_cap` and `annual_cap` have
-- existed since `0027`. The HR setup screen offers two of them and
-- prints "up to RM 200" beside the type. No SQL had ever read any of
-- the three.
--
-- That is worse than a column nothing reads. A screen showing a limit
-- is a promise, and a company that sets one believes claims above it
-- will be stopped. None was, and the way they found out was by reading
-- the ledger.
--
-- The fixture below claims in the shape `createClaim` actually uses —
-- the claim row inserted as `submitted` and the lines added afterwards
-- — because that shape is the reason the first version of `0364`
-- passed every test while enforcing nothing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A claim in the shape the app makes one: the row first, the lines
-- after. Returns whether it was refused.
create or replace function pg_temp.claim_refused(
  p_org uuid, p_emp uuid, p_type uuid, p_no text, p_on date, p_amount numeric)
returns boolean language plpgsql as $$
declare v_id uuid;
begin
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (p_org, p_no, p_emp, p_on, 'Petrol', 'submitted', p_amount)
  returning id into v_id;
  insert into public.expense_claim_lines
    (org_id, claim_id, line_no, claim_type_id, expense_date, description, amount)
  values (p_org, v_id, 1, p_type, p_on, 'Petrol', p_amount);
  return false;
exception when others then
  return true;
end $$;

do $$
declare
  v_org  uuid;
  v_emp  uuid;
  v_per  uuid;   -- capped per claim
  v_mth  uuid;   -- capped a month
  v_yr   uuid;   -- capped a year
  v_free uuid;   -- capped not at all
  v_msg  text;
  v_id   uuid;
begin
  v_org := pg_temp.test_org('Tuntutan Terhad Sdn Bhd');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'E-1', 'Siti', date '2020-01-01', 'active')
  returning id into v_emp;

  insert into public.claim_types (org_id, code, name, per_claim_cap)
  values (v_org, 'MEAL', 'Meals', 50) returning id into v_per;
  insert into public.claim_types (org_id, code, name, monthly_cap)
  values (v_org, 'FUEL', 'Petrol', 300) returning id into v_mth;
  insert into public.claim_types (org_id, code, name, annual_cap)
  values (v_org, 'GLAS', 'Spectacles', 500) returning id into v_yr;
  insert into public.claim_types (org_id, code, name)
  values (v_org, 'MISC', 'Sundry') returning id into v_free;

  -- ------------------------------------------------------------------
  -- Per claim
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a meal inside the cap goes through',
    not pg_temp.claim_refused(v_org, v_emp, v_per, 'CL-1',
                              date '2026-03-04', 50.00));
  perform pg_temp.check_true('and one sen over it does not',
    pg_temp.claim_refused(v_org, v_emp, v_per, 'CL-2',
                          date '2026-03-05', 50.01));

  -- ------------------------------------------------------------------
  -- Per month, which is about the ones already in
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('two hundred of petrol in March is fine',
    not pg_temp.claim_refused(v_org, v_emp, v_mth, 'CL-3',
                              date '2026-03-06', 200.00));
  perform pg_temp.check_true('another hundred still is',
    not pg_temp.claim_refused(v_org, v_emp, v_mth, 'CL-4',
                              date '2026-03-20', 100.00));
  perform pg_temp.check_true('and the next ringgit is not',
    pg_temp.claim_refused(v_org, v_emp, v_mth, 'CL-5',
                          date '2026-03-21', 1.00));

  -- April is a different month, which is the whole point of the window.
  perform pg_temp.check_true('April starts again',
    not pg_temp.claim_refused(v_org, v_emp, v_mth, 'CL-6',
                              date '2026-04-01', 300.00));

  -- The window is `claim_date` rather than today: somebody submitting
  -- March's petrol in April has spent March's allowance.
  perform pg_temp.check_true('and a late claim spends the month it was spent in',
    pg_temp.claim_refused(v_org, v_emp, v_mth, 'CL-7',
                          date '2026-03-28', 1.00));

  -- ------------------------------------------------------------------
  -- Per year
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('spectacles up to the yearly cap',
    not pg_temp.claim_refused(v_org, v_emp, v_yr, 'CL-8',
                              date '2026-02-01', 500.00));
  perform pg_temp.check_true('and no more that year',
    pg_temp.claim_refused(v_org, v_emp, v_yr, 'CL-9',
                          date '2026-11-01', 10.00));
  perform pg_temp.check_true('but the next year is a new pair',
    not pg_temp.claim_refused(v_org, v_emp, v_yr, 'CL-10',
                              date '2027-01-05', 500.00));

  -- ------------------------------------------------------------------
  -- A type with no cap is not capped
  -- ------------------------------------------------------------------
  -- The control. Without it every assertion above is satisfied by a
  -- trigger that refuses everything.
  perform pg_temp.check_true('an uncapped type takes any figure',
    not pg_temp.claim_refused(v_org, v_emp, v_free, 'CL-11',
                              date '2026-03-09', 9999.00));

  -- ------------------------------------------------------------------
  -- A draft is somebody working
  -- ------------------------------------------------------------------
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CL-12', v_emp, date '2026-05-01', 'Half typed', 'draft', 0)
  returning id into v_id;
  insert into public.expense_claim_lines
    (org_id, claim_id, line_no, claim_type_id, expense_date, description, amount)
  values (v_org, v_id, 1, v_per, date '2026-05-01', 'A very good lunch', 500);
  perform pg_temp.check_true(
    'a draft over the cap is left alone until it is submitted',
    (select status::text = 'draft' from public.expense_claims where id = v_id));

  -- And refused the moment it is asked for.
  begin
    update public.expense_claims set status = 'submitted' where id = v_id;
    raise exception 'FAIL: submitting a draft over the cap was allowed';
  exception when check_violation then
    raise notice 'ok   and refused the moment it is submitted';
  end;

  -- ------------------------------------------------------------------
  -- The message names the type and the figure
  -- ------------------------------------------------------------------
  -- "Over the cap" leaves somebody with five lines to work out which.
  begin
    perform pg_temp.claim_refused(v_org, v_emp, v_per, 'CL-13',
                                  date '2026-06-01', 80.00);
  exception when others then null;
  end;
  begin
    insert into public.expense_claims
      (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
    values (v_org, 'CL-14', v_emp, date '2026-06-02', 'Lunch', 'submitted', 80);
    insert into public.expense_claim_lines
      (org_id, claim_id, line_no, claim_type_id, expense_date, description, amount)
    select v_org, id, 1, v_per, date '2026-06-02', 'Lunch', 80
      from public.expense_claims where claim_no = 'CL-14' and org_id = v_org;
    raise exception 'FAIL: over the per-claim cap was allowed';
  exception when check_violation then
    v_msg := sqlerrm;
  end;
  perform pg_temp.check_true('the refusal names the type: ' || coalesce(v_msg, ''),
    v_msg like '%Meals%');
  perform pg_temp.check_true('and the cap it broke',
    v_msg like '%50.00%');

  perform pg_temp.sign_out();
end $$;

rollback;
