-- No organization on this deployment could be deleted, by anybody.
--
-- `0182` added a teardown for demo tenants and CI refused it:
--
--     ERROR: insert or update on table "audit_logs" violates foreign key
--            constraint "audit_logs_org_id_fkey"
--     DETAIL: Key (org_id)=(...) is not present in table "organizations".
--     CONTEXT: PL/pgSQL function write_audit_log() line 34
--              SQL statement "delete from public.organizations ..."
--
-- The `audit_changes` trigger fires on delete and writes an `audit_logs`
-- row recording it. For every other table that row names the owning
-- company. For `organizations` it names *the row being deleted*, which
-- by then is gone — so the insert fails and takes the delete with it.
--
-- This is not a fault in `0182`. It is older than `0182` and wider:
-- `organizations_delete` grants owners a delete policy, so an owner
-- pressing "delete this company" has always hit the same foreign key.
-- Nothing had ever tried.
--
-- ## Why the audit row is dropped rather than preserved
--
-- The first instinct was the opposite — loosen the foreign key so the
-- record of a deletion outlives the company, on the grounds that an
-- audit trail with a hole where deletions go is the wrong shape. That
-- reasoning does not survive contact with the schema:
--
--   * `audit_logs.org_id` is **`on delete cascade`**. Deleting a company
--     already removes its entire audit history. A row recording the
--     deletion would be deleted by the very statement that caused it.
--   * `audit_logs` is read through RLS scoped by `org_id`. With the
--     company gone there is no member, no policy match, and no reader.
--
-- So the row cannot be written, could not be read if it were, and would
-- be deleted immediately if it survived being read. Keeping it is not a
-- stricter audit trail, it is an unreachable write. The honest record of
-- "this tenant was removed" belongs in the platform-level tables that
-- are not scoped to the tenant — `platform_invoices` and friends — and
-- that is a separate piece of work, deliberately not invented here.
--
-- The guard is therefore exact: `organizations` **and** `DELETE`. Every
-- other audit event on `organizations`, including every update, is
-- written exactly as before, and no other table is affected.
--
-- Restated from `0055` mechanically rather than retyped; the diff is the
-- five added lines and nothing else.

create or replace function app.write_audit_log()
returns trigger language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_old  jsonb := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
  v_new  jsonb := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
  v_row  jsonb := coalesce(v_new, v_old);
  v_org  uuid;
  v_id   uuid;
  v_from jsonb;
  v_to   jsonb;
begin
  -- A tenant being deleted cannot be audited into its own audit trail.
  -- See the header: the row is unwritable, and would be unreadable and
  -- already deleted even if it could be written.
  if TG_TABLE_NAME = 'organizations' and TG_OP = 'DELETE' then
    return null;
  end if;

  -- organizations is its own tenant; everything else names one.
  if TG_TABLE_NAME = 'organizations' then
    v_org := (v_row ->> 'id')::uuid;
  else
    v_org := nullif(v_row ->> 'org_id', '')::uuid;
  end if;

  begin
    v_id := nullif(v_row ->> 'id', '')::uuid;
  exception when others then
    v_id := null;   -- a table keyed on something other than a uuid
  end;

  if TG_OP = 'UPDATE' then
    v_to := app.audit_diff(v_old, v_new);
    -- A write that changed nothing is not an event.
    if v_to = '{}'::jsonb then return null; end if;
    v_from := app.audit_diff(v_new, v_old);
  else
    v_from := v_old;
    v_to := v_new;
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
