-- The receipt belongs with the claim
--
-- A claim is a request to be paid back for money somebody has already
-- spent, and the evidence is the receipt. `expense_claims` has been a
-- readable attachment entity since attachments existed — an employee can
-- *see* what is filed against their own claim — but nobody without
-- `can_write` on the organization could put it there, and an ordinary
-- employee does not have `can_write`. So the one person who has the
-- receipt in their hand was the one person who could not attach it.
--
-- This lets them, and no further.

-- Who may file a document against a record.
--
-- The mirror of `app.can_read_attachment`, which has always been more
-- generous than the write side. Same shape on purpose: the two are read
-- together and a difference between them should be visible at a glance.
create or replace function app.can_attach_to(
  p_org_id uuid, p_entity_table text, p_entity_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_employee uuid;
begin
  if p_org_id is null or p_entity_id is null then return false; end if;

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

revoke all on function app.can_attach_to(uuid, text, uuid) from public, anon;
grant execute on function app.can_attach_to(uuid, text, uuid) to authenticated;

-- The row.
drop policy if exists attachments_insert on public.attachments;
create policy attachments_insert on public.attachments
  for insert to authenticated
  with check (app.can_attach_to(org_id, entity_table, entity_id));

-- Removing one, on the same terms. Somebody who photographed the wrong
-- side of a receipt has to be able to take it off again; once the claim
-- is posted, neither.
drop policy if exists attachments_delete on public.attachments;
create policy attachments_delete on public.attachments
  for delete to authenticated
  using (app.can_attach_to(org_id, entity_table, entity_id));

-- And the object behind it. Both halves have to agree: a row nobody can
-- write is useless, and an object with no row is invisible.
--
-- The name is `org/table/record/file`, which is what the storage
-- policies have always read the permission out of.
drop policy if exists attachments_write on storage.objects;
create policy attachments_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'attachments'
    and app.can_attach_to(
      app.uuid_or_null(split_part(name, '/', 1)),
      split_part(name, '/', 2),
      app.uuid_or_null(split_part(name, '/', 3)))
    and split_part(name, '/', 2) <> ''
    and app.uuid_or_null(split_part(name, '/', 3)) is not null
    and split_part(name, '/', 4) <> '');

drop policy if exists attachments_delete on storage.objects;
create policy attachments_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'attachments'
    and app.can_attach_to(
      app.uuid_or_null(split_part(name, '/', 1)),
      split_part(name, '/', 2),
      app.uuid_or_null(split_part(name, '/', 3))));

-- `attachments_move` is deliberately left alone. Moving an object from a
-- placeholder onto a saved record is how a scanned bill is filed, and
-- that is staff work — an employee attaching to their own claim uploads
-- against the claim itself, which already exists by then, and never
-- needs to move anything.
