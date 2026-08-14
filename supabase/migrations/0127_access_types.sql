-- =====================================================================
-- iAkauntan :: access types a company defines for itself
--
-- Membership has been one of ten fixed roles since 0001 — owner, admin,
-- accountant, hr_manager, accounts_clerk, auditor, sales, purchaser,
-- viewer, employee — and every company gets the same ten whether they
-- fit or not. A firm with a clerk who may see purchases but not payroll,
-- or a partner who may read everything and change nothing, has had
-- nowhere to say so.
--
-- This adds a second, per-company dimension: an *access type*, which is
-- a named set of modules and, for each, whether the holder may read it
-- or write it.
--
-- ---------------------------------------------------------------------
-- It layers on top of the roles rather than replacing them
--
-- The two answer different questions and both still have to be yes. The
-- role says what *kind* of thing somebody may do — post to the ledger,
-- run payroll, administer the company. The access type says which
-- *modules* they may reach at all, and whether they may change anything
-- there. An access type cannot grant what the role does not already
-- allow; it can only take away.
--
-- Replacing the roles would have meant rewriting the `can_*` functions
-- that every policy on 155 tables calls, in one migration, with no way
-- to test the half that does not break loudly. Layering is enforceable
-- today and leaves that door open.
--
-- ---------------------------------------------------------------------
-- Nothing changes for anybody until a company says so
--
-- A member with no access type gets `write` on every module, which is
-- exactly what they have now. Owners and administrators always get
-- `write`, whatever is assigned — an access type that could lock the
-- owner out of their own company would be a support call, not a
-- feature. So on every existing organization this migration is inert
-- until somebody creates an access type and assigns it.
--
-- ---------------------------------------------------------------------
-- Enforced by restrictive policies, not by rewriting 155 of them
--
-- A RESTRICTIVE policy is ANDed with whatever permissive policies a
-- table already has, so module access can be added as a second gate
-- without touching the first. The existing policy still decides whether
-- this row is yours; the new one decides whether you may be in this
-- module at all. Written per command, because a single `for all`
-- restrictive policy would hold reading to the standard for writing.
-- =====================================================================

create type app.module_access as enum ('none', 'read', 'write');

create table public.access_types (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  name        text not null,
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, name)
);

create index access_types_org_idx on public.access_types (org_id);

-- One row per module the access type says anything about. A module with
-- no row is `none`: an access type grants what it lists and nothing
-- else, so forgetting to add a module denies it rather than opening it.
create table public.access_type_modules (
  access_type_id uuid not null references public.access_types(id)
                   on delete cascade,
  module_code    text not null,
  access         app.module_access not null default 'none',
  primary key (access_type_id, module_code)
);

-- Optional, and null for everybody until a company decides otherwise.
alter table public.org_members
  add column access_type_id uuid references public.access_types(id)
    on delete set null;

-- ---------------------------------------------------------------------
-- What somebody may do in a module
-- ---------------------------------------------------------------------
create or replace function app.module_access(p_org_id uuid, p_module text)
returns app.module_access
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_type uuid;
  v_access app.module_access;
begin
  if p_org_id is null or auth.uid() is null then
    return 'none';
  end if;

  -- Not a member of this company at all. The permissive policies say
  -- this too; saying it here keeps the function honest on its own.
  if not app.is_org_member(p_org_id) then
    return 'none';
  end if;

  -- The people who hand out access types cannot be shut out by one.
  if app.can_admin(p_org_id) then
    return 'write';
  end if;

  select m.access_type_id into v_type
    from public.org_members m
   where m.org_id = p_org_id and m.user_id = auth.uid();

  -- No access type assigned is how every member stands today, and it
  -- has to keep meaning "as before" or this migration would quietly
  -- take the whole product away from every existing company.
  if v_type is null then
    return 'write';
  end if;

  select t.access into v_access
    from public.access_type_modules t
   where t.access_type_id = v_type and t.module_code = p_module;

  return coalesce(v_access, 'none');
end; $$;

create or replace function app.can_read_module(p_org_id uuid, p_module text)
returns boolean
language sql stable
set search_path = public, app, pg_temp as $$
  select app.module_access(p_org_id, p_module) in ('read', 'write');
$$;

create or replace function app.can_write_module(p_org_id uuid, p_module text)
returns boolean
language sql stable
set search_path = public, app, pg_temp as $$
  select app.module_access(p_org_id, p_module) = 'write';
$$;

revoke all on function app.module_access(uuid, text) from public, anon;
grant execute on function app.module_access(uuid, text) to authenticated;
revoke all on function app.can_read_module(uuid, text) from public, anon;
grant execute on function app.can_read_module(uuid, text) to authenticated;
revoke all on function app.can_write_module(uuid, text) from public, anon;
grant execute on function app.can_write_module(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Who may see and change the access types themselves
-- ---------------------------------------------------------------------
alter table public.access_types enable row level security;
alter table public.access_type_modules enable row level security;

-- Everybody in the company can read them, because the screens that
-- explain why a module is missing have to be able to name the reason.
create policy access_types_select on public.access_types
  for select to authenticated using (app.is_org_member(org_id));

create policy access_types_write on public.access_types
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

create policy access_type_modules_select on public.access_type_modules
  for select to authenticated
  using (exists (select 1 from public.access_types t
                  where t.id = access_type_id
                    and app.is_org_member(t.org_id)));

create policy access_type_modules_write on public.access_type_modules
  for all to authenticated
  using (exists (select 1 from public.access_types t
                  where t.id = access_type_id and app.can_admin(t.org_id)))
  with check (exists (select 1 from public.access_types t
                       where t.id = access_type_id
                         and app.can_admin(t.org_id)));

grant select, insert, update, delete on public.access_types to authenticated;
grant select, insert, update, delete on public.access_type_modules
  to authenticated;

-- ---------------------------------------------------------------------
-- The gate itself
--
-- Tables that plainly belong to one module. Deliberately not `accounts`
-- or `gl_entries`: the chart of accounts is reference data every module
-- reads, and the ledger is already behind `can_read_ledger`. Gating
-- shared reference data on a module would lock somebody out of the
-- screen they do have access to, which is the failure mode worth
-- avoiding in a first cut.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('sales_documents',        'sales'),
      ('sales_document_lines',   'sales'),
      ('receipts',               'sales'),
      ('purchase_documents',     'purchases'),
      ('purchase_document_lines','purchases'),
      ('purchase_payments',      'purchases'),
      ('expenses',               'purchases'),
      ('items',                  'inventory'),
      ('item_prices',            'inventory'),
      ('stock_movements',        'inventory'),
      ('warehouses',             'inventory'),
      ('contacts',               'contacts'),
      ('leads',                  'crm'),
      ('employees',              'hr'),
      ('expense_claims',         'hr'),
      ('leave_requests',         'hr'),
      ('payslips',               'payroll'),
      ('payroll_runs',           'payroll'),
      ('corp_entities',          'secretarial'),
      ('matters',                'legal')
    ) as t(table_name, module_code)
  loop
    execute format(
      'drop policy if exists module_gate_select on public.%I', r.table_name);
    execute format(
      'create policy module_gate_select on public.%I
         as restrictive for select to authenticated
         using (app.can_read_module(org_id, %L))',
      r.table_name, r.module_code);

    execute format(
      'drop policy if exists module_gate_insert on public.%I', r.table_name);
    execute format(
      'create policy module_gate_insert on public.%I
         as restrictive for insert to authenticated
         with check (app.can_write_module(org_id, %L))',
      r.table_name, r.module_code);

    execute format(
      'drop policy if exists module_gate_update on public.%I', r.table_name);
    execute format(
      'create policy module_gate_update on public.%I
         as restrictive for update to authenticated
         using (app.can_write_module(org_id, %L))
         with check (app.can_write_module(org_id, %L))',
      r.table_name, r.module_code, r.module_code);

    execute format(
      'drop policy if exists module_gate_delete on public.%I', r.table_name);
    execute format(
      'create policy module_gate_delete on public.%I
         as restrictive for delete to authenticated
         using (app.can_write_module(org_id, %L))',
      r.table_name, r.module_code);
  end loop;
end $$;
