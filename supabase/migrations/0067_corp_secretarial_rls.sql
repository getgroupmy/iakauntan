-- =====================================================================
-- iAkauntan :: 0067 who may see and change the registers
-- =====================================================================

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values ('secretarial', 'Corporate Secretarial',
        'Statutory registers, SSM deadlines, resolutions and document '
        'generation under the Companies Act 2016',
        false, 79.00, 11, true)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  monthly_price = excluded.monthly_price, sort_order = excluded.sort_order;

-- Reference data everyone may read: the sections of the Act are not a
-- trade secret, and the client needs them to label a deadline.
alter table public.corp_filing_types enable row level security;
drop policy if exists corp_filing_types_read on public.corp_filing_types;
create policy corp_filing_types_read on public.corp_filing_types
  for select using (true);

-- Platform templates are readable by anyone signed in; a firm's own
-- templates only by that firm.
alter table public.corp_templates enable row level security;
drop policy if exists corp_templates_read on public.corp_templates;
create policy corp_templates_read on public.corp_templates
  for select using (org_id is null or app.is_org_member(org_id));
drop policy if exists corp_templates_write on public.corp_templates;
create policy corp_templates_write on public.corp_templates
  for all using (org_id is not null and app.can_write(org_id))
  with check (org_id is not null and app.can_write(org_id)
              and app.has_module(org_id, 'secretarial'));

-- Everything else is ordinary tenant data. Reading follows can_write's
-- audience plus the auditor, because a statutory register is exactly
-- what an auditor is entitled to inspect; writing additionally requires
-- the module.
do $do$
declare t text;
begin
  foreach t in array array[
    'corp_entities', 'corp_persons', 'corp_officers', 'corp_share_classes',
    'corp_share_events', 'corp_beneficial_owners', 'corp_charges',
    'corp_resolutions', 'corp_filings', 'corp_documents']
  loop
    execute format('alter table public.%I enable row level security', t);

    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format(
      'create policy %I on public.%I for select
         using (app.can_read_ledger(org_id) or app.can_write(org_id))',
      t || '_select', t);

    execute format('drop policy if exists %I on public.%I', t || '_write', t);
    execute format(
      'create policy %I on public.%I for all
         using (app.can_write(org_id))
         with check (app.can_write(org_id) and app.has_module(org_id, ''secretarial''))',
      t || '_write', t);
  end loop;
end
$do$;

-- The registers are precisely the records where a quiet change matters,
-- so they join the audit trail alongside employees and bank accounts.
do $do$
declare t text;
begin
  foreach t in array array[
    'corp_entities', 'corp_persons', 'corp_officers', 'corp_share_events',
    'corp_beneficial_owners', 'corp_charges', 'corp_filings']
  loop
    execute format('drop trigger if exists audit_changes on public.%I', t);
    execute format(
      'create trigger audit_changes after insert or update or delete on public.%I
         for each row execute function app.write_audit_log()', t);
  end loop;
end
$do$;

-- The standing sweep: nothing SECURITY DEFINER is left reachable by
-- anon, and the two internal posting functions stay off the API.
do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
       and p.proname not in ('create_gl_entry_internal', 'run_daily_jobs',
                             'write_audit_log', 'next_document_number_internal')
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;
