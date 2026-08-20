-- ---------------------------------------------------------------------
-- 0237  A log must not block the deletion it records
-- ---------------------------------------------------------------------
--
-- 0236 put the audit trigger on thirteen more tables, and deleting an
-- organization stopped working:
--
--     ERROR: insert or update on table "audit_logs" violates foreign key
--            constraint "audit_logs_org_id_fkey"
--     DETAIL: Key (org_id)=(bab48f97-...) is not present in table
--             "organizations".
--     CONTEXT: write_audit_log() line 45
--              "delete from public.organizations where id = any (v_orgs)"
--              demo_teardown() line 67
--
-- Reproduced on production before fixing it: put the trigger on
-- `contacts`, give a company one contact, delete the company, and the
-- delete fails.
--
-- ## Why the twenty-five that were already audited did not do this
--
-- `demo_teardown` deletes their rows explicitly, in order, while the
-- organization still exists -- so their triggers fire against a parent
-- that is still there and the org's own delete finds those tables
-- already empty. The thirteen 0236 added are not on that list, so they
-- are left to `on delete cascade`, which runs *after* the parent row is
-- gone. The trigger then writes an audit row naming an organization that
-- no longer exists, and `audit_logs.org_id` refuses it.
--
-- This is not a demo-teardown problem. Any deletion of an organization
-- that has a contact, an invoice, an item or an expense hits it.
--
-- ## Why skipping the row loses nothing
--
-- `audit_logs.org_id` is `on delete cascade`. Every audit row belonging
-- to that organization is being deleted by the same statement, so a row
-- written now could not survive it -- it would be inserted and
-- immediately cascaded away. Measured on production: across 1,988 audit
-- rows there is not one `delete` of an `organizations` row, and none of
-- any kind. The record was never being kept; the insert was only ever
-- either doomed or fatal.
--
-- So when the organization is already gone, the trigger declines to
-- write. The test is confined to DELETE because on INSERT and UPDATE the
-- source row's own foreign key guarantees the organization exists --
-- which keeps the extra lookup off the path every invoice, contact and
-- item takes.
--
-- The rule this is the third instance of, and it is worth naming: a log
-- must never be able to block the thing it is recording.
-- `security_events.user_id` dropped its foreign key for the same reason
-- in 0235, and `record_session_end` stopped joining `auth.users` for the
-- same reason again.

create or replace function app.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_old  jsonb := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
  v_new  jsonb := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
  v_row  jsonb := coalesce(v_new, v_old);
  v_org  uuid;
  v_id   uuid;
  v_from jsonb;
  v_to   jsonb;
begin
  if TG_TABLE_NAME = 'organizations' then
    v_org := (v_row ->> 'id')::uuid;
  elsif TG_TABLE_NAME = 'access_type_modules' then
    select t.org_id into v_org
      from public.access_types t
     where t.id = (v_row ->> 'access_type_id')::uuid;
  else
    v_org := nullif(v_row ->> 'org_id', '')::uuid;
  end if;

  -- The company is already gone: this row is cascading away behind it.
  -- Only on DELETE, because an insert or an update cannot name an
  -- organization that does not exist -- the source row's own foreign key
  -- has already said so -- and this must not cost a lookup on the path
  -- every invoice takes.
  if TG_OP = 'DELETE'
     and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return null;
  end if;

  begin
    v_id := nullif(v_row ->> 'id', '')::uuid;
  exception when others then
    v_id := null;   -- a table keyed on something other than a uuid
  end;

  if v_id is null and TG_TABLE_NAME = 'access_type_modules' then
    v_id := (v_row ->> 'access_type_id')::uuid;
  end if;

  if TG_OP = 'UPDATE' then
    v_to := app.audit_diff(v_old, v_new);
    -- A write that changed nothing is not an event.
    if v_to = '{}'::jsonb then return null; end if;
    v_from := app.audit_diff(v_new, v_old);
  else
    v_from := app.audit_redact(v_old);
    v_to := app.audit_redact(v_new);
  end if;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data,
     ip_address, user_agent)
  values (v_org, auth.uid(), TG_TABLE_NAME, v_id, lower(TG_OP), v_from, v_to,
          nullif(split_part(coalesce(
            app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet,
          app.request_header('user-agent'));

  return null;
end;
$$;

revoke all on function app.write_audit_log() from public, anon, authenticated;
