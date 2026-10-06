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
          pg_temp.today(), 'Trip', 'submitted', p_amount)
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
  values (v_org, 'E-BOSS', 'Boss', v_boss_user, pg_temp.today())
  returning id into v_boss;

  insert into public.departments (org_id, code, name, head_employee_id)
  values (v_org, 'OPS', 'Operations', v_boss) returning id into v_dept;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id,
     department_id)
  values (v_org, 'E-STAFF', 'Staff', v_staff_user, pg_temp.today(), v_boss, v_dept)
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
  values (v_org, 'E-1', 'Nobody''s report', v_user, pg_temp.today())
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
  values (v_org, 'E-ORPHAN', 'Nobody above them', v_user, pg_temp.today())
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
  values (v_org, 'E-BOSS', 'Boss', v_boss_user, pg_temp.today())
  returning id into v_boss;

  insert into public.departments (org_id, code, name, head_employee_id)
  values (v_org, 'OPS', 'Operations', v_boss) returning id into v_dept;

  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id,
     department_id)
  values (v_org, 'E-STAFF', 'Staff', v_staff_user, pg_temp.today(), v_boss, v_dept)
  returning id into v_staff;

  -- Two claims, both starting at the manager.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CLM-FIRST', v_staff, pg_temp.today(), 'Trip', 'submitted', 500)
  returning id into v_first;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, status, total_amount)
  values (v_org, 'CLM-SECOND', v_staff, pg_temp.today(), 'Taxi', 'submitted', 800)
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

-- ---------------------------------------------------------------------
-- decide_claim_step, rule by rule
--
-- A sweep of `0119`'s definition over this file and `expense_claims.sql`
-- left thirteen mutants alive. Most were the record a decision leaves:
-- nothing read who decided a step, when, or what they wrote, nor who
-- approved or refused the claim and why -- only its status. And three
-- were the order of things: a refused claim was never offered to
-- anybody a second time, nobody refused at the LAST step (where carrying
-- on past a refusal finds nothing pending and approves the claim), and
-- a claim with nothing pending was never decided at all.
--
-- One is equivalent: `note = coalesce(p_note, note)` against `note =
-- p_note`. A step is only decided while pending, and
-- `build_claim_chain` writes every pending step with no note -- the
-- notes it writes are the reasons a step was SKIPPED -- so there is
-- never a note there for the coalesce to keep.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Keputusan Tuntutan Sdn Bhd');
  v_boss_user uuid := pg_temp.another_user('boss@keputusan.test');
  v_staff_user uuid := pg_temp.another_user('staff@keputusan.test');
  v_boss uuid; v_staff uuid;
  v_paid uuid; v_last uuid; v_first uuid; v_stuck uuid;
  r record;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss_user, 'employee'), (v_org, v_staff_user, 'employee')
  on conflict do nothing;
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-BOSS', 'Boss', v_boss_user, pg_temp.today())
  returning id into v_boss;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id)
  values (v_org, 'E-STAFF', 'Staff', v_staff_user, pg_temp.today(), v_boss)
  returning id into v_staff;

  perform pg_temp.check_refused('a claim that is not there says so',
    format('select public.decide_claim_step(%L, true)', gen_random_uuid()),
    '%Claim not found%', 'P0002');

  -- Approved all the way: what each step and the claim record.
  v_paid := pg_temp.claim(v_org, v_staff, 500);
  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_paid, true, 'The trip happened');
  select * into r from public.claim_approvals
   where claim_id = v_paid and stage = 'manager';
  perform pg_temp.check_eq('a step records who decided it', r.decided_by, v_boss_user);
  perform pg_temp.check_eq('and when', r.decided_at::text, now()::text);
  perform pg_temp.check_eq('and what they said', r.note, 'The trip happened');

  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_claim_step(v_paid, true, 'Within policy');
  perform public.decide_claim_step(v_paid, true, 'Paid on Friday');
  select * into r from public.expense_claims where id = v_paid;
  perform pg_temp.check_eq('the claim is approved', r.status::text, 'approved');
  perform pg_temp.check_eq('by whoever cleared the last step', r.approver_id, v_owner);
  perform pg_temp.check_eq('with what they said', r.decision_note, 'Paid on Friday');

  -- Refused at the LAST step. Everything before it is approved, so
  -- nothing is pending once it is refused -- and a refusal that carried
  -- on would find nothing left to wait for and approve the claim.
  v_last := pg_temp.claim(v_org, v_staff, 300);
  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_last, true);
  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_claim_step(v_last, true);
  perform public.decide_claim_step(v_last, false, 'No budget left this quarter');
  select * into r from public.expense_claims where id = v_last;
  perform pg_temp.check_eq('a refusal at the last step is a refusal',
    r.status::text, 'rejected');
  perform pg_temp.check_eq('it records who refused', r.approver_id, v_owner);
  perform pg_temp.check_eq('and why', r.decision_note, 'No budget left this quarter');

  -- Refused at the FIRST step, with later steps still pending. The
  -- step says rejected, and the claim cannot then be taken up again by
  -- somebody further up.
  v_first := pg_temp.claim(v_org, v_staff, 200);
  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_first, false, 'Not a company expense');
  perform pg_temp.check_eq('the refusing step says it refused',
    (select status::text from public.claim_approvals
      where claim_id = v_first and stage = 'manager'), 'rejected');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_refused('a refused claim is not decided again',
    format('select public.decide_claim_step(%L, true)', v_first),
    '%already rejected%', '22023');

  -- Submitted, with every step since stood down: nothing is waiting,
  -- and the claim says that rather than "somebody else".
  v_stuck := pg_temp.claim(v_org, v_staff, 100);
  update public.claim_approvals set status = 'skipped' where claim_id = v_stuck;
  perform pg_temp.check_refused('a claim with nothing pending says so',
    format('select public.decide_claim_step(%L, true)', v_stuck),
    '%no approval waiting%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- may_decide_claim_step, rule by rule
--
-- A sweep of `0119`'s definition over this file and `expense_claims.sql`
-- left ten of twelve mutants alive, and for one reason: every role
-- stage in both files was cleared by the OWNER, who is an administrator
-- and may act at any stage. So nothing ever asked whether HR may clear
-- the finance step, whether an accountant may clear HR's, or whether a
-- plain employee may clear either -- the administrator's way through
-- answered every one of those questions with yes. And the company's
-- head was always its manager, so the unit head's step was always
-- skipped and nobody ever stood in front of one.
--
-- Here each stage has somebody holding exactly one role, and each is
-- asked about every step -- which is how 0752 was found: HR, asked
-- about the manager's step, got NULL rather than false, and so did
-- everybody else with no employee record in the company, a stranger
-- from another company included; `decide_claim_step` let all of them
-- through.
--
-- One mutant is EQUIVALENT, by the table: dropping `approver_employee_id
-- is not null` from the manager's and the unit head's test. A pending
-- step that names nobody cannot arise -- `build_claim_chain` writes a
-- step with no approver as SKIPPED, and the plain foreign key on
-- `approver_employee_id` refuses to delete an employee a step still
-- names (the composite one's ON DELETE SET NULL never gets the chance).
-- 0752's `coalesce(..., false)` is the guard that matters now.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Peranan Sdn Bhd');
  v_boss_user uuid := pg_temp.another_user('boss@peranan.test');
  v_head_user uuid := pg_temp.another_user('head@peranan.test');
  v_staff_user uuid := pg_temp.another_user('staff@peranan.test');
  v_hr_user uuid := pg_temp.another_user('hr@peranan.test');
  v_acct_user uuid := pg_temp.another_user('acct@peranan.test');
  v_boss uuid; v_head uuid; v_staff uuid; v_dept uuid; v_claim uuid;
  v_mgr_step uuid; v_head_step uuid; v_hr_step uuid; v_fin_step uuid;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss_user, 'employee'), (v_org, v_head_user, 'employee'),
         (v_org, v_staff_user, 'employee'), (v_org, v_hr_user, 'hr_manager'),
         (v_org, v_acct_user, 'accountant')
  on conflict do nothing;

  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-BOSS', 'Boss', v_boss_user, pg_temp.today())
  returning id into v_boss;
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-HEAD', 'Head', v_head_user, pg_temp.today())
  returning id into v_head;
  -- A department whose head is NOT the claimant's manager, so the unit
  -- head's step is somebody's to decide rather than skipped.
  insert into public.departments (org_id, code, name, head_employee_id)
  values (v_org, 'OPS', 'Operations', v_head) returning id into v_dept;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id, department_id)
  values (v_org, 'E-STAFF', 'Staff', v_staff_user, pg_temp.today(), v_boss, v_dept)
  returning id into v_staff;

  v_claim := pg_temp.claim(v_org, v_staff, 500);
  select id into v_mgr_step  from public.claim_approvals where claim_id = v_claim and stage = 'manager';
  select id into v_head_step from public.claim_approvals where claim_id = v_claim and stage = 'unit_head';
  select id into v_hr_step   from public.claim_approvals where claim_id = v_claim and stage = 'hr';
  select id into v_fin_step  from public.claim_approvals where claim_id = v_claim and stage = 'finance';
  perform pg_temp.check_eq('every step of this claim is waiting on somebody',
    pg_temp.chain_of(v_claim),
    'manager=pending | unit_head=pending | hr=pending | finance=pending');

  perform pg_temp.check_true('a step that is not there is nobody''s',
    app.may_decide_claim_step(gen_random_uuid()) is false);

  -- The manager's step: the named manager, and the administrator.
  perform pg_temp.sign_in_as(v_boss_user);
  perform pg_temp.check_true('the manager may decide the manager''s step',
    app.may_decide_claim_step(v_mgr_step) is true);
  perform pg_temp.check_true('but not the unit head''s',
    app.may_decide_claim_step(v_head_step) is false);
  perform pg_temp.sign_in_as(v_hr_user);
  perform pg_temp.check_true('HR may not decide the manager''s step',
    app.may_decide_claim_step(v_mgr_step) is false);

  -- THE DOOR THIS WAS OPEN AT, before 0752. With no employee record
  -- here the answer above was NULL, not false, and `decide_claim_step`
  -- asked `if not ...` -- so HR, or anybody signed in to any company,
  -- could approve or refuse the manager's step on this claim.
  perform pg_temp.check_refused('so HR cannot decide it through the door either',
    format('select public.decide_claim_step(%L, false, %L)', v_claim, 'Refused by HR'),
    '%waiting for somebody else%', '42501');
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@elsewhere-claims.test'));
  perform pg_temp.check_true('nor may somebody from another company',
    app.may_decide_claim_step(v_mgr_step) is false);
  perform pg_temp.check_refused('who cannot decide it through the door',
    format('select public.decide_claim_step(%L, true)', v_claim),
    '%waiting for somebody else%', '42501');
  perform pg_temp.check_eq('and the manager''s step is still the manager''s',
    (select status::text || '/' || coalesce(decided_by::text, 'nobody')
       from public.claim_approvals where id = v_mgr_step), 'pending/nobody');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('an administrator may, at any stage',
    app.may_decide_claim_step(v_mgr_step) is true);

  -- The unit head's step: its head, and not the claimant.
  perform pg_temp.sign_in_as(v_head_user);
  perform pg_temp.check_true('the head may decide the unit head''s step',
    app.may_decide_claim_step(v_head_step) is true);
  perform pg_temp.sign_in_as(v_staff_user);
  perform pg_temp.check_true('another employee may not',
    app.may_decide_claim_step(v_head_step) is false);

  -- The role steps: each to its own role, and to nobody else's.
  perform pg_temp.check_true('an employee may not decide the finance step',
    app.may_decide_claim_step(v_fin_step) is false);
  perform pg_temp.sign_in_as(v_hr_user);
  perform pg_temp.check_true('HR may decide HR''s step',
    app.may_decide_claim_step(v_hr_step) is true);
  perform pg_temp.check_true('but not finance''s',
    app.may_decide_claim_step(v_fin_step) is false);
  perform pg_temp.sign_in_as(v_acct_user);
  perform pg_temp.check_true('an accountant may decide finance''s step',
    app.may_decide_claim_step(v_fin_step) is true);
  perform pg_temp.check_true('but not HR''s',
    app.may_decide_claim_step(v_hr_step) is false);

  -- Decided, the step is nobody's any more -- the administrator's
  -- included, who may act at any stage but not twice at one.
  perform pg_temp.sign_in_as(v_boss_user);
  perform public.decide_claim_step(v_claim, true);
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('a decided step is nobody''s to decide again',
    app.may_decide_claim_step(v_mgr_step) is false);
end $$;

-- ---------------------------------------------------------------------
-- One login, two companies
--
-- `v_me` is the employee record in THE STEP'S company. A person on two
-- payrolls has two records, and without the company in the lookup the
-- first one found answers for both -- here the one in the other
-- company, made first, so a step naming them in this one is refused.
-- (Which row comes first without an ORDER BY is the heap's order; in a
-- fresh transaction that is insertion order, which is what this leans
-- on and why the other company's record is made first.)
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_first_org uuid;
  v_org uuid;
  v_boss_user uuid := pg_temp.another_user('boss@duasyarikat.test');
  v_staff_user uuid := pg_temp.another_user('staff@duasyarikat.test');
  v_boss uuid; v_staff uuid; v_claim uuid; v_step uuid;
begin
  perform pg_temp.allow_many_companies();
  v_first_org := pg_temp.test_org('Syarikat Pertama Sdn Bhd');
  insert into public.org_members (org_id, user_id, role)
  values (v_first_org, v_boss_user, 'employee') on conflict do nothing;
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_first_org, 'E-ELSEWHERE', 'Boss, elsewhere', v_boss_user, pg_temp.today());

  v_org := pg_temp.test_org('Syarikat Kedua Sdn Bhd');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss_user, 'employee'), (v_org, v_staff_user, 'employee')
  on conflict do nothing;
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-BOSS', 'Boss', v_boss_user, pg_temp.today())
  returning id into v_boss;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id)
  values (v_org, 'E-STAFF', 'Staff', v_staff_user, pg_temp.today(), v_boss)
  returning id into v_staff;

  v_claim := pg_temp.claim(v_org, v_staff, 500);
  select id into v_step from public.claim_approvals
   where claim_id = v_claim and stage = 'manager';

  perform pg_temp.sign_in_as(v_boss_user);
  perform pg_temp.check_true('a manager on two payrolls may decide in either',
    app.may_decide_claim_step(v_step) is true);
end $$;

-- ---------------------------------------------------------------------
-- build_claim_chain, rule by rule
--
-- A sweep of `0121`'s definition over this file and `expense_claims.sql`
-- left ten mutants alive. Every company in both files had an owner, so
-- the HR and finance steps were always somebody's and the notes that say
-- why one was skipped were never written; nobody claimed against
-- themselves through the org chart; the threshold was only ever met by
-- a claim well clear of it; and only one company had a threshold set,
-- so reading anybody's would do.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid; v_plain uuid; v_hr_only uuid; v_books_only uuid;
  v_self_user uuid := pg_temp.another_user('self@rantai-sendiri.test');
  v_self uuid; v_dept uuid; v_claim uuid; v_staff uuid;
begin
  perform pg_temp.allow_many_companies();

  -- THE THRESHOLD IS THIS COMPANY'S. One company sets a thousand;
  -- another sets nothing and so takes the full chain at any figure. A
  -- claim of five hundred in each must come out differently -- and if
  -- the threshold were read from whichever row came first, one of the
  -- two would not.
  v_org := pg_temp.test_org('Ambang Sendiri Sdn Bhd');
  insert into public.claim_approval_settings (org_id, full_chain_from)
  values (v_org, 1000);
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_org, 'E-BOSS', 'Boss', pg_temp.another_user('boss@ambang.test'), pg_temp.today())
  returning id into v_self;  -- the manager, for now
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id)
  values (v_org, 'E-STAFF', 'Staff', pg_temp.another_user('staff@ambang.test'),
          pg_temp.today(), v_self)
  returning id into v_staff;

  v_claim := pg_temp.claim(v_org, v_staff, 500);
  perform pg_temp.check_eq('below this company''s threshold, the manager alone',
    pg_temp.chain_of(v_claim), 'manager=pending');
  -- AT the threshold is the full chain: "from" a thousand.
  v_claim := pg_temp.claim(v_org, v_staff, 1000);
  perform pg_temp.check_eq('at the threshold, the whole chain',
    (select count(*) from public.claim_approvals where claim_id = v_claim), 4);

  v_plain := pg_temp.test_org('Tiada Ambang Sdn Bhd');
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_plain, 'E-BOSS', 'Boss', pg_temp.another_user('boss@tiada.test'), pg_temp.today())
  returning id into v_self;
  insert into public.employees
    (org_id, employee_no, full_name, user_id, hire_date, manager_id)
  values (v_plain, 'E-STAFF', 'Staff', pg_temp.another_user('staff@tiada.test'),
          pg_temp.today(), v_self)
  returning id into v_staff;
  v_claim := pg_temp.claim(v_plain, v_staff, 500);
  perform pg_temp.check_eq('while a company with no threshold asks everybody',
    (select count(*) from public.claim_approvals where claim_id = v_claim), 4);

  -- NOBODY APPROVES THEIR OWN CLAIM, however the chart is drawn: an
  -- employee recorded as their own manager, heading their own
  -- department. Both steps are skipped rather than handed to them.
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_plain, 'E-SELF', 'Own boss', v_self_user, pg_temp.today())
  returning id into v_self;
  insert into public.departments (org_id, code, name, head_employee_id)
  values (v_plain, 'SELF', 'One-person department', v_self) returning id into v_dept;
  update public.employees set manager_id = v_self, department_id = v_dept
   where id = v_self;
  v_claim := pg_temp.claim(v_plain, v_self, 500);
  perform pg_temp.check_eq('their own manager and head are both stood down',
    pg_temp.chain_of(v_claim),
    'manager=skipped | unit_head=skipped | hr=pending | finance=pending');
  perform pg_temp.check_true('and neither step names them',
    not exists (select 1 from public.claim_approvals
                 where claim_id = v_claim and approver_employee_id = v_self));

  -- A department with no head says so.
  v_claim := pg_temp.claim(v_plain, v_staff, 500);
  perform pg_temp.check_eq('a missing head is skipped and says why',
    (select note from public.claim_approvals
      where claim_id = v_claim and stage = 'unit_head'),
    'No head is set for this department.');

  -- A COMPANY MISSING A ROLE. Built, then the owner's membership is
  -- turned into the one role under test -- so the company has an HR
  -- manager and nobody who keeps the books, or the reverse.
  v_hr_only := pg_temp.test_org('Hanya HR Sdn Bhd');
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_hr_only, 'E-1', 'Staff', pg_temp.another_user('staff@hanyahr.test'), pg_temp.today())
  returning id into v_staff;
  update public.org_members set role = 'hr_manager' where org_id = v_hr_only;
  v_claim := pg_temp.claim(v_hr_only, v_staff, 500);
  perform pg_temp.check_eq('with HR and no finance role, finance is stood down',
    (select status::text || ': ' || coalesce(note, '') from public.claim_approvals
      where claim_id = v_claim and stage = 'finance'),
    'skipped: Nobody in this company holds a finance role.');
  perform pg_temp.check_eq('and HR is asked',
    (select status::text from public.claim_approvals
      where claim_id = v_claim and stage = 'hr'), 'pending');

  v_books_only := pg_temp.test_org('Hanya Akaun Sdn Bhd');
  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (v_books_only, 'E-1', 'Staff', pg_temp.another_user('staff@hanyaakaun.test'), pg_temp.today())
  returning id into v_staff;
  update public.org_members set role = 'accountant' where org_id = v_books_only;
  v_claim := pg_temp.claim(v_books_only, v_staff, 500);
  perform pg_temp.check_eq('with an accountant and no HR, HR is stood down',
    (select status::text || ': ' || coalesce(note, '') from public.claim_approvals
      where claim_id = v_claim and stage = 'hr'),
    'skipped: Nobody in this company holds an HR role.');
  perform pg_temp.check_eq('and finance is asked',
    (select status::text from public.claim_approvals
      where claim_id = v_claim and stage = 'finance'), 'pending');
end $$;

rollback;
