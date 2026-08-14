-- =====================================================================
-- iAkauntan :: a small claim with nobody to ask
--
-- 0119 gave companies a threshold: at or above it a claim goes to all
-- four stages, below it the employee's manager alone can approve it.
-- That short path assumed there is a manager. When there is not, the
-- chain builder wrote a single `manager` step marked `skipped` and
-- returned, leaving a claim with no pending step at all — and
-- `decide_claim_step` only ever acts on the pending step in front:
--
--   chain: manager=skipped
--   decide_claim_step -> This claim has no approval waiting
--   status stays 'submitted'
--
-- Not slow, not waiting on anybody: unapprovable. No owner, no
-- administrator, nobody could pay it, and there is no screen anywhere
-- that would explain why. Any company that sets a threshold and has one
-- employee without a `manager_id` reaches this with a parking receipt.
--
-- The fix is to take the short path only when there is in fact a manager
-- to ask. With nobody in that chair the claim goes up the full chain,
-- where HR and finance are roles rather than named people and an
-- organization always has an owner holding both. That errs towards
-- asking one person too many, which is the right direction to err in for
-- money leaving the company.
--
-- Everything else about the function is 0119's, reproduced because
-- `create or replace` needs the whole body.
-- =====================================================================

create or replace function app.build_claim_chain(p_claim_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_claim public.expense_claims;
  v_manager uuid;
  v_head uuid;
  v_threshold numeric;
  v_full boolean;
  v_step smallint := 0;
  v_seen uuid[] := array[]::uuid[];

  v_note text;
begin
  select * into v_claim from public.expense_claims where id = p_claim_id;
  if v_claim.id is null then return; end if;

  select coalesce(s.full_chain_from, 0) into v_threshold
    from public.claim_approval_settings s where s.org_id = v_claim.org_id;
  v_threshold := coalesce(v_threshold, 0);
  v_full := v_claim.total_amount >= v_threshold;

  select e.manager_id, d.head_employee_id
    into v_manager, v_head
    from public.employees e
    left join public.departments d on d.id = e.department_id
   where e.id = v_claim.employee_id;

  -- Nobody approves their own claim, however the org chart is drawn.
  if v_manager = v_claim.employee_id then v_manager := null; end if;
  if v_head = v_claim.employee_id then v_head := null; end if;

  -- 1. The manager who knows whether it happened.
  v_step := v_step + 1;
  if v_manager is null then
    v_note := 'No manager is set for this employee.';
  else
    v_note := null;
    v_seen := v_seen || v_manager;
  end if;
  insert into public.claim_approvals
    (org_id, claim_id, step_no, stage, status, approver_employee_id, note)
  values (v_claim.org_id, p_claim_id, v_step, 'manager',
          -- Cast, because a `case` over string literals is `text` and
          -- Postgres will not quietly coerce that to an enum. A bare
          -- literal in the same position would have been fine, which is
          -- exactly why this is easy to miss.
          case when v_manager is null then 'skipped'::app.claim_step_status
               else 'pending'::app.claim_step_status end,
          v_manager, v_note);

  -- Below the threshold the manager decides alone — but only where there
  -- is a manager. Returning here with the step above skipped would leave
  -- the claim with nothing pending and no way to approve it ever again,
  -- so an employee with nobody above them goes up the full chain
  -- instead.
  if not v_full and v_manager is not null then return; end if;

  -- 2. The unit head who owns the budget. Skipped where the head is the
  -- manager who has already been asked — one person, one decision.
  v_step := v_step + 1;
  if v_head is null then
    v_note := 'No head is set for this department.';
  elsif v_head = any (v_seen) then
    v_note := 'The department head is also the manager above.';
    v_head := null;
  else
    v_note := null;
    v_seen := v_seen || v_head;
  end if;
  insert into public.claim_approvals
    (org_id, claim_id, step_no, stage, status, approver_employee_id, note)
  values (v_claim.org_id, p_claim_id, v_step, 'unit_head',
          case when v_head is null then 'skipped'::app.claim_step_status
               else 'pending'::app.claim_step_status end,
          v_head, v_note);

  -- 3 and 4. Roles rather than people, so they are never skipped for
  -- want of a name — only where the organization has nobody holding the
  -- role at all.
  v_step := v_step + 1;
  insert into public.claim_approvals
    (org_id, claim_id, step_no, stage, status, note)
  select v_claim.org_id, p_claim_id, v_step, 'hr',
         case when exists (
           select 1 from public.org_members m
            where m.org_id = v_claim.org_id
              and m.role in ('owner', 'admin', 'hr_manager'))
         then 'pending'::app.claim_step_status
              else 'skipped'::app.claim_step_status end,
         case when exists (
           select 1 from public.org_members m
            where m.org_id = v_claim.org_id
              and m.role in ('owner', 'admin', 'hr_manager'))
         then null else 'Nobody in this company holds an HR role.' end;

  v_step := v_step + 1;
  insert into public.claim_approvals
    (org_id, claim_id, step_no, stage, status, note)
  select v_claim.org_id, p_claim_id, v_step, 'finance',
         case when exists (
           select 1 from public.org_members m
            where m.org_id = v_claim.org_id
              and m.role in ('owner', 'admin', 'accountant'))
         then 'pending'::app.claim_step_status
              else 'skipped'::app.claim_step_status end,
         case when exists (
           select 1 from public.org_members m
            where m.org_id = v_claim.org_id
              and m.role in ('owner', 'admin', 'accountant'))
         then null else 'Nobody in this company holds a finance role.' end;
end; $$;

revoke all on function app.build_claim_chain(uuid) from public, anon, authenticated;
