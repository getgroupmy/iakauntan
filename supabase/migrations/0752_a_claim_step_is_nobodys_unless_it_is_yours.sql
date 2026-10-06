-- =====================================================================
-- 0752 :: a claim step is nobody's unless it is yours
--
-- Answered on 6 October: "fix it".
--
-- `app.may_decide_claim_step` (0119) answers the manager's and the unit
-- head's step with
--
--     v_step.approver_employee_id is not null
--     and v_step.approver_employee_id = v_me
--
-- where `v_me` is the caller's employee record IN THE STEP'S COMPANY.
-- For anybody with no such record -- an HR manager or accountant who is
-- not on the payroll, or a signed-in user of ANOTHER company altogether
-- -- `v_me` is null, `x = null` is null, and `true and null` is null.
-- The function answered NULL, not false.
--
-- `decide_claim_step` asked `if not app.may_decide_claim_step(...)`,
-- and `not null` is null, which plpgsql's IF treats as false: the
-- refusal did not fire. So anybody signed in could approve or REJECT
-- the manager's or the unit head's step on any company's claim, given
-- the claim's id. Reproduced before this was written: a user who was a
-- member of no company in the test approved another company's manager
-- step, and the row recorded them as the one who decided it.
-- `claims_awaiting_my_approval` (0123) was never affected -- its
-- `and app.may_decide_claim_step(...)` drops a NULL like a false.
--
-- Production had no `claim_approvals` rows at all when this was written,
-- so nothing was decided this way.
--
-- Both ends are closed, so neither alone has to be right:
--
--   * `may_decide_claim_step` answers false whenever it does not answer
--     true -- `coalesce(..., false)` over the stage's answer, which also
--     covers a stage the CASE does not name;
--   * `decide_claim_step` refuses unless the answer `is true`.
--
-- Nothing else in either function changes. Grants and the comments
-- 0581 wrote survive a CREATE OR REPLACE.
-- =====================================================================

create or replace function app.may_decide_claim_step(p_step_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_step public.claim_approvals;
  v_me uuid;
begin
  select * into v_step from public.claim_approvals where id = p_step_id;
  if v_step.id is null or v_step.status <> 'pending' then return false; end if;

  -- An owner or an administrator can act at any stage. Not a loophole so
  -- much as the way out of one: a manager who has left the company would
  -- otherwise strand every claim behind them, and the row records who
  -- actually decided it.
  if app.can_admin(v_step.org_id) then return true; end if;

  select e.id into v_me
    from public.employees e
   where e.org_id = v_step.org_id and e.user_id = auth.uid();

  -- FALSE, never NULL. With no employee record here `v_me` is null and
  -- `approver_employee_id = v_me` is null with it; a caller that asks
  -- `if not ...` reads that as permission.
  return coalesce(case v_step.stage
    when 'manager' then v_step.approver_employee_id is not null
                    and v_step.approver_employee_id = v_me
    when 'unit_head' then v_step.approver_employee_id is not null
                    and v_step.approver_employee_id = v_me
    when 'hr' then app.can_manage_hr(v_step.org_id)
    when 'finance' then app.can_post(v_step.org_id)
  end, false);
end; $$;

create or replace function public.decide_claim_step(
  p_claim_id uuid,
  p_approve boolean,
  p_note text default null,
  p_approved_amount numeric default null
)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_claim public.expense_claims;
  v_step public.claim_approvals;
  v_remaining int;
begin
  select * into v_claim from public.expense_claims where id = p_claim_id;
  if v_claim.id is null then
    raise exception 'Claim not found' using errcode = 'P0002';
  end if;
  if v_claim.status <> 'submitted' then
    raise exception 'This claim is already %', v_claim.status
      using errcode = '22023';
  end if;

  -- The step in front, and only that one. Approving out of order would
  -- make the chain a list of opinions rather than a sequence.
  select * into v_step from public.claim_approvals
   where claim_id = p_claim_id and status = 'pending'
   order by step_no limit 1;

  if v_step.id is null then
    raise exception 'This claim has no approval waiting'
      using errcode = '22023';
  end if;

  -- `is not true`, not `not`: an answer of NULL is not permission.
  if app.may_decide_claim_step(v_step.id) is not true then
    raise exception 'This claim is waiting for somebody else'
      using errcode = '42501';
  end if;

  update public.claim_approvals
     set status = case when p_approve then 'approved'::app.claim_step_status
                       else 'rejected'::app.claim_step_status end,
         decided_by = auth.uid(),
         decided_at = now(),
         note = coalesce(p_note, note)
   where id = v_step.id;

  if not p_approve then
    update public.expense_claims
       set status = 'rejected', approved_amount = 0,
           approver_id = auth.uid(), decided_at = now(), decision_note = p_note
     where id = p_claim_id;
    return;
  end if;

  select count(*) into v_remaining from public.claim_approvals
   where claim_id = p_claim_id and status = 'pending';

  -- Approved by everybody the chain asked. Only now is it approved.
  if v_remaining = 0 then
    update public.expense_claims
       set status = 'approved',
           approved_amount = coalesce(p_approved_amount, total_amount),
           approver_id = auth.uid(), decided_at = now(), decision_note = p_note
     where id = p_claim_id;
  end if;
end; $$;
