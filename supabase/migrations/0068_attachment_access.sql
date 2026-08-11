-- =====================================================================
-- iAkauntan :: 0068 an attachment inherits what it hangs off
--
-- Both the attachments table and the storage bucket let any member of
-- the organization read any file. That was harmless while nothing could
-- upload; it stops being harmless the moment the client can. A scan of a
-- payslip, an employee's passport or a director's NRIC would have been
-- readable by every signed-in colleague — which undoes the payslip
-- access rules by the simple expedient of attaching a photograph.
--
-- The path is <org>/<table>/<record>/<file> and that is not decoration:
-- the storage policies read the organization, the table and the record
-- straight out of the object name, and a trigger refuses any row whose
-- path disagrees with its own columns.
-- =====================================================================

-- Casting a path segment straight to uuid raises rather than denies when
-- somebody uploads to a malformed path, which turns a permission
-- decision into a 500.
create or replace function app.uuid_or_null(p_text text)
returns uuid language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
begin
  return nullif(p_text, '')::uuid;
exception when others then
  return null;
end;
$$;

create or replace function app.can_read_attachment(
  p_org_id uuid, p_entity_table text, p_entity_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_employee uuid;
begin
  if p_org_id is null then return false; end if;

  if app.can_write(p_org_id) or app.can_read_ledger(p_org_id) then
    -- …except the personnel records, which the ledger audience has no
    -- business in. An accounts clerk does not get to read a passport.
    if p_entity_table in ('employees', 'employee_documents', 'payslips',
                          'corp_persons') then
      return app.can_manage_hr(p_org_id) or app.can_admin(p_org_id)
          or app.can_run_payroll(p_org_id);
    end if;
    return true;
  end if;

  if app.can_manage_hr(p_org_id) then return true; end if;

  -- Otherwise: the person it is about, and nobody else.
  select e.id into v_employee
    from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid();
  if v_employee is null then return false; end if;

  return case p_entity_table
    when 'employees' then p_entity_id = v_employee
    when 'employee_documents' then exists (
      select 1 from public.employee_documents d
       where d.id = p_entity_id and d.employee_id = v_employee)
    when 'expense_claims' then exists (
      select 1 from public.expense_claims c
       where c.id = p_entity_id and c.employee_id = v_employee)
    when 'leave_requests' then exists (
      select 1 from public.leave_requests r
       where r.id = p_entity_id and r.employee_id = v_employee)
    when 'payslips' then exists (
      select 1 from public.payslips p
       where p.id = p_entity_id and p.employee_id = v_employee)
    else false
  end;
end;
$$;

revoke all on function app.can_read_attachment(uuid, text, uuid) from public, anon;
grant execute on function app.can_read_attachment(uuid, text, uuid)
  to authenticated, service_role;
revoke all on function app.uuid_or_null(text) from public, anon;
grant execute on function app.uuid_or_null(text) to authenticated, service_role;

drop policy if exists attachments_select on public.attachments;
create policy attachments_select on public.attachments
  for select using (app.can_read_attachment(org_id, entity_table, entity_id));

create or replace function app.attachment_path_ok()
returns trigger language plpgsql
set search_path = public, app, pg_temp as $$
begin
  if NEW.storage_path is distinct from format('%s/%s/%s/%s',
       NEW.org_id, NEW.entity_table, NEW.entity_id,
       split_part(NEW.storage_path, '/', 4))
     or split_part(NEW.storage_path, '/', 4) = ''
     or split_part(NEW.storage_path, '/', 5) <> '' then
    raise exception
      'An attachment path must be <org>/<table>/<record>/<file>, got %',
      NEW.storage_path using errcode = '22023';
  end if;
  return NEW;
end;
$$;

drop trigger if exists attachment_path_ok on public.attachments;
create trigger attachment_path_ok before insert or update on public.attachments
  for each row execute function app.attachment_path_ok();

-- The bucket now answers the same question the table does.
drop policy if exists attachments_read on storage.objects;
create policy attachments_read on storage.objects
  for select using (
    bucket_id = 'attachments'
    and app.can_read_attachment(
          app.uuid_or_null(split_part(name, '/', 1)),
          split_part(name, '/', 2),
          app.uuid_or_null(split_part(name, '/', 3))));

drop policy if exists attachments_write on storage.objects;
create policy attachments_write on storage.objects
  for insert with check (
    bucket_id = 'attachments'
    and app.can_write(app.uuid_or_null(split_part(name, '/', 1)))
    and split_part(name, '/', 2) <> ''
    and app.uuid_or_null(split_part(name, '/', 3)) is not null
    and split_part(name, '/', 4) <> '');

drop policy if exists attachments_delete on storage.objects;
create policy attachments_delete on storage.objects
  for delete using (
    bucket_id = 'attachments'
    and app.can_write(app.uuid_or_null(split_part(name, '/', 1))));
