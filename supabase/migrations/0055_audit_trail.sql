-- =====================================================================
-- iAkauntan :: 0055 an audit trail that is actually written
--
-- audit_logs existed with a select policy, no write policy, and no
-- writer at all: zero rows, and no insert anywhere in the schema. There
-- was no history of who changed a salary, a bank account or somebody's
-- access — conspicuous next to payslip_access_log, which records every
-- auditor's glance.
--
-- Same shape as that log: a SECURITY DEFINER trigger writes it, and
-- there is still no insert, update or delete policy, so nobody edits it
-- afterwards.
-- =====================================================================

-- Only the columns that actually moved, so an update to one field does
-- not store two copies of the whole row. Timestamps the database
-- maintains are not news.
create or replace function app.audit_diff(p_old jsonb, p_new jsonb)
returns jsonb language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from jsonb_each(p_new)
   where key not in ('updated_at', 'created_at')
     and p_old -> key is distinct from value;
$$;

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

revoke all on function app.write_audit_log() from public, anon, authenticated;

-- The tables where a quiet change would matter. Deliberately not every
-- table: an audit trail nobody reads because it is mostly invoice lines
-- is the same as no audit trail.
do $do$
declare t text;
begin
  foreach t in array array[
    'employees', 'employee_salary_components', 'employee_ytd_opening',
    'employee_tax_reliefs', 'salary_components', 'payroll_settings',
    'bank_accounts', 'accounts', 'tax_codes', 'fiscal_periods',
    'org_members', 'org_modules', 'organizations']
  loop
    execute format('drop trigger if exists audit_changes on public.%I', t);
    execute format(
      'create trigger audit_changes after insert or update or delete on public.%I
         for each row execute function app.write_audit_log()', t);
  end loop;
end
$do$;

-- Tightened from can_read_ledger. The log carries salaries, bank account
-- numbers and statutory identifiers in its diffs, and the whole point of
-- the payslip access work is that an auditor does not get those without
-- an approved request. Owners and admins only.
drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select using (app.can_admin(org_id));

create or replace function public.audit_trail(
  p_org_id uuid, p_table text default null, p_record_id uuid default null,
  p_limit integer default 100)
returns table (
  id bigint, at timestamptz, actor text, action text,
  table_name text, record_id uuid, changes jsonb)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the audit trail'
      using errcode = '42501';
  end if;

  return query
  select l.id, l.created_at,
         coalesce(p.full_name, p.email, 'system'),
         l.action, l.table_name, l.record_id,
         jsonb_build_object('from', l.old_data, 'to', l.new_data)
    from public.audit_logs l
    left join public.profiles p on p.id = l.user_id
   where l.org_id = p_org_id
     and (p_table is null or l.table_name = p_table)
     and (p_record_id is null or l.record_id = p_record_id)
   order by l.id desc
   limit least(coalesce(p_limit, 100), 500);
end;
$$;

do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;
