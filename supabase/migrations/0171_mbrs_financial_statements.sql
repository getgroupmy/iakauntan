-- Audited financial statements, and the data MBRS wants.
--
-- ## What this is, and what it is not
--
-- MBRS is SSM's XBRL platform. A preparer keys or imports the figures
-- into **mTool** — an Excel application SSM distributes — which generates
-- the XBRL instance, and uploads that through **mPortal**. There is no
-- public API for third-party lodgement, so nothing here submits to SSM.
-- What this module does is produce the dataset that goes *into* mTool,
-- and record the reference that comes back out of mPortal.
--
-- Saying so plainly matters: a module that implied it had filed a
-- company's accounts when it had not would be worse than no module.
--
-- ## The numbers already exist
--
-- `report_balance_sheet`, `report_profit_loss`, `report_changes_in_equity`
-- and `report_cash_flow` have been here since `0014`. This adds the four
-- things between a trial balance and a lodgeable set of accounts:
--
--   1. a **mapping** from this company's chart of accounts to taxonomy
--      elements — which mostly writes itself, see below;
--   2. the **audit metadata** MBRS asks for that no ledger holds: the
--      auditor, the opinion, the report date, going concern;
--   3. a **frozen snapshot**, because a lodged statement must not change
--      when somebody posts a back-dated journal in March;
--   4. the **statutory clock** — s.258 and s.259 — and the audit
--      exemption test under Practice Directive 3/2018.
--
-- ## The mapping mostly writes itself
--
-- `accounts.account_subtype` already says what every account is:
-- `accounts_receivable`, `inventory`, `finance_cost`, `payroll_expense`.
-- That is very nearly the taxonomy already, so `app.fs_default_element`
-- maps every subtype to an element and `fs_account_map` holds only the
-- deviations. A company with a standard chart maps nothing by hand.
--
-- ## The element codes are a working set
--
-- **`mbrs_elements` is a table, not a hardcoded list, and that is
-- deliberate.** The MBRS taxonomy is versioned and changes between
-- releases; a set of codes baked into a migration would be wrong the
-- first time SSM published a new one, and correcting it would need a
-- deployment. The codes seeded below are the standard MPERS and MFRS
-- statement lines under their conventional names. **They must be
-- reconciled against the mTool taxonomy in use before the first live
-- lodgement**, and `taxonomy_version` is there to record which one.

create type app.fs_framework as enum ('mpers', 'mfrs');

-- `unaudited` is not the same as `audit_exempt`. A company that
-- qualifies for exemption under PD 3/2018 and claims it files unaudited
-- accounts lawfully; a company that simply has not been audited yet does
-- not. MBRS asks which, so the column has to be able to say.
create type app.fs_audit_status as enum ('audited', 'audit_exempt', 'unaudited');

create type app.fs_opinion as enum
  ('unmodified', 'qualified', 'adverse', 'disclaimer');

create type app.fs_filing_status as enum ('draft', 'frozen', 'lodged');

create type app.fs_statement as enum
  ('sofp',      -- Statement of Financial Position
   'soploci',   -- Statement of Profit or Loss and Other Comprehensive Income
   'socie',     -- Statement of Changes in Equity
   'socf',      -- Statement of Cash Flows
   'disclosure');

-- ---------------------------------------------------------------------
-- The taxonomy
--
-- Global, like `ref_currencies` — every tenant reports against the same
-- taxonomy, and a per-tenant copy would let two companies disagree about
-- what SSM asked for.
-- ---------------------------------------------------------------------
create table public.mbrs_elements (
  code        text primary key,
  statement   app.fs_statement not null,

  -- Grouping within the statement, for presentation order in the export.
  section     text,
  label       text not null,

  -- Null means the element exists under both frameworks, which is true
  -- of almost every line on the face of the statements. The differences
  -- are in the notes.
  framework   app.fs_framework,

  sort_order  integer not null default 0,
  is_active   boolean not null default true,

  -- Which taxonomy release these codes came from. The seed below says
  -- `working-set`, which is not a taxonomy version and is meant to look
  -- wrong until somebody reconciles it.
  taxonomy_version text not null default 'working-set',
  created_at  timestamptz not null default now()
);

-- Readable by anybody signed in; writable only by platform staff, who
-- are the ones who would be loading a new taxonomy release.
alter table public.mbrs_elements enable row level security;
create policy mbrs_elements_select on public.mbrs_elements
  for select to authenticated using (true);
create policy mbrs_elements_write on public.mbrs_elements
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());
grant select, insert, update, delete on public.mbrs_elements to authenticated;

insert into public.mbrs_elements (code, statement, section, label, sort_order)
values
  -- Statement of Financial Position
  ('PropertyPlantAndEquipment', 'sofp', 'non_current_assets',
   'Property, plant and equipment', 100),
  ('InvestmentProperties', 'sofp', 'non_current_assets',
   'Investment properties', 110),
  ('IntangibleAssets', 'sofp', 'non_current_assets', 'Intangible assets', 120),
  ('OtherNonCurrentAssets', 'sofp', 'non_current_assets',
   'Other non-current assets', 190),
  ('Inventories', 'sofp', 'current_assets', 'Inventories', 200),
  ('TradeAndOtherReceivables', 'sofp', 'current_assets',
   'Trade and other receivables', 210),
  ('OtherCurrentAssets', 'sofp', 'current_assets',
   'Other current assets', 220),
  ('CashAndCashEquivalents', 'sofp', 'current_assets',
   'Cash and cash equivalents', 290),
  ('TradeAndOtherPayables', 'sofp', 'current_liabilities',
   'Trade and other payables', 300),
  ('CurrentTaxLiabilities', 'sofp', 'current_liabilities',
   'Current tax liabilities', 310),
  ('OtherCurrentLiabilities', 'sofp', 'current_liabilities',
   'Other current liabilities', 390),
  ('LoansAndBorrowings', 'sofp', 'non_current_liabilities',
   'Loans and borrowings', 400),
  ('OtherNonCurrentLiabilities', 'sofp', 'non_current_liabilities',
   'Other non-current liabilities', 490),
  ('ShareCapital', 'sofp', 'equity', 'Share capital', 500),
  ('Reserves', 'sofp', 'equity', 'Reserves', 510),
  ('RetainedEarnings', 'sofp', 'equity',
   'Retained earnings / (accumulated losses)', 590),

  -- Statement of Profit or Loss and Other Comprehensive Income
  ('Revenue', 'soploci', 'trading', 'Revenue', 600),
  ('CostOfSales', 'soploci', 'trading', 'Cost of sales', 610),
  ('OtherIncome', 'soploci', 'other', 'Other income', 620),
  ('AdministrativeExpenses', 'soploci', 'expenses',
   'Administrative expenses', 700),
  ('StaffCosts', 'soploci', 'expenses', 'Staff costs', 710),
  ('DepreciationAndAmortisation', 'soploci', 'expenses',
   'Depreciation and amortisation', 720),
  ('OtherOperatingExpenses', 'soploci', 'expenses',
   'Other operating expenses', 790),
  ('FinanceCosts', 'soploci', 'finance', 'Finance costs', 800),
  ('TaxExpense', 'soploci', 'tax', 'Tax expense', 900)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- One filing per financial year
-- ---------------------------------------------------------------------
create table public.fs_filings (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,

  -- Optional. A company keeping its own books here has no corp-sec
  -- entity row, and should still be able to prepare its accounts.
  corp_entity_id uuid references public.corp_entities(id) on delete set null,

  fy_start    date not null,
  fy_end      date not null,
  framework   app.fs_framework not null default 'mpers',

  audit_status app.fs_audit_status not null default 'audited',
  auditor_name text,
  auditor_firm_no text,
  auditor_signatory text,
  audit_report_date date,
  opinion     app.fs_opinion,

  -- Asked separately from the opinion because an emphasis of matter on
  -- going concern sits *with* an unmodified opinion, and MBRS asks for
  -- it as its own fact.
  going_concern_emphasis boolean not null default false,

  -- Headcount at the year end, for the PD 3/2018 threshold test. Not
  -- derived: the `employees` table only exists for tenants on the HR
  -- module, and a number this one is guessed at is a number somebody
  -- signs a declaration over.
  employee_count integer check (employee_count is null or employee_count >= 0),

  directors_approval_date date,
  circulated_on date,
  lodged_on   date,

  -- What mPortal gave back. The only evidence in here that a lodgement
  -- actually happened.
  mbrs_reference text,

  status      app.fs_filing_status not null default 'draft',
  frozen_at   timestamptz,
  frozen_by   uuid references auth.users(id),
  notes       text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) default auth.uid(),
  updated_at  timestamptz not null default now(),

  constraint fs_filings_period check (fy_end > fy_start),
  -- A financial year is filed once. A second row for the same year end
  -- is somebody preparing the same accounts twice, and the two would
  -- disagree.
  unique (org_id, fy_end)
);

create index fs_filings_org_idx on public.fs_filings (org_id, fy_end desc);

alter table public.fs_filings
  add constraint fs_filings_org_id_id_key unique (org_id, id);

-- ---------------------------------------------------------------------
-- The deviations from the default mapping
--
-- Only the exceptions live here. `app.fs_default_element` covers every
-- subtype, so an empty table means "the standard chart, mapped the
-- standard way" rather than "nothing is mapped".
-- ---------------------------------------------------------------------
create table public.fs_account_map (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  element_code text not null references public.mbrs_elements(code),
  created_at  timestamptz not null default now(),
  unique (org_id, account_id),
  -- The account has to belong to the company doing the mapping. The
  -- composite key makes that declarative rather than remembered.
  constraint fs_account_map_account_same_org
    foreign key (org_id, account_id)
    references public.accounts (org_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- The frozen figures
--
-- The reason this table exists rather than the export reading the
-- ledger live: a set of accounts lodged with SSM in April must still
-- show the same numbers in November, and the ledger will not, because
-- somebody will have posted a correction into the closed year. What was
-- filed is a fact about the past and stops being a query.
-- ---------------------------------------------------------------------
create table public.fs_figures (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  filing_id   uuid not null references public.fs_filings(id) on delete cascade,
  element_code text not null references public.mbrs_elements(code),
  current_amount numeric(18, 2) not null default 0,
  prior_amount numeric(18, 2) not null default 0,
  unique (filing_id, element_code),
  constraint fs_figures_filing_same_org
    foreign key (org_id, filing_id)
    references public.fs_filings (org_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- The narrative MBRS asks for and no ledger holds
-- ---------------------------------------------------------------------
create table public.fs_disclosures (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  filing_id   uuid not null references public.fs_filings(id) on delete cascade,
  code        text not null,
  value_text  text,
  unique (filing_id, code),
  constraint fs_disclosures_filing_same_org
    foreign key (org_id, filing_id)
    references public.fs_filings (org_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Frozen means frozen
--
-- A trigger rather than a policy, because the rule is about the row's
-- own state rather than about who is asking. `fs_freeze` and `fs_lodge`
-- are SECURITY DEFINER and would sail past a policy; they cannot sail
-- past this, so they set `app.fs_writing` for the one statement that is
-- allowed to write.
-- ---------------------------------------------------------------------
create or replace function app.fs_refuse_when_frozen()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_status app.fs_filing_status;
  v_filing uuid;
begin
  -- `coalesce(new, old)` is not addressable in plpgsql — a record
  -- expression has no field access — so the branch is written out.
  if tg_op = 'DELETE' then v_filing := old.filing_id;
                      else v_filing := new.filing_id; end if;

  if coalesce(current_setting('app.fs_writing', true), '') <> 'on' then
    select status into v_status from public.fs_filings where id = v_filing;
    if v_status in ('frozen', 'lodged') then
      raise exception
        'These accounts are %. Unfreeze them first — and if they have been '
        'lodged, they cannot be changed at all.', v_status
        using errcode = '42501';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; else return new; end if;
end $$;

create trigger fs_figures_frozen
  before insert or update or delete on public.fs_figures
  for each row execute function app.fs_refuse_when_frozen();
create trigger fs_disclosures_frozen
  before insert or update or delete on public.fs_disclosures
  for each row execute function app.fs_refuse_when_frozen();

-- The filing row itself. Lodged accounts are evidence: the reference and
-- the date may still be corrected, and nothing else may.
create or replace function app.fs_refuse_lodged_edit()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if coalesce(current_setting('app.fs_writing', true), '') = 'on' then
    new.updated_at := now();
    return new;
  end if;
  if old.status = 'lodged' then
    -- The reference and the lodgement date may still be corrected — a
    -- typo in what mPortal returned is a typo, not a restatement.
    -- Everything the accounts actually *say* is closed.
    if (new.fy_start, new.fy_end, new.framework, new.audit_status,
        new.opinion, new.audit_report_date, new.auditor_name)
       is distinct from
       (old.fy_start, old.fy_end, old.framework, old.audit_status,
        old.opinion, old.audit_report_date, old.auditor_name) then
      raise exception
        'These accounts have been lodged with SSM. Correcting them means '
        'lodging a fresh set, not editing this one.' using errcode = '42501';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger fs_filings_lodged
  before update on public.fs_filings
  for each row execute function app.fs_refuse_lodged_edit();

-- ---------------------------------------------------------------------
-- Row level security
--
-- Reads stay open to any member on the permissive policy: a filed set of
-- accounts is evidence for a year already closed, and switching the
-- add-on off must not hide a company's own history. Writes need the
-- entitlement.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'fs_filings', 'fs_account_map', 'fs_figures', 'fs_disclosures'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_org_member(org_id))', t || '_select', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (app.can_write(org_id) and app.has_module(org_id, ''mbrs''))',
      t || '_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (app.can_write(org_id) and app.has_module(org_id, ''mbrs''))
         with check (app.can_write(org_id) and app.has_module(org_id, ''mbrs''))',
      t || '_update', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (app.can_admin(org_id) and app.has_module(org_id, ''mbrs''))',
      t || '_delete', t);

    -- The access-type layer from 0127. Draft accounts are a sensitive
    -- thing to leave on every member's screen.
    execute format(
      'create policy module_gate_select on public.%I
         as restrictive for select to authenticated
         using (app.can_read_module(org_id, ''mbrs''))', t);
    execute format(
      'create policy module_gate_insert on public.%I
         as restrictive for insert to authenticated
         with check (app.can_write_module(org_id, ''mbrs''))', t);
    execute format(
      'create policy module_gate_update on public.%I
         as restrictive for update to authenticated
         using (app.can_write_module(org_id, ''mbrs''))
         with check (app.can_write_module(org_id, ''mbrs''))', t);
    execute format(
      'create policy module_gate_delete on public.%I
         as restrictive for delete to authenticated
         using (app.can_write_module(org_id, ''mbrs''))', t);

    execute format(
      'grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The module
--
-- **Deliberately not granted to every existing tenant**, unlike `0168`
-- and `0170`. Those two gated capabilities companies were already using,
-- so taking them away would have been a removal dressed as a migration.
-- Nothing here existed before this migration, so there is nothing anyone
-- can lose by having to ask for it.
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('mbrs', 'Financial Statements & MBRS',
   'Audited financial statements mapped to the MBRS taxonomy, with the '
   'section 258 and 259 lodgement clock, the Practice Directive 3/2018 '
   'audit exemption test, frozen figures and an export for mTool',
   false, 79, 17)
on conflict (code) do nothing;
