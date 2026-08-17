-- `0183` fixed the parent and missed the children.
--
-- `0183` stopped the audit trigger writing a row for a tenant's own
-- deletion. CI still refused the teardown, with the identical foreign
-- key error, and the reason is one I should have seen the first time:
--
--     the row being audited was never `organizations`.
--
-- Deleting a company cascades into 165 child tables, 22 of which carry
-- the `audit_changes` trigger — `org_members`, `accounts`, `tax_codes`,
-- `employees`, the whole `corp_*` family. Each cascaded delete fires the
-- trigger, and each writes an `audit_logs` row stamped with the `org_id`
-- of the company that has just gone. `0183` guarded the parent row and
-- left every one of those.
--
-- Diagnosed by reproducing it rather than by reading: the migrations
-- could not be applied to the hosted project (the failing database job
-- gates the migrate job, so `0182` and `0183` never left CI), and the
-- GitHub API was returning 403 on the jobs endpoint, so the run log was
-- unreadable. The fix and its controls were exercised against the hosted
-- project inside a transaction that rolled back.
--
-- ## The general form
--
-- Not "is this the organizations table" but "is the company this row
-- belongs to still there". On a delete, if it is not, the audit row has
-- nothing to hang on and is skipped. That covers the parent and every
-- child behind it, and it needs no list of cascading tables to be kept
-- in step — a table added next year is covered by the same three lines.
--
-- The cost is one indexed lookup per audited delete, and only on
-- deletes. Updates and inserts are untouched.
--
-- ## What it must not do
--
-- Silently stop auditing ordinary deletions. A row deleted from a
-- company that still exists must still be recorded, and the test now
-- proves it against `tax_codes` — an audited table, which `contacts`
-- (the first control written here) is not, so that control would have
-- passed by measuring nothing.

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
  -- organizations is its own tenant; everything else names one.
  if TG_TABLE_NAME = 'organizations' then
    v_org := (v_row ->> 'id')::uuid;
  else
    v_org := nullif(v_row ->> 'org_id', '')::uuid;
  end if;

  -- On a delete, if the company this row belonged to has already gone,
  -- there is nothing for the audit row's foreign key to point at. This
  -- covers the tenant's own row *and* every child swept out by the
  -- cascade behind it. See the header for why 0183's narrower form was
  -- not enough.
  if TG_OP = 'DELETE' and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return null;
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
