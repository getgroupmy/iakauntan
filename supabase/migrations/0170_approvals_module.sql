-- Sell approvals as an add-on.
--
-- `0167` deliberately shipped this ungated, on the reasoning that
-- deciding who may reach the ledger is not a product a company buys but
-- how a company that already has the ledger governs it. That is a fair
-- argument and it is not the one being made here: an approval chain is
-- the thing a company with more than one pair of hands pays for, and
-- charging for it is a pricing decision, not an architectural one.
--
-- **The interesting part is what happens when the entitlement lapses.**
--
-- Every other module here fails *closed*: switch off inventory and new
-- stock movements are refused. Approvals must fail **open**, and the
-- reason is the gate. `refuse_unapproved` stops a document posting until
-- its chain is complete. If a lapsed entitlement left the gate biting
-- while taking away the screen that clears it, a company whose card
-- expired would find every invoice above its own threshold permanently
-- unpostable and no way in the product to release them. That is not a
-- degraded module; it is a ledger held hostage to a billing failure.
--
-- So `app.approval_required` — the question every gate asks first —
-- answers false when the module is off. The workflow returns to exactly
-- the state `0167` shipped in: inert. Rules are kept, not deleted, so
-- switching it back on restores the chain that was configured rather
-- than an empty screen.
--
-- **Every existing tenant keeps it**, by the same insert every other
-- module migration ends with. Nothing on this deployment has an approval
-- rule yet, so no chain changes either way.

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('approvals', 'Approvals',
   'Approval chains for sales documents, purchase documents and manual '
   'journals, with a per-role or per-person signature required before '
   'anything reaches the ledger',
   false, 29, 16)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- The guard
--
-- One function, and it is the only place the entitlement is consulted.
-- `submit_for_approval` already refuses when nothing needs approving,
-- and `refuse_unapproved` already lets a document through when nothing
-- needs approving, so both follow from this without being touched.
-- ---------------------------------------------------------------------
create or replace function app.approval_required(
  p_org_id uuid,
  p_kind app.approval_entity,
  p_doc_type text,
  p_amount numeric)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select app.has_module(p_org_id, 'approvals')
     and exists (
    select 1 from public.approval_rules r
     where r.org_id = p_org_id
       and r.entity_kind = p_kind
       and r.is_active
       and (r.doc_type is null or r.doc_type = p_doc_type)
       and coalesce(p_amount, 0) >= r.min_amount);
$$;

-- ---------------------------------------------------------------------
-- Rules are policy, and policy is bought
--
-- Writes need the entitlement as well as the role. Reads do not: a
-- company whose subscription lapsed should still be able to see the
-- chain it had, which is also the chain it gets back on renewing.
-- ---------------------------------------------------------------------
drop policy if exists approval_rules_write on public.approval_rules;

create policy approval_rules_write on public.approval_rules
  for all to authenticated
  using (app.can_admin(org_id) and app.has_module(org_id, 'approvals'))
  with check (app.can_admin(org_id) and app.has_module(org_id, 'approvals'));

-- The access-type layer from 0127, so a company can keep a member out of
-- the approvals screen without taking it off the company. Only on the
-- rules: `approval_requests` and `approval_steps` are unreadable
-- directly by anybody — their policies are `using (false)` — and reach
-- the screen through `my_approvals`, which is SECURITY DEFINER and does
-- its own scoping.
create policy module_gate_select on public.approval_rules
  as restrictive for select to authenticated
  using (app.can_read_module(org_id, 'approvals'));
create policy module_gate_write on public.approval_rules
  as restrictive for all to authenticated
  using (app.can_write_module(org_id, 'approvals'))
  with check (app.can_write_module(org_id, 'approvals'));

-- ---------------------------------------------------------------------
-- Deliberately *not* gated: finishing what you started
--
-- `decide_approval` and `my_approvals` keep working with the module off.
-- A request already in flight when the entitlement lapsed can still be
-- cleared or rejected, so nobody is left with an inbox they cannot empty.
-- Nothing new can enter it — `submit_for_approval` asks
-- `approval_required` first — so the queue drains and stays drained.
-- ---------------------------------------------------------------------

-- Nobody loses a workflow they are already using.
insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
select o.id, 'approvals', true, now()
  from public.organizations o
on conflict (org_id, module_code) do nothing;
