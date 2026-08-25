-- Attachments become a module of their own.
--
-- Every company on the platform can attach a file to a bill, an expense
-- claim, an invoice or an employee, and always could — it was part of
-- keeping books rather than something anybody chose. Asked for as a
-- module, so it becomes one: storage costs money per gigabyte per month
-- for as long as the document exists, which is a different shape of
-- cost from the rest of the product and worth pricing as itself.
--
-- ## One guard, four doors
--
-- The obvious version of this touches four policies: inserting an
-- attachment row, deleting one, uploading the file, deleting the file.
-- It does not need to. All four already ask `app.can_attach_to`, which
-- is the single place that decides whether this person may put a
-- document against this record — so the module check goes inside it and
-- every door closes at once.
--
-- The two that do not go through it are renaming and moving a file,
-- which ask `app.can_write`. That one is the ordinary bookkeeping
-- permission used by a hundred other tables and must not learn about
-- attachments, so those two policies get the module check written into
-- them directly.
--
-- ## Reading is deliberately not gated
--
-- `app.can_read_attachment` is untouched, so a document uploaded before
-- today stays readable by everybody who could read it yesterday. A
-- company that does not take the module cannot add another file; it
-- does not lose the ones it has. Withdrawing access to a receipt
-- somebody attached to a claim two years ago would be taking away their
-- records, not selling them a feature — and the auditor asking for it
-- has no module.
--
-- ## Nobody is granted it
--
-- Asked for explicitly, and it is the sharp option: every company, old
-- and new, has to have `attachments` switched on before anybody can
-- upload again. The alternative — granting it to everyone already using
-- it — would have made the module invisible to exactly the customers it
-- is meant to be sold to.
--
-- Two consequences worth saying out loud rather than discovering:
-- existing customers lose the ability to add files until somebody
-- enables it for them, and the demo tenants are companies like any
-- other, so the demonstration of attaching a receipt is off until the
-- module is switched on for them too.

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values
  ('attachments', 'Document attachments',
   'Keep the paperwork against the record it belongs to - a supplier '
   'invoice on the bill, a receipt on the claim, a contract on the '
   'employee. Files stay readable whether or not the module is on; '
   'adding new ones needs it.',
   false, 19.00, 100, true)
on conflict (code) do update
  set name          = excluded.name,
      description   = excluded.description,
      monthly_price = excluded.monthly_price,
      is_active     = excluded.is_active;

-- ---------------------------------------------------------------------
-- The one guard every writer already asks
--
-- Restated in full rather than derived. `0231` moved thirteen guards by
-- rewriting `pg_get_functiondef` output because thirteen bodies pasted
-- into a migration is a diff nobody can check; one body is a diff
-- anybody can read, and reading beats cleverness at this size.
--
-- The check goes first, before the null test even, because it is the
-- cheapest and the most absolute: no module, no writing, whoever is
-- asking.
-- ---------------------------------------------------------------------
create or replace function app.can_attach_to(
  p_org_id uuid, p_entity_table text, p_entity_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, app, pg_temp as $$
declare v_employee uuid;
begin
  if p_org_id is null or p_entity_id is null then return false; end if;

  -- 0323. The module. Reading is decided by
  -- `app.can_read_attachment`, which does not ask this and is
  -- deliberately left open: a company that stops paying keeps its
  -- documents, it just cannot add more.
  if not app.has_module(p_org_id, 'attachments') then return false; end if;

  -- Everybody who could before.
  if app.can_write(p_org_id) then return true; end if;
  if app.can_manage_hr(p_org_id) then return true; end if;

  -- Otherwise: the person the record is about, on the records that are
  -- theirs to support.
  select e.id into v_employee
    from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid();
  if v_employee is null then return false; end if;

  return case p_entity_table
    -- While it can still matter. Once a claim is in the ledger the
    -- paperwork behind it is the accountant's record, not a document
    -- the claimant can still add to.
    when 'expense_claims' then exists (
      select 1 from public.expense_claims c
       where c.id = p_entity_id
         and c.employee_id = v_employee
         and c.posted_at is null)
    when 'leave_requests' then exists (
      select 1 from public.leave_requests r
       where r.id = p_entity_id
         and r.employee_id = v_employee)
    else false
  end;
end; $$;

-- `0165`'s event trigger strips privileges from anything created or
-- replaced in `public` or `app`, and a policy calling a function it may
-- not execute fails closed — which here would lock every company out of
-- their own attachments rather than just the ones without the module.
revoke all on function app.can_attach_to(uuid, text, uuid) from public;
grant execute on function app.can_attach_to(uuid, text, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- And the two that ask a different question
--
-- Renaming an attachment row and moving the file behind it both go
-- through `app.can_write`, the ordinary bookkeeping permission. It is
-- used by a hundred other tables and must not learn what an attachment
-- is, so the module check is written into these two policies instead.
-- ---------------------------------------------------------------------
drop policy if exists attachments_update on public.attachments;
create policy attachments_update on public.attachments
  for update to authenticated
  using (app.can_write(org_id) and app.has_module(org_id, 'attachments'))
  with check (app.can_write(org_id) and app.has_module(org_id, 'attachments'));

drop policy if exists attachments_move on storage.objects;
create policy attachments_move on storage.objects
  for update to authenticated
  using (
    bucket_id = 'attachments'
    and app.can_write(app.uuid_or_null(split_part(name, '/', 1)))
    and app.has_module(
          app.uuid_or_null(split_part(name, '/', 1)), 'attachments'))
  with check (
    bucket_id = 'attachments'
    and app.can_write(app.uuid_or_null(split_part(name, '/', 1)))
    and app.has_module(
          app.uuid_or_null(split_part(name, '/', 1)), 'attachments'));
