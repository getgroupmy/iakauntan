-- =====================================================================
-- iAkauntan :: branches
--
-- A company that trades from more than one place has had one address,
-- one set of documents and no way to say which shop a sale happened in.
-- This adds a branch: a place the company trades from, under the same
-- registration and the same ledger.
--
-- ---------------------------------------------------------------------
-- A branch is not a company
--
-- Where two shops share an SSM number they are one company with two
-- branches, and everything here applies: one ledger, one set of books,
-- a branch recorded against each document so the takings can be told
-- apart. Where they have different registrations they are different
-- companies, and a branch cannot represent that — 0132 links those into
-- a group instead. The distinction is not a modelling preference; it is
-- what SSM and LHDN think, and the books have to agree with them.
--
-- Some branches do carry their own numbers without being separate
-- companies — a branch registered for SST in its own right, or with its
-- own business registration under the same parent. Those columns are
-- here so such a branch can put the right number on its own invoices,
-- and they are null for the ordinary branch that uses the company's.
--
-- ---------------------------------------------------------------------
-- Inert until used
--
-- `branch_id` is nullable everywhere. Every document that exists today
-- has no branch, every company has no branches, and nothing reads the
-- column unless something is filled in. A company that never opens a
-- second shop never sees any of this.
-- =====================================================================

create table public.branches (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  code          text not null,
  name          text not null,

  -- Null unless this branch is registered in its own right. The
  -- company's own numbers are the default and stay in `organizations`.
  registration_no      text,
  tin                  text,
  sst_registration_no  text,

  address_line1 text,
  address_line2 text,
  address_line3 text,
  postcode      text,
  city          text,
  state_code    text,
  country_code  char(3) not null default 'MYS',
  phone         text,
  email         text,

  is_default    boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (org_id, code)
);

create index branches_org_idx on public.branches (org_id) where is_active;

-- Where the work happened. Nullable on purpose: see the header.
alter table public.sales_documents
  add column branch_id uuid references public.branches(id);
alter table public.purchase_documents
  add column branch_id uuid references public.branches(id);
alter table public.expenses
  add column branch_id uuid references public.branches(id);
alter table public.warehouses
  add column branch_id uuid references public.branches(id);
alter table public.employees
  add column branch_id uuid references public.branches(id);

create index sales_documents_branch_idx
  on public.sales_documents (org_id, branch_id) where branch_id is not null;
create index purchase_documents_branch_idx
  on public.purchase_documents (org_id, branch_id) where branch_id is not null;
create index expenses_branch_idx
  on public.expenses (org_id, branch_id) where branch_id is not null;

-- ---------------------------------------------------------------------
-- Who may see and change them
-- ---------------------------------------------------------------------
alter table public.branches enable row level security;

create policy branches_select on public.branches
  for select to authenticated using (app.is_org_member(org_id));

create policy branches_write on public.branches
  for all to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));

grant select, insert, update, delete on public.branches to authenticated;

-- A branch belongs to the company whose branch it is. Without this a
-- document in one company could name another company's branch, which
-- would be invisible on screen and wrong in every report.
create or replace function app.branch_belongs_to_org()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if new.branch_id is not null
     and not exists (select 1 from public.branches b
                      where b.id = new.branch_id and b.org_id = new.org_id) then
    raise exception 'That branch belongs to another company'
      using errcode = '23514';
  end if;
  return new;
end; $$;

revoke all on function app.branch_belongs_to_org()
  from public, anon, authenticated;

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'sales_documents', 'purchase_documents', 'expenses',
    'warehouses', 'employees'
  ]
  loop
    execute format(
      'drop trigger if exists branch_belongs_to_org on public.%I', v_table);
    execute format(
      'create trigger branch_belongs_to_org
         before insert or update of branch_id, org_id on public.%I
         for each row execute function app.branch_belongs_to_org()',
      v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- A module, so it can be sold and so an access type can gate it
-- ---------------------------------------------------------------------
insert into public.platform_modules (code, name, description, is_core,
                                     monthly_price)
values ('branches', 'Branches',
        'Trade from more than one place under one registration', false, 0)
on conflict (code) do nothing;
