-- Property management, in two modules.
--
-- A building either has strata titles or it does not, and almost nothing
-- about managing it is the same across that line:
--
--   * A **strata** scheme is governed by the Strata Management Act 2013.
--     There is a Joint Management Body or a management corporation, the
--     parcels carry allocated share units, and the Charges must be
--     levied in proportion to those share units — not per square foot,
--     not equally. A sinking fund contribution of at least ten per cent
--     of the Charges rides on top (s.25(3) for a JMB, s.51(2) for an
--     MC). Arrears attract a late payment charge which the Third
--     Schedule of the Strata Management (Maintenance and Management)
--     Regulations 2015 caps at ten per cent per annum, on a daily basis.
--
--   * A **non-strata** property — a shoplot, a landed house, a whole
--     commercial building — has none of that. It has a tenancy, a rent,
--     a deposit and an end date, and the money is rent rather than a
--     statutory contribution.
--
-- So they are sold and gated separately: `property_strata` and
-- `property_nonstrata`. What they share is the physical thing — a site
-- and the units in it — and that spine is available to a company holding
-- either one.
--
-- Both bill through `sales_documents`. A charge run raises ordinary
-- invoices, which means aged receivables, statements, receipts, credit
-- control, reminder emails and e-Invoice all work on the day this ships
-- rather than needing a parallel set of each. A management corporation's
-- Charges are receivable in exactly the sense the rest of this system
-- already understands.

-- ---------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('property_strata', 'Property — Strata',
   'Strata schemes under the SMA 2013: parcels and share units, Charges '
   'apportioned by share unit, sinking fund and arrears interest',
   false, 89, 12),
  ('property_nonstrata', 'Property — Non-Strata',
   'Landed, shop and commercial property: tenancies, rent invoicing, '
   'deposits, quit rent and assessment',
   false, 69, 13)
on conflict (code) do nothing;

-- Neither is switched on by `app.seed_org_modules`, which only enables
-- the four add-ons every tenant gets. A property company asks for these.

-- ---------------------------------------------------------------------
-- The spine
-- ---------------------------------------------------------------------

-- True when the company holds either property module. The shared tables
-- gate on this rather than on one of them, because a site and its units
-- are the same rows whichever module manages them, and a managing agent
-- with a mixed portfolio holds both.
create or replace function app.has_property_module(p_org_id uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select app.has_module(p_org_id, 'property_strata')
      or app.has_module(p_org_id, 'property_nonstrata');
$$;

create type app.property_tenure as enum ('strata', 'non_strata');

create table public.property_sites (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references public.organizations(id)
                          on delete cascade,
  code                  text not null,
  name                  text not null,
  -- The line the whole module is split on, and it cannot be changed once
  -- there are units under it: a scheme does not stop being strata.
  tenure                app.property_tenure not null,
  address_line1         text,
  address_line2         text,
  postcode              text,
  city                  text,
  state_code            text,
  -- Cukai tanah and cukai pintu are billed by different authorities
  -- against different account numbers, and both arrive as paper.
  local_authority       text,
  land_title_no         text,
  lot_no                text,
  quit_rent_account_no  text,
  assessment_account_no text,
  is_active             boolean not null default true,
  notes                 text,
  created_by            uuid references auth.users(id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (org_id, code)
);
create index property_sites_org_idx
  on public.property_sites (org_id) where is_active;

create type app.property_unit_type as enum (
  'parcel',           -- a strata parcel: an apartment, an office suite
  'accessory',        -- a car park or store attached to a principal parcel
  'landed',           -- a house or a lot on its own title
  'shop', 'office', 'industrial',
  'common');          -- common property, never billed

create table public.property_units (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  site_id       uuid not null references public.property_sites(id)
                  on delete cascade,
  unit_no       text not null,
  unit_type     app.property_unit_type not null default 'parcel',
  floor         text,
  built_up_sqft numeric(18, 2),

  -- Allocated share units, from the Schedule of Parcels. Null on a
  -- non-strata unit and on common property; required, and positive, on
  -- anything a strata scheme intends to charge — see the trigger below.
  -- This is the number the SMA 2013 makes the Charges proportional to,
  -- so it is `numeric` rather than `integer`: some schedules allocate
  -- fractions and rounding them would move money between neighbours.
  share_units   numeric(18, 4) check (share_units is null or share_units >= 0),

  -- An accessory parcel is charged through its principal parcel, not
  -- separately, so it points at the one it belongs to.
  principal_unit_id uuid references public.property_units(id)
                      on delete set null,

  -- Who is billed. A contact rather than a table of its own: an owner
  -- receives invoices, pays them, appears in aged receivables and may
  -- need an e-Invoice, and `contacts` is what all of that speaks.
  owner_contact_id uuid references public.contacts(id) on delete set null,

  is_chargeable boolean not null default true,
  is_active     boolean not null default true,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (site_id, unit_no)
);
create index property_units_site_idx on public.property_units (site_id);
create index property_units_owner_idx
  on public.property_units (owner_contact_id)
  where owner_contact_id is not null;

-- The cross-tenant rule 0160 made declarative, applied to the new
-- columns. A unit must sit in a site of its own company, and be owned by
-- a contact of its own company.
alter table public.property_sites add constraint property_sites_org_id_id_key
  unique (org_id, id);
alter table public.contacts add constraint contacts_org_id_id_key
  unique (org_id, id);
alter table public.property_units
  add constraint property_units_site_same_org
  foreign key (org_id, site_id)
  references public.property_sites (org_id, id) on delete cascade;
alter table public.property_units
  add constraint property_units_owner_same_org
  foreign key (org_id, owner_contact_id)
  references public.contacts (org_id, id);
alter table public.property_units add constraint property_units_org_id_id_key
  unique (org_id, id);

-- A unit belongs to the tenure of its site, and a strata scheme cannot
-- charge a parcel it has not allocated share units to.
create or replace function app.property_unit_matches_site()
returns trigger language plpgsql
set search_path = pg_catalog, public, pg_temp as $$
declare v_tenure app.property_tenure;
begin
  select tenure into v_tenure from public.property_sites where id = new.site_id;

  if v_tenure = 'strata' then
    if new.unit_type in ('landed', 'shop', 'office', 'industrial') then
      raise exception
        'A strata scheme holds parcels and accessory parcels, not a %',
        new.unit_type using errcode = '23514';
    end if;
    -- The one that would otherwise be found at the AGM. A parcel with no
    -- share units cannot be charged in proportion to its share units,
    -- and billing it anyway means somebody else is paying for it.
    if new.is_chargeable and new.unit_type = 'parcel'
       and coalesce(new.share_units, 0) <= 0 then
      raise exception
        'Parcel % has no allocated share units. The Charges are levied in '
        'proportion to share units, so it cannot be billed until the '
        'Schedule of Parcels says what its share is.', new.unit_no
        using errcode = '23514';
    end if;
  else
    if new.unit_type in ('parcel', 'accessory') then
      raise exception
        'A non-strata property has no parcels; % is not a unit type it can '
        'hold', new.unit_type using errcode = '23514';
    end if;
    if new.share_units is not null then
      raise exception 'Share units belong to a strata scheme'
        using errcode = '23514';
    end if;
  end if;

  return new;
end $$;

create trigger unit_matches_site
  before insert or update on public.property_units
  for each row execute function app.property_unit_matches_site();

-- ---------------------------------------------------------------------
-- Quit rent and assessment
--
-- Cukai tanah is charged by the state and cukai pintu by the local
-- authority; the rates are set state by state and change without
-- notice, so nothing here computes them. What this does is hold the
-- bill, its period and the date it falls due, so that a portfolio of
-- forty sites does not lose one. Common to both modules — a strata
-- scheme pays quit rent on the master title, a landed owner on their
-- own.
-- ---------------------------------------------------------------------
create type app.statutory_property_charge as enum ('quit_rent', 'assessment');

create table public.property_statutory_charges (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,
  site_id      uuid not null references public.property_sites(id)
                 on delete cascade,
  kind         app.statutory_property_charge not null,
  authority    text,
  account_no   text,
  period_year  integer not null,
  -- 1 or 2 for a half-yearly assessment; null for an annual quit rent.
  period_half  integer check (period_half in (1, 2)),
  amount       numeric(18, 2) not null check (amount >= 0),
  due_date     date not null,
  paid_on      date,
  -- The supplier bill it was paid through, if it went through the books.
  bill_document_id uuid references public.purchase_documents(id)
                     on delete set null,
  reference    text,
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (site_id, kind, period_year, period_half)
);
create index property_statutory_due_idx
  on public.property_statutory_charges (org_id, due_date)
  where paid_on is null;

alter table public.property_statutory_charges
  add constraint property_statutory_site_same_org
  foreign key (org_id, site_id)
  references public.property_sites (org_id, id) on delete cascade;

-- ---------------------------------------------------------------------
-- Strata
-- ---------------------------------------------------------------------
create type app.strata_stage as enum ('developer', 'jmb', 'mc');

create table public.strata_schemes (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations(id)
                        on delete cascade,
  site_id             uuid not null unique references public.property_sites(id)
                        on delete cascade,
  -- Who is running it today. It moves developer → JMB → MC as the
  -- development is handed over, and which one it is decides who signs.
  stage               app.strata_stage not null default 'jmb',
  cob_reference       text,
  mc_registration_no  text,
  established_on      date,
  first_agm_on        date,
  financial_year_end  date,
  -- The denominator. Held rather than summed so that a Schedule of
  -- Parcels which has not been fully entered is visibly incomplete
  -- instead of silently changing everyone's share of the Charges.
  total_share_units   numeric(18, 4) check (total_share_units is null
                                            or total_share_units > 0),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table public.strata_schemes
  add constraint strata_schemes_site_same_org
  foreign key (org_id, site_id)
  references public.property_sites (org_id, id) on delete cascade;
alter table public.strata_schemes add constraint strata_schemes_org_id_id_key
  unique (org_id, id);

-- What the AGM resolved. Rates change by resolution and the old ones
-- have to stay: a charge raised for January is raised at January's rate
-- however many times it is reprinted.
create table public.strata_charge_rates (
  id                    uuid primary key default gen_random_uuid(),
  org_id                uuid not null references public.organizations(id)
                          on delete cascade,
  scheme_id             uuid not null references public.strata_schemes(id)
                          on delete cascade,
  effective_from        date not null,

  -- Ringgit per share unit per month. This is the figure an AGM votes
  -- on, and multiplying it by a parcel's share units is what makes the
  -- Charges proportional to share units, which is the requirement.
  rate_per_share_unit   numeric(18, 6) not null
                          check (rate_per_share_unit >= 0),

  -- At least ten per cent of the Charges — SMA 2013 s.25(3) for a JMB,
  -- s.51(2) for a management corporation. The constraint is a floor and
  -- not an equality because a scheme may resolve to contribute more, and
  -- many do; it may not resolve to contribute less.
  sinking_fund_percent  numeric(6, 3) not null default 10
                          check (sinking_fund_percent >= 10
                                 and sinking_fund_percent <= 100),

  -- The late payment charge on arrears. Capped at ten per cent per
  -- annum by the Third Schedule of the Strata Management (Maintenance
  -- and Management) Regulations 2015, and computed daily.
  late_interest_percent numeric(6, 3) not null default 10
                          check (late_interest_percent >= 0
                                 and late_interest_percent <= 10),

  resolution_reference  text,
  notes                 text,
  created_at            timestamptz not null default now(),
  unique (scheme_id, effective_from)
);

alter table public.strata_charge_rates
  add constraint strata_charge_rates_scheme_same_org
  foreign key (org_id, scheme_id)
  references public.strata_schemes (org_id, id) on delete cascade;

create table public.strata_charge_runs (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  scheme_id      uuid not null references public.strata_schemes(id)
                   on delete cascade,
  run_no         text not null,
  period_from    date not null,
  period_to      date not null check (period_to >= period_from),
  rate_id        uuid not null references public.strata_charge_rates(id),
  months         numeric(9, 4) not null check (months > 0),
  parcels        integer not null default 0,
  total_maintenance numeric(18, 2) not null default 0,
  total_sinking     numeric(18, 2) not null default 0,
  raised_at      timestamptz not null default now(),
  raised_by      uuid references auth.users(id),
  unique (scheme_id, period_from, period_to)
);

alter table public.strata_charge_runs
  add constraint strata_charge_runs_scheme_same_org
  foreign key (org_id, scheme_id)
  references public.strata_schemes (org_id, id) on delete cascade;
alter table public.strata_charge_runs add constraint strata_charge_runs_org_id_id_key
  unique (org_id, id);

create table public.strata_charge_lines (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,
  run_id       uuid not null references public.strata_charge_runs(id)
                 on delete cascade,
  unit_id      uuid not null references public.property_units(id),
  -- Snapshotted, not read back through the unit. A Schedule of Parcels
  -- can be amended and an owner can sell; the charge that was raised was
  -- raised on the share units of the day, and an invoice that quietly
  -- restates itself is not evidence of anything.
  share_units  numeric(18, 4) not null check (share_units > 0),
  maintenance_amount numeric(18, 2) not null check (maintenance_amount >= 0),
  sinking_amount     numeric(18, 2) not null check (sinking_amount >= 0),
  invoice_id   uuid references public.sales_documents(id) on delete set null,
  unique (run_id, unit_id)
);

alter table public.strata_charge_lines
  add constraint strata_charge_lines_run_same_org
  foreign key (org_id, run_id)
  references public.strata_charge_runs (org_id, id) on delete cascade;
alter table public.strata_charge_lines
  add constraint strata_charge_lines_unit_same_org
  foreign key (org_id, unit_id)
  references public.property_units (org_id, id);

-- ---------------------------------------------------------------------
-- Non-strata: tenancies
-- ---------------------------------------------------------------------
create type app.tenancy_status as enum
  ('draft', 'active', 'expired', 'terminated');

create table public.tenancies (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id)
                      on delete cascade,
  unit_id           uuid not null references public.property_units(id)
                      on delete cascade,
  tenant_contact_id uuid not null references public.contacts(id),
  tenancy_no        text not null,
  start_date        date not null,
  end_date          date not null check (end_date >= start_date),
  monthly_rent      numeric(18, 2) not null check (monthly_rent >= 0),
  -- Which day of the month rent falls due. Kept as a number rather than
  -- assumed to be the first, because shop tenancies routinely fall due
  -- on the anniversary of the commencement date.
  rent_due_day      integer not null default 1
                      check (rent_due_day between 1 and 28),
  security_deposit  numeric(18, 2) not null default 0
                      check (security_deposit >= 0),
  utility_deposit   numeric(18, 2) not null default 0
                      check (utility_deposit >= 0),
  -- What is actually held today. Separate from the agreed figures above
  -- because a deposit can be partly forfeited, topped up, or refunded on
  -- exit, and the agreement does not change when it is.
  deposit_held      numeric(18, 2) not null default 0
                      check (deposit_held >= 0),
  status            app.tenancy_status not null default 'draft',
  terminated_on     date,
  notes             text,
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (org_id, tenancy_no)
);
create index tenancies_unit_idx on public.tenancies (unit_id);
create index tenancies_active_idx
  on public.tenancies (org_id, end_date) where status = 'active';

alter table public.tenancies
  add constraint tenancies_unit_same_org
  foreign key (org_id, unit_id)
  references public.property_units (org_id, id) on delete cascade;
alter table public.tenancies
  add constraint tenancies_tenant_same_org
  foreign key (org_id, tenant_contact_id)
  references public.contacts (org_id, id);
alter table public.tenancies add constraint tenancies_org_id_id_key
  unique (org_id, id);

-- One unit cannot be let to two tenants over the same days. Enforced by
-- the database rather than by the screen, because the double booking
-- that matters is the one made by two people at once.
create extension if not exists btree_gist;
alter table public.tenancies
  add constraint tenancies_no_overlap
  exclude using gist (
    unit_id with =,
    daterange(start_date, end_date, '[]') with &&
  ) where (status in ('active', 'draft'));

create table public.rent_runs (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  site_id     uuid not null references public.property_sites(id)
                on delete cascade,
  run_no      text not null,
  period_from date not null,
  period_to   date not null check (period_to >= period_from),
  tenancies   integer not null default 0,
  total_rent  numeric(18, 2) not null default 0,
  raised_at   timestamptz not null default now(),
  raised_by   uuid references auth.users(id),
  unique (site_id, period_from, period_to)
);

alter table public.rent_runs
  add constraint rent_runs_site_same_org
  foreign key (org_id, site_id)
  references public.property_sites (org_id, id) on delete cascade;
alter table public.rent_runs add constraint rent_runs_org_id_id_key
  unique (org_id, id);

create table public.rent_run_lines (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  run_id      uuid not null references public.rent_runs(id) on delete cascade,
  tenancy_id  uuid not null references public.tenancies(id),
  -- Whole months, or the fraction of one when a tenancy starts or ends
  -- mid-period. Held so a pro-rated first month can be read back rather
  -- than re-derived from dates that may since have been corrected.
  months      numeric(9, 4) not null check (months > 0),
  amount      numeric(18, 2) not null check (amount >= 0),
  invoice_id  uuid references public.sales_documents(id) on delete set null,
  unique (run_id, tenancy_id)
);

alter table public.rent_run_lines
  add constraint rent_run_lines_run_same_org
  foreign key (org_id, run_id)
  references public.rent_runs (org_id, id) on delete cascade;
alter table public.rent_run_lines
  add constraint rent_run_lines_tenancy_same_org
  foreign key (org_id, tenancy_id)
  references public.tenancies (org_id, id);
