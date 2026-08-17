-- Approvals, for anything that reaches the ledger.
--
-- Expense claims have had a real approval chain since `0116` —
-- `claim_approvals`, a step per approver, a decision each. Nothing else
-- has. A purchase requisition is a document type that exists and
-- transfers into a purchase order with nobody asked; a manual journal
-- posts the moment it is written; an invoice above any amount goes out
-- on one person's say-so.
--
-- `claim_approvals` cannot be widened to cover them. It is keyed on
-- `claim_id`, its steps are `app.claim_stage` — manager, unit head, HR,
-- finance — and its approvers are `employees`. Those are the right
-- shapes for a staff expense and the wrong ones for a journal. So this
-- is a second, polymorphic layer beside it rather than a rewrite of it,
-- and expense claims keep the chain they have.
--
-- **Nothing changes for anybody until a rule is written.** Every gate
-- below asks `approval_required` first, which is false when no rule
-- matches, and no rules exist anywhere on this deployment. A company
-- that never opens the approvals screen will not notice this migration.

create type app.approval_entity as enum
  ('sales_document', 'purchase_document', 'journal');

create type app.approval_status as enum
  ('pending', 'approved', 'rejected', 'cancelled');

-- ---------------------------------------------------------------------
-- What needs approving, and by whom
-- ---------------------------------------------------------------------
create table public.approval_rules (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  entity_kind app.approval_entity not null,

  -- Null means every document of that kind. A value narrows it to one
  -- type, which is how a company gets "purchase requisitions need a
  -- head of department" without also holding up every supplier bill.
  doc_type    text,

  -- The rule bites at or above this. Zero means always, which is what a
  -- journal rule usually wants.
  min_amount  numeric(18, 2) not null default 0 check (min_amount >= 0),

  step_no     smallint not null check (step_no > 0),

  -- One or the other, never both and never neither. A role is the
  -- ordinary case — "an admin" — and a named person is for the company
  -- where only one person may sign.
  approver_role app.member_role,
  approver_user_id uuid references auth.users(id) on delete cascade,

  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),

  constraint approval_rules_one_approver check (
    (approver_role is not null) <> (approver_user_id is not null))
);

create index approval_rules_lookup_idx
  on public.approval_rules (org_id, entity_kind, min_amount)
  where is_active;

-- ---------------------------------------------------------------------
-- One request per thing being approved, and a step per approver
-- ---------------------------------------------------------------------
create table public.approval_requests (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  entity_kind app.approval_entity not null,
  -- Deliberately not a foreign key. It points at one of three tables,
  -- and the alternative — three nullable columns with a check — makes
  -- every query in this file a case statement. The functions below are
  -- the only things that write it and each resolves the row first.
  entity_id   uuid not null,
  doc_no      text,
  amount      numeric(18, 2) not null default 0,
  status      app.approval_status not null default 'pending',
  requested_by uuid references auth.users(id),
  requested_at timestamptz not null default now(),
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);

-- One live request per document. A rejected one may be resubmitted —
-- that is the normal way a document gets fixed and sent round again —
-- so the uniqueness is on the pending ones only.
create unique index approval_requests_live_idx
  on public.approval_requests (org_id, entity_kind, entity_id)
  where status = 'pending';

create index approval_requests_entity_idx
  on public.approval_requests (org_id, entity_kind, entity_id, status);

create table public.approval_steps (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  request_id  uuid not null references public.approval_requests(id)
                on delete cascade,
  step_no     smallint not null,
  approver_role app.member_role,
  approver_user_id uuid references auth.users(id) on delete set null,
  status      app.approval_status not null default 'pending',
  decided_by  uuid references auth.users(id),
  decided_at  timestamptz,
  note        text,
  unique (request_id, step_no)
);

alter table public.approval_requests
  add constraint approval_requests_org_id_id_key unique (org_id, id);
alter table public.approval_steps
  add constraint approval_steps_request_same_org
  foreign key (org_id, request_id)
  references public.approval_requests (org_id, id) on delete cascade;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['approval_rules', 'approval_requests',
                           'approval_steps'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_org_member(org_id))', t || '_select', t);
    execute format(
      'grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- Who may write what differs by table, so these are not looped.
-- Rules are policy: only an administrator sets them, or somebody could
-- write themselves out of the chain that governs them.
create policy approval_rules_write on public.approval_rules
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

-- Requests and steps are written by the functions below, which are
-- SECURITY DEFINER. Nothing writes them directly: a member who could
-- update `approval_steps` could approve their own document by hand.
create policy approval_requests_none on public.approval_requests
  for all to authenticated using (false) with check (false);
create policy approval_steps_none on public.approval_steps
  for all to authenticated using (false) with check (false);

-- ---------------------------------------------------------------------
-- Does this need approving?
--
-- The question every gate asks first, and the reason this migration is
-- inert until somebody writes a rule.
-- ---------------------------------------------------------------------
create or replace function app.approval_required(
  p_org_id uuid,
  p_kind app.approval_entity,
  p_doc_type text,
  p_amount numeric)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.approval_rules r
     where r.org_id = p_org_id
       and r.entity_kind = p_kind
       and r.is_active
       and (r.doc_type is null or r.doc_type = p_doc_type)
       and coalesce(p_amount, 0) >= r.min_amount);
$$;

create or replace function app.is_approved(
  p_org_id uuid,
  p_kind app.approval_entity,
  p_entity_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.approval_requests q
     where q.org_id = p_org_id and q.entity_kind = p_kind
       and q.entity_id = p_entity_id and q.status = 'approved');
$$;

-- ---------------------------------------------------------------------
-- Send it round
-- ---------------------------------------------------------------------
create or replace function public.submit_for_approval(
  p_kind app.approval_entity,
  p_entity_id uuid)
returns uuid language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_org uuid; v_type text; v_amount numeric(18, 2); v_no text;
  v_request uuid; r record; v_steps integer := 0;
begin
  -- Resolve the thing being approved. Three tables, and this is the one
  -- place that has to know which.
  if p_kind = 'sales_document' then
    select d.org_id, d.doc_type::text, d.total_amount, d.doc_no
      into v_org, v_type, v_amount, v_no
      from public.sales_documents d where d.id = p_entity_id;
  elsif p_kind = 'purchase_document' then
    select d.org_id, d.doc_type::text, d.total_amount, d.doc_no
      into v_org, v_type, v_amount, v_no
      from public.purchase_documents d where d.id = p_entity_id;
  else
    select e.org_id, e.source::text,
           (select coalesce(sum(l.debit), 0) from public.gl_lines l
             where l.entry_id = e.id),
           e.entry_no
      into v_org, v_type, v_amount, v_no
      from public.gl_entries e where e.id = p_entity_id;
  end if;

  if v_org is null then
    raise exception 'No such document' using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'You may not submit this' using errcode = '42501';
  end if;
  if not app.approval_required(v_org, p_kind, v_type, v_amount) then
    raise exception
      'Nothing needs approving here — no rule covers a % of %.',
      p_kind, v_amount using errcode = '22023';
  end if;
  if app.is_approved(v_org, p_kind, p_entity_id) then
    raise exception 'This has already been approved' using errcode = '22023';
  end if;

  insert into public.approval_requests
    (org_id, entity_kind, entity_id, doc_no, amount, requested_by)
  values (v_org, p_kind, p_entity_id, v_no, coalesce(v_amount, 0), auth.uid())
  returning id into v_request;

  -- A step per matching rule, in the order the rules give. Two rules on
  -- the same step number would be two approvers at one stage; the
  -- `unique (request_id, step_no)` above makes that a configuration
  -- error rather than a silent half-chain, and it is caught here rather
  -- than by whoever tries to approve it.
  for r in
    select distinct on (rl.step_no) rl.step_no, rl.approver_role,
           rl.approver_user_id
      from public.approval_rules rl
     where rl.org_id = v_org and rl.entity_kind = p_kind and rl.is_active
       and (rl.doc_type is null or rl.doc_type = v_type)
       and coalesce(v_amount, 0) >= rl.min_amount
     order by rl.step_no, rl.created_at
  loop
    insert into public.approval_steps
      (org_id, request_id, step_no, approver_role, approver_user_id)
    values (v_org, v_request, r.step_no, r.approver_role, r.approver_user_id);
    v_steps := v_steps + 1;
  end loop;

  if v_steps = 0 then
    raise exception 'No approver is configured for this' using errcode = 'P0002';
  end if;

  return v_request;
end $$;

-- ---------------------------------------------------------------------
-- Decide
--
-- Named `decide_*` with an `approve boolean`, which is how every other
-- decision in this schema is spelled — `decide_expense_claim`,
-- `decide_leave_request`, `decide_payslip_access`.
-- ---------------------------------------------------------------------
create or replace function public.decide_approval(
  p_request_id uuid,
  p_approve boolean,
  p_note text default null)
returns app.approval_status
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  q public.approval_requests;
  s public.approval_steps;
  v_left integer;
begin
  select * into q from public.approval_requests where id = p_request_id;
  if not found then
    raise exception 'No such approval request' using errcode = 'P0002';
  end if;
  if q.status <> 'pending' then
    raise exception 'That request was already %', q.status
      using errcode = '22023';
  end if;

  -- The next undecided step, and only that one. Approving out of order
  -- would let the last signatory clear a document the first has not
  -- seen, which is the entire point of having steps.
  select * into s from public.approval_steps
   where request_id = p_request_id and status = 'pending'
   order by step_no limit 1;
  if not found then
    raise exception 'Nothing left to decide on this request'
      using errcode = '22023';
  end if;

  -- May this person decide *this* step?
  if s.approver_user_id is not null then
    if s.approver_user_id <> auth.uid() then
      raise exception 'This step is somebody else''s to decide'
        using errcode = '42501';
    end if;
  elsif not app.has_org_role(q.org_id, array[s.approver_role]) then
    raise exception 'This step needs a %', s.approver_role
      using errcode = '42501';
  end if;

  -- Nobody approves their own. The commonest way an approval chain
  -- becomes decoration is the person who raised the document also
  -- holding the role that clears it.
  if q.requested_by = auth.uid() then
    raise exception
      'You raised this, so you cannot approve it. Somebody else holding '
      'the same role has to.' using errcode = '42501';
  end if;

  -- Cast explicitly. A bare CASE over two string literals is `text`,
  -- and Postgres will not coerce that into the enum on assignment.
  update public.approval_steps
     set status = case when p_approve then 'approved'::app.approval_status
                       else 'rejected'::app.approval_status end,
         decided_by = auth.uid(), decided_at = now(), note = p_note
   where id = s.id;

  if not p_approve then
    update public.approval_requests
       set status = 'rejected', decided_at = now()
     where id = p_request_id;
    return 'rejected';
  end if;

  select count(*) into v_left from public.approval_steps
   where request_id = p_request_id and status = 'pending';

  if v_left = 0 then
    update public.approval_requests
       set status = 'approved', decided_at = now()
     where id = p_request_id;
    return 'approved';
  end if;

  return 'pending';
end $$;

-- What is sitting on somebody's desk.
create or replace function public.my_approvals(p_org_id uuid)
returns table (
  request_id uuid,
  entity_kind app.approval_entity,
  entity_id uuid,
  doc_no text,
  amount numeric,
  step_no smallint,
  requested_at timestamptz,
  requested_by_name text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select q.id, q.entity_kind, q.entity_id, q.doc_no, q.amount,
           s.step_no, q.requested_at,
           coalesce(p.full_name, p.email)
      from public.approval_requests q
      join public.approval_steps s on s.request_id = q.id
      left join public.profiles p on p.id = q.requested_by
     where q.org_id = p_org_id
       and q.status = 'pending'
       and s.status = 'pending'
       -- The step in front, not any step of mine further down the chain.
       and s.step_no = (select min(s2.step_no) from public.approval_steps s2
                         where s2.request_id = q.id and s2.status = 'pending')
       and (s.approver_user_id = auth.uid()
            or (s.approver_user_id is null
                and app.has_org_role(p_org_id, array[s.approver_role])))
       -- Not my own, for the same reason `decide_approval` refuses it.
       and q.requested_by is distinct from auth.uid()
     order by q.requested_at;
end $$;

-- ---------------------------------------------------------------------
-- The gate
--
-- Enforced by trigger rather than inside the posting routines. There
-- are several ways a document reaches `posted` — the screen, a transfer,
-- a recurring schedule, a charge run — and a check written into one of
-- them is a check the others do not have. A trigger is on the table, so
-- it covers the paths nobody has written yet.
-- ---------------------------------------------------------------------
create or replace function app.refuse_unapproved_posting()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_kind app.approval_entity;
  v_type text;
  v_amount numeric;
begin
  if tg_table_name = 'gl_entries' then
    -- Only journals somebody typed. Every other entry in this table is
    -- the by-product of a document that has its own gate above, and
    -- holding those up would stop an approved invoice posting itself.
    if new.source <> 'manual' then return new; end if;
    v_kind := 'journal';
    v_type := new.source::text;
    -- The journal's value, which only exists once its lines do. This is
    -- why the trigger on `gl_entries` is deferred to commit and the
    -- other two are not: a rule reading "journals over ten thousand"
    -- cannot be evaluated at INSERT, when the entry has no lines yet and
    -- every journal would look like nothing.
    select coalesce(sum(l.debit), 0) into v_amount
      from public.gl_lines l where l.entry_id = new.id;
  else
    -- Only the transition into posted. An already-posted row being
    -- touched for any other reason is not a posting.
    if new.status <> 'posted' or coalesce(old.status, 'draft') = 'posted' then
      return new;
    end if;
    v_kind := case when tg_table_name = 'sales_documents'
                   then 'sales_document' else 'purchase_document' end;
    v_type := new.doc_type::text;
    v_amount := new.total_amount;
  end if;

  if app.approval_required(new.org_id, v_kind, v_type, v_amount)
     and not app.is_approved(new.org_id, v_kind, new.id) then
    raise exception
      'This needs approving before it can be posted. Send it for approval '
      'first.' using errcode = '42501';
  end if;

  return new;
end $$;

create trigger refuse_unapproved
  before update on public.sales_documents
  for each row execute function app.refuse_unapproved_posting();
create trigger refuse_unapproved
  before update on public.purchase_documents
  for each row execute function app.refuse_unapproved_posting();
-- Deferred, so the lines are in by the time it looks. `assert_balanced`
-- on `gl_lines` is deferred for the same reason and is the precedent.
create constraint trigger refuse_unapproved
  after insert on public.gl_entries
  deferrable initially deferred
  for each row execute function app.refuse_unapproved_posting();

grant execute on function app.approval_required(
  uuid, app.approval_entity, text, numeric) to authenticated;
grant execute on function app.is_approved(
  uuid, app.approval_entity, uuid) to authenticated;
grant execute on function public.submit_for_approval(
  app.approval_entity, uuid) to authenticated;
grant execute on function public.decide_approval(uuid, boolean, text)
  to authenticated;
grant execute on function public.my_approvals(uuid) to authenticated;
