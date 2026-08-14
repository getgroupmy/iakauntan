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
  v_boss_user uuid := pg_temp.another_user('boss@rantaian.test');
  v_staff_user uuid := pg_temp.another_user('staff@rantaian.test');
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
  v_user uuid := pg_temp.another_user('alone@baru.test');
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
-- Below the threshold, with nobody in the manager's chair
--
-- The short path is "the manager decides alone", which is not a path at
-- all when there is no manager. Written naively it produced a claim
-- whose only step was `skipped`: nothing pending, and
-- `decide_claim_step` acts on the pending step in front, so the claim
-- could not be approved by anyone, ever, with nothing on screen to say
-- why. A threshold and one employee without a `manager_id` is all it
-- took. It now goes up the full chain instead.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := (select id from public.organizations where name = 'Rantaian Sdn Bhd');
  v_user uuid := pg_temp.another_user('orphan@rantaian.test');
  v_owner uuid := pg_temp.test_user();
  v_orphan uuid;
  v_small uuid;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_user, 'employee') on conflict do nothing;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-ORPHAN', 'Nobody above them', v_user, current_date)
  returning id into v_orphan;

  -- Still below the 200 threshold set above.
  v_small := pg_temp.claim(v_org, v_orphan, 12);

  perform pg_temp.check_true('a small claim with no manager is not left stuck',
    (select count(*) > 0 from public.claim_approvals
      where claim_id = v_small and status = 'pending'));
  perform pg_temp.check_true('it goes up the full chain instead',
    (select count(*) = 4 from public.claim_approvals where claim_id = v_small));

  -- And somebody can actually finish it.
  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_claim_step(v_small, true, 'Within policy');
  perform public.decide_claim_step(v_small, true, 'Funds available');
  perform pg_temp.check_true('and the roles above can approve it',
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
  -- Nobody further up is ever asked. Counting the steps left pending
  -- would be the wrong test: this company's unit head is the manager, so
  -- that step was skipped when the chain was built and there are two
  -- pending steps, not three. What the rejection has to guarantee is
  -- that no *decision* was taken anywhere else.
  perform pg_temp.check_true('the later stages are never asked',
    (select count(*) = 0 from public.claim_approvals
      where claim_id = v_claim and stage <> 'manager'
        and decided_at is not null));
  perform pg_temp.check_true('and the two role stages are still open',
    (select count(*) = 2 from public.claim_approvals
      where claim_id = v_claim and stage in ('hr', 'finance')
        and status = 'pending'));
end $$;

-- ---------------------------------------------------------------------
-- The claims waiting on you, and only those
--
-- A chain of four makes "every submitted claim in the company" a useless
-- thing to hand an approver. `claims_awaiting_my_approval` answers the
-- narrower question, and the assertions worth making are the ones that
-- keep it narrow: it moves off your list when you clear it, it never
-- contains your own claim, and it is bounded by the company you are
-- actually in.
-- ---------------------------------------------------------------------
create or replace function pg_temp.waiting_on_me(p_org uuid)
returns text language sql stable as $$
  select coalesce(string_agg(c.claim_no, ',' order by c.claim_no), 'nothing')
    from public.claims_awaiting_my_approval(p_org) as t(claim_id)
    join public.expense_claims c on c.id = t.claim_id;
$$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Barisan Sdn Bhd');
  v_boss_user uuid := pg_temp.another_user('boss@barisan.test');
  v_staff_user uuid := pg_temp.another_user('staff@barisan.test');
  v_stranger uuid := pg_temp.another_user('nobody@elsewhere.test');
  v_elsewhere uuid;
  v_boss uuid; v_staff uuid; v_dept uuid;
  v_first uuid; v_second uuid;
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

  -- Two claims, both starting at the manager.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CLM-FIRST', v_staff, current_date, 'Trip', 'submitted', 500)
  returning id into v_first;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CLM-SECOND', v_staff, current_date, 'Taxi', 'submitted', 800)
  returning id into v_second;

  perform pg_temp.sign_in_as(v_boss_user);
  perform pg_temp.check_true('both claims start on the manager''s list',
    pg_temp.waiting_on_me(v_org) = 'CLM-FIRST,CLM-SECOND');

  -- The point of the whole thing: a claimant is never waiting on
  -- themselves, so their own claims do not appear as work to do.
  perform pg_temp.sign_in_as(v_staff_user);
  perform pg_temp.check_true('a claimant is not waiting on themselves',
    pg_temp.waiting_on_me(v_org) = 'nothing');

  -- Clearing one moves it to the next stage and off this list. A list
  -- that kept it would be a to-do list of somebody else's work.
  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_first, true, 'The trip happened');
  perform pg_temp.check_true('a cleared claim leaves the manager''s list',
    pg_temp.waiting_on_me(v_org) = 'CLM-SECOND');

  -- And arrives on the list of whoever the chain asks next. The owner
  -- holds both role stages here.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and arrives on the next approver''s',
    pg_temp.waiting_on_me(v_org) like '%CLM-FIRST%');

  -- Nobody outside the company sees a claim of theirs, and a member of
  -- one company asking about another gets nothing rather than an error.
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_true('a stranger sees none of it',
    pg_temp.waiting_on_me(v_org) = 'nothing');

  v_elsewhere := pg_temp.test_org('Lain Sdn Bhd');
  perform pg_temp.sign_in_as(v_boss_user);
  perform pg_temp.check_true('nor does a member of one company see another',
    pg_temp.waiting_on_me(v_elsewhere) = 'nothing');

  perform pg_temp.sign_out();
  perform pg_temp.check_true('signed out, nothing is waiting on anybody',
    pg_temp.waiting_on_me(v_org) = 'nothing');
end $$;

rollback;
