-- =====================================================================
-- iAkauntan :: a claim goes up the line
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/claim_approval_chain.sql
--
-- Approval used to be one person — HR, finance, or the claimant's
-- manager, whoever pressed the button first. It is now four stages in
-- order, and the properties worth asserting are the ones that make it a
-- chain rather than four buttons:
--
--   * one approval does not approve the claim;
--   * the person at step two cannot act while step one is pending;
--   * nobody approves their own claim, however the org chart is drawn;
--   * a stage with nobody to fill it is skipped and says why, so a
--     company that has not drawn its org chart can still pay a claim;
--   * below the threshold a claim needs its manager and nobody else;
--   * a rejection at any stage rejects the claim.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.chain_of(p_claim uuid)
returns text language sql stable as $$
  select string_agg(stage || '=' || status, ' | ' order by step_no)
    from public.claim_approvals where claim_id = p_claim;
$$;

create or replace function pg_temp.claim(
  p_org uuid, p_employee uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (p_org, 'CLM-' || substr(gen_random_uuid()::text, 1, 8), p_employee,
          current_date, 'Trip', 'submitted', p_amount)
  returning id into v_id;
  return v_id;
end; $$;

-- ---------------------------------------------------------------------
-- A company with a manager who is also the department head
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Rantaian Sdn Bhd');
  v_boss_user uuid := pg_temp.test_user();
  v_staff_user uuid := pg_temp.test_user();
  v_boss uuid; v_staff uuid; v_dept uuid; v_claim uuid;
  v_refused boolean;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss_user, 'employee'), (v_org, v_staff_user, 'employee')
  on conflict do nothing;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-BOSS', 'Boss', v_boss_user, current_date)
  returning id into v_boss;

  insert into public.departments (org_id, code, name, head_employee_id)
  values (v_org, 'OPS', 'Operations', v_boss) returning id into v_dept;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id,
     department_id)
  values (v_org, 'E-STAFF', 'Staff', v_staff_user, current_date, v_boss, v_dept)
  returning id into v_staff;

  v_claim := pg_temp.claim(v_org, v_staff, 500);

  perform pg_temp.check_eq('a submitted claim gets four steps',
    (select count(*) from public.claim_approvals where claim_id = v_claim), 4);

  -- The head is the manager, so asking twice would be asking one person
  -- the same question.
  perform pg_temp.check_true('the head who is also the manager is skipped',
    (select status = 'skipped' from public.claim_approvals
      where claim_id = v_claim and stage = 'unit_head'));

  -- ------------------------------------------------------------------
  -- The claimant
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_staff_user);
  begin
    perform public.decide_claim_step(v_claim, true);
    v_refused := false;
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true('a claimant cannot approve their own claim',
    v_refused);

  -- ------------------------------------------------------------------
  -- The manager, who clears one step and not the claim
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_claim, true, 'The trip happened');

  perform pg_temp.check_true('one approval is not the approval',
    (select status = 'submitted' from public.expense_claims
      where id = v_claim));
  perform pg_temp.check_true('the manager''s step is recorded',
    (select status = 'approved' from public.claim_approvals
      where claim_id = v_claim and stage = 'manager'));

  -- The step in front is HR's, and a manager is not HR.
  begin
    perform public.decide_claim_step(v_claim, true);
    v_refused := false;
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true('and does not carry them into the next stage',
    v_refused);

  -- ------------------------------------------------------------------
  -- HR, then finance. The owner holds both roles here.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_claim_step(v_claim, true, 'Within policy');
  perform pg_temp.check_true('still not approved after HR',
    (select status = 'submitted' from public.expense_claims
      where id = v_claim));

  perform public.decide_claim_step(v_claim, true, 'Funds available');
  perform pg_temp.check_true('approved once the last stage clears',
    (select status = 'approved' from public.expense_claims
      where id = v_claim));
  perform pg_temp.check_eq('and the amount is what was claimed',
    (select approved_amount from public.expense_claims where id = v_claim),
    500);
end $$;

-- ---------------------------------------------------------------------
-- A company that has not drawn its org chart
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Baru Sdn Bhd');
  v_user uuid := pg_temp.test_user();
  v_staff uuid; v_claim uuid;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_user, 'employee') on conflict do nothing;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-1', 'Nobody''s report', v_user, current_date)
  returning id into v_staff;

  v_claim := pg_temp.claim(v_org, v_staff, 500);

  -- Skipped rather than stuck. A chain that stalls on a missing
  -- `manager_id` means no claim in the company can ever be paid.
  perform pg_temp.check_true('a missing manager is skipped',
    (select status = 'skipped' from public.claim_approvals
      where claim_id = v_claim and stage = 'manager'));
  perform pg_temp.check_true('and says why',
    (select note is not null from public.claim_approvals
      where claim_id = v_claim and stage = 'manager'));
  perform pg_temp.check_true('while the roles that are filled still stand',
    (select status = 'pending' from public.claim_approvals
      where claim_id = v_claim and stage = 'finance'));
end $$;

-- ---------------------------------------------------------------------
-- Below the threshold
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Rantaian Sdn Bhd');
  v_staff uuid := (select id from public.employees
                    where org_id = v_org and employee_no = 'E-STAFF');
  v_boss_user uuid := (select user_id from public.employees
                        where org_id = v_org and employee_no = 'E-BOSS');
  v_small uuid;
begin
  insert into public.claim_approval_settings (org_id, full_chain_from)
  values (v_org, 200)
  on conflict (org_id) do update set full_chain_from = 200;

  v_small := pg_temp.claim(v_org, v_staff, 12);

  perform pg_temp.check_eq('a small claim gets one step',
    (select count(*) from public.claim_approvals where claim_id = v_small), 1);

  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_small, true);
  perform pg_temp.check_true('and the manager alone approves it',
    (select status = 'approved' from public.expense_claims where id = v_small));
end $$;

-- ---------------------------------------------------------------------
-- A rejection anywhere is a rejection
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Rantaian Sdn Bhd');
  v_staff uuid := (select id from public.employees
                    where org_id = v_org and employee_no = 'E-STAFF');
  v_boss_user uuid := (select user_id from public.employees
                        where org_id = v_org and employee_no = 'E-BOSS');
  v_claim uuid;
begin
  update public.claim_approval_settings set full_chain_from = 0
   where org_id = v_org;

  v_claim := pg_temp.claim(v_org, v_staff, 900);

  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_claim, false, 'Not a company expense');

  perform pg_temp.check_true('the claim is rejected at the first stage',
    (select status = 'rejected' from public.expense_claims where id = v_claim));
  perform pg_temp.check_eq('and nothing is approved to pay',
    (select approved_amount from public.expense_claims where id = v_claim), 0);
  perform pg_temp.check_true('the later stages are never asked',
    (select count(*) = 3 from public.claim_approvals
      where claim_id = v_claim and status = 'pending'));
end $$;

rollback;
