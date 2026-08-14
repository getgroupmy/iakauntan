-- A claim goes up the line
--
-- Approval was one person: HR, finance, or the claimant's manager,
-- whoever pressed the button first. That is fine for three people in one
-- room and wrong for a company with departments — a claim should be seen
-- by the manager who knows whether the trip happened, the unit head who
-- owns the budget, HR who owns the policy, and finance who owns the
-- money.
--
-- Four stages, in that order, built when the claim is submitted and
-- worked through one at a time.
--
-- ---------------------------------------------------------------------
-- Three decisions, made deliberately
--
-- **A stage with nobody to fill it is skipped, and says so.** Most
-- companies have not filled in an org chart on their first day, and a
-- chain that stalls on a missing `manager_id` would mean no claim in the
-- company can ever be paid. The step is recorded as skipped with the
-- reason, so the history shows what did *not* happen as clearly as what
-- did.
--
-- **Small claims stop early.** `claim_approval_settings.full_chain_from`
-- is the amount at which the whole chain applies; below it a claim needs
-- its manager and nobody else. It defaults to zero, which means every
-- claim goes the whole way — the strict reading, until somebody chooses
-- otherwise.
--
-- **HR and finance are roles, not people.** Anyone holding the role can
-- clear that stage, so nobody's leave stops a claim. The manager and
-- unit head stages are the opposite by nature: they are a particular
-- person, and the point of them is that it is that person.

create type app.claim_stage as enum ('manager', 'unit_head', 'hr', 'finance');
create type app.claim_step_status as
  enum ('pending', 'approved', 'rejected', 'skipped');

-- Where the chain becomes the full chain.
create table public.claim_approval_settings (
  org_id uuid primary key
    references public.organizations(id) on delete cascade,
  -- At or above this, all four stages. Below it, the manager alone.
  -- Zero — the default — means every claim goes the whole way.
  full_chain_from numeric(18, 2) not null default 0
    check (full_chain_from >= 0),
  updated_at timestamptz not null default now()
);

-- One step of one claim.
create table public.claim_approvals (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  claim_id uuid not null
    references public.expense_claims(id) on delete cascade,
  step_no smallint not null,
  stage app.claim_stage not null,
  status app.claim_step_status not null default 'pending',

  -- Set for the two stages that are a named person. Null for HR and
  -- finance, which are whoever holds the role.
  approver_employee_id uuid references public.employees(id),

  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  note text,
  created_at timestamptz not null default now(),

  unique (claim_id, step_no)
);

create index claim_approvals_claim on public.claim_approvals (claim_id);
create index claim_approvals_waiting
  on public.claim_approvals (org_id, status) where status = 'pending';

-- ---------------------------------------------------------------------
-- Building the chain
-- ---------------------------------------------------------------------

-- Built by a trigger rather than by whoever creates the claim: a claim
-- can be created by the app, by an import, or by a function written
-- next year, and a chain built by the caller is a chain somebody can
-- forget to build.
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

  if not v_full then return; end if;

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

create or replace function app.claim_chain_trigger()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if new.status = 'submitted' then
    perform app.build_claim_chain(new.id);
  end if;
  return new;
end; $$;

create trigger claim_chain_on_submit
  after insert on public.expense_claims
  for each row execute function app.claim_chain_trigger();

-- ---------------------------------------------------------------------
-- Who may decide the step in front of them
-- ---------------------------------------------------------------------
create or replace function app.may_decide_claim_step(p_step_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
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

  return case v_step.stage
    when 'manager' then v_step.approver_employee_id is not null
                    and v_step.approver_employee_id = v_me
    when 'unit_head' then v_step.approver_employee_id is not null
                    and v_step.approver_employee_id = v_me
    when 'hr' then app.can_manage_hr(v_step.org_id)
    when 'finance' then app.can_post(v_step.org_id)
  end;
end; $$;

-- ---------------------------------------------------------------------
-- Deciding
-- ---------------------------------------------------------------------
create or replace function public.decide_claim_step(
  p_claim_id uuid,
  p_approve boolean,
  p_note text default null,
  p_approved_amount numeric default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
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

  if not app.may_decide_claim_step(v_step.id) then
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

-- The old one-shot decision now goes through the chain.
--
-- Left in place rather than dropped: it is what the app calls, and a
-- second door into a decision that skips three approvals is exactly the
-- thing this migration exists to close.
create or replace function public.decide_expense_claim(
  p_claim_id uuid,
  p_approve boolean,
  p_note text default null,
  p_approved_amount numeric default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  perform public.decide_claim_step(
    p_claim_id, p_approve, p_note, p_approved_amount);
end; $$;

-- ---------------------------------------------------------------------
-- Who sees the chain
-- ---------------------------------------------------------------------
alter table public.claim_approvals enable row level security;
alter table public.claim_approval_settings enable row level security;

-- The same audience that may read the claim's paperwork: the claimant,
-- HR, and staff who can already see the ledger. Written as one call so
-- the two cannot drift apart.
create policy claim_approvals_select on public.claim_approvals
  for select to authenticated
  using (app.can_read_attachment(org_id, 'expense_claims', claim_id));

-- Nothing writes these but the functions above, which are SECURITY
-- DEFINER and check who is asking. No insert, update or delete policy is
-- the point rather than an omission.

create policy claim_settings_select on public.claim_approval_settings
  for select to authenticated using (app.is_org_member(org_id));

create policy claim_settings_write on public.claim_approval_settings
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

revoke all on function app.build_claim_chain(uuid) from public, anon, authenticated;
revoke all on function app.may_decide_claim_step(uuid) from public, anon;
grant execute on function app.may_decide_claim_step(uuid) to authenticated;
revoke all on function public.decide_claim_step(uuid, boolean, text, numeric)
  from public, anon;
grant execute on function public.decide_claim_step(uuid, boolean, text, numeric)
  to authenticated;

-- ---------------------------------------------------------------------
-- Claims that were already in flight
-- ---------------------------------------------------------------------
-- A claim submitted before this migration has no chain, and without one
-- `decide_claim_step` would refuse it forever. Give each waiting claim
-- the chain it would have been given.
do $$
declare v_claim uuid;
begin
  for v_claim in
    select c.id from public.expense_claims c
     where c.status = 'submitted'
       and not exists (select 1 from public.claim_approvals a
                        where a.claim_id = c.id)
  loop
    perform app.build_claim_chain(v_claim);
  end loop;
end $$;
