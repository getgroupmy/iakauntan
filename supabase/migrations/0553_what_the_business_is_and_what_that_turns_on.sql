-- =====================================================================
-- iAkauntan :: 0553 what the business is, and what that turns on
--
-- Setup asks for a company name, an entity type and an MSIC code, and
-- then hands over a product with thirty modules in it and no opinion
-- about which of them a restaurant needs. Four are on by default for
-- everybody -- `seed_org_modules`: e-Invoice, purchases, inventory and
-- CRM -- and the rest are found by somebody going looking. A law firm
-- that never finds `legal` keeps client money in the office ledger,
-- which is the offence the Solicitors' Accounts Rules exist about.
--
-- So the setup asks what the business is, and the answer knows what it
-- needs.
--
-- ---------------------------------------------------------------------
-- A table rather than a list in Dart
--
-- The mapping is business configuration: which trades this product
-- claims to serve, and what it gives each of them. It changes when the
-- catalogue changes, and it has to be readable by the console -- both
-- of which are arguments for a row rather than a constant in a bundle
-- somebody has to rebuild and redeploy.
--
-- `module_codes` is a `text[]` rather than a join table, and that is a
-- deliberate loss of a foreign key. What replaces it is
-- `business_types.sql`, which asserts that every code names a module
-- that exists and is not core -- an assertion a join table would have
-- given for free, but only for the codes somebody remembered to insert
-- through it. The seed is written here, in one place, in a form
-- somebody reviewing this file can read as a list.
--
-- ---------------------------------------------------------------------
-- What "recommended" means, and what it does not
--
-- These modules are OFFERED, preselected, with their price beside
-- them. They are not switched on by this table's existence: nothing
-- reads `module_codes` except the setup screen and
-- `apply_business_type`, and both put the list in front of somebody
-- before anything is charged. A product that quietly enabled RM 300 a
-- month of modules because somebody said "restaurant" would be a
-- product that bills by inference.
--
-- The four `seed_org_modules` already switches on are deliberately NOT
-- repeated in these lists. They are on before this runs, for every
-- company, and naming them here would make a screen say "this business
-- type adds e-Invoice" about something nothing added.
--
-- ---------------------------------------------------------------------
-- Personal use, and the number that identifies a person
--
-- `app.entity_type` has carried `individual` since `0001` and nothing
-- ever set it. Somebody invoicing under their own name is a real user
-- of this product -- a freelancer, a landlord with two units, a tuition
-- teacher -- and for them LHDN's identification is not a business
-- registration number. It is the NRIC, or a passport number for a
-- person who has no NRIC, and it goes in the same UBL field with a
-- different `schemeID` (`_shared/ubl.ts` line 133).
--
-- `einvoice_id_type` already exists, the column DEFAULTS to `'BRN'`,
-- and `prepare_einvoice` coalesces to `'BRN'` again on top of that. A
-- person filed as BRN is rejected by MyInvois, so the answer has to be
-- right at the row rather than at the form: a trigger, which holds
-- whichever path created the company -- setup, an import, the console,
-- a seed.
--
-- Null or `BRN`, and nothing else. BRN on an individual is not a thing
-- anybody chose -- it is the column default, and a person cannot have
-- a business registration number -- so it is treated as unanswered.
-- `PASSPORT` and `ARMY` are answers, and a trigger that overrode them
-- would file the wrong number for somebody who had told it the right
-- one.
-- =====================================================================

create table if not exists public.business_types (
  code         text primary key,
  name         text not null,
  sector       text not null,
  module_codes text[] not null default '{}',
  sort_order   integer not null default 100,
  is_active    boolean not null default true
);

comment on table public.business_types is
  'What a company does, coarsely, and which modules that suggests. '
  'Offered at setup (0553); nothing here switches a module on by '
  'itself.';

comment on column public.business_types.module_codes is
  'Codes in platform_modules, none of them core and none of them one '
  'that seed_org_modules already switches on. Asserted in '
  'supabase/tests/business_types.sql.';

alter table public.business_types enable row level security;

drop policy if exists business_types_read on public.business_types;
create policy business_types_read on public.business_types
  for select to authenticated using (true);

revoke all on table public.business_types from public, anon;
grant select on table public.business_types to authenticated;

-- What the company said it was. Nullable: every company created before
-- this said nothing, and a person using this for themselves is not a
-- business type at all.
alter table public.organizations
  add column if not exists business_type text
    references public.business_types(code);

comment on column public.organizations.business_type is
  'What the company said it does at setup (0553). Null for a company '
  'set up before the question existed, and for personal use.';

-- ---------------------------------------------------------------------
-- The catalogue
--
-- Grouped by sector because the picker groups by sector, and ordered
-- within it by how likely somebody signing up here is to be that
-- thing. `other` is last and empty on purpose: it is the answer that
-- means "ask me instead", and the screen then shows the whole module
-- list with nothing preselected.
-- ---------------------------------------------------------------------
insert into public.business_types (code, name, sector, module_codes, sort_order)
values
  -- Food and drink
  ('restaurant', 'Restaurant or café', 'Food and drink',
   array['pos', 'loyalty'], 10),
  ('food_stall', 'Food stall, truck or kiosk', 'Food and drink',
   array['pos'], 11),
  ('bakery', 'Bakery or central kitchen', 'Food and drink',
   array['pos', 'manufacturing'], 12),
  ('catering', 'Catering', 'Food and drink',
   array['pos', 'approvals'], 13),

  -- Retail
  ('retail_shop', 'Retail shop', 'Retail',
   array['pos', 'loyalty'], 20),
  ('minimart', 'Minimart or grocery', 'Retail',
   array['pos', 'forecasting'], 21),
  ('online_store', 'Online store', 'Retail',
   array['forecasting'], 22),
  ('pharmacy', 'Pharmacy', 'Retail',
   array['pos', 'forecasting'], 23),
  ('automotive', 'Workshop or car dealer', 'Retail',
   array['pos', 'ticketing', 'fixed_assets'], 24),

  -- Services to people
  ('salon', 'Salon or barber', 'Personal services',
   array['pos', 'memberships', 'loyalty'], 30),
  ('spa', 'Spa or wellness', 'Personal services',
   array['pos', 'memberships', 'loyalty'], 31),
  ('gym', 'Gym or studio', 'Personal services',
   array['memberships', 'pos', 'loyalty'], 32),
  ('clinic', 'Clinic or dental practice', 'Personal services',
   array['pos', 'attachments', 'memberships'], 33),
  ('tuition', 'Tuition centre or school', 'Personal services',
   array['memberships', 'hr', 'attachments'], 34),
  ('childcare', 'Childcare or kindergarten', 'Personal services',
   array['memberships', 'hr', 'attachments'], 35),

  -- Professional practices
  ('law_firm', 'Law firm', 'Professional',
   array['legal', 'timesheets', 'attachments'], 40),
  ('accounting_firm', 'Accounting or tax practice', 'Professional',
   array['multi_company', 'timesheets', 'mbrs', 'secretarial'], 41),
  ('audit_firm', 'Audit firm', 'Professional',
   array['multi_company', 'timesheets', 'mbrs', 'attachments'], 42),
  ('secretarial_firm', 'Company secretarial practice', 'Professional',
   array['secretarial', 'multi_company', 'attachments'], 43),
  ('consulting', 'Consulting or advisory', 'Professional',
   array['timesheets', 'approvals'], 44),
  ('it_services', 'IT services or software', 'Professional',
   array['timesheets', 'ticketing', 'ai'], 45),
  ('creative_agency', 'Creative or marketing agency', 'Professional',
   array['timesheets', 'attachments'], 46),
  ('engineering', 'Engineering or architecture', 'Professional',
   array['timesheets', 'approvals', 'attachments'], 47),

  -- Property
  ('property_strata', 'Strata management (JMB or MC)', 'Property',
   array['property_strata', 'attachments', 'ticketing'], 50),
  ('property_landlord', 'Landlord or property owner', 'Property',
   array['property_nonstrata', 'fixed_assets'], 51),
  ('property_agency', 'Property agency', 'Property',
   array['attachments'], 52),
  ('developer', 'Property developer', 'Property',
   array['property_nonstrata', 'fixed_assets', 'approvals'], 53),

  -- Making and moving things
  ('manufacturer', 'Manufacturer', 'Industry',
   array['manufacturing', 'forecasting', 'fixed_assets'], 60),
  ('wholesale', 'Wholesale or distribution', 'Industry',
   array['forecasting', 'branches'], 61),
  ('construction', 'Construction or contracting', 'Industry',
   array['timesheets', 'fixed_assets', 'approvals'], 62),
  ('logistics', 'Transport or logistics', 'Industry',
   array['fixed_assets', 'timesheets'], 63),
  ('printing', 'Printing or signage', 'Industry',
   array['pos', 'manufacturing'], 64),
  ('agriculture', 'Agriculture or plantation', 'Industry',
   array['fixed_assets', 'timesheets'], 65),

  -- Everything else
  ('hotel', 'Hotel, hostel or homestay', 'Hospitality and travel',
   array['pos', 'memberships', 'fixed_assets'], 70),
  ('events', 'Events or venue hire', 'Hospitality and travel',
   array['pos', 'timesheets'], 71),
  ('travel_agency', 'Travel agency', 'Hospitality and travel',
   array['memberships'], 72),
  ('security_services', 'Security or cleaning services', 'Labour',
   array['hr', 'payroll', 'timesheets'], 80),
  ('staffing', 'Staffing or outsourcing', 'Labour',
   array['hr', 'payroll', 'timesheets', 'approvals'], 81),
  ('ngo', 'Association, society or NGO', 'Not for profit',
   array['attachments', 'approvals'], 90),
  ('other', 'Something else', 'Other', array[]::text[], 999)
on conflict (code) do update
  set name         = excluded.name,
      sector       = excluded.sector,
      module_codes = excluded.module_codes,
      sort_order   = excluded.sort_order,
      is_active    = true;

-- ---------------------------------------------------------------------
-- Applying the answer
--
-- One call rather than the screen making N calls to `set_own_module`:
-- a company that is half set up because the fourth of six requests
-- failed is a company whose modules do not match what it was shown and
-- charged for.
--
-- The writing itself still goes through `set_own_module`, which is the
-- one audited path a company enables a module by (`0488`) and the one
-- that refuses somebody who is not an owner or admin. Core modules are
-- skipped rather than refused: they are already on, and a list that
-- names one is a list, not a mistake worth stopping for.
-- ---------------------------------------------------------------------
create or replace function public.apply_business_type(
  p_org_id uuid,
  p_business_type text default null,
  p_modules text[] default null)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_wanted text[];
  v_code   text;
  v_n      integer := 0;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may set up the company'
      using errcode = '42501';
  end if;

  if p_business_type is not null
     and not exists (select 1 from public.business_types
                      where code = p_business_type and is_active) then
    raise exception 'There is no business type %', p_business_type
      using errcode = 'P0002';
  end if;

  update public.organizations
     set business_type = p_business_type
   where id = p_org_id;

  -- Told explicitly, or the type's own list. Not both: the screen
  -- shows the type's list with the ticks somebody has moved, and what
  -- it sends is the answer.
  v_wanted := coalesce(
    p_modules,
    (select module_codes from public.business_types
      where code = p_business_type),
    array[]::text[]);

  foreach v_code in array v_wanted loop
    -- Already on for everybody, and `set_own_module` refuses a core
    -- module rather than shrugging at it.
    continue when exists (select 1 from public.platform_modules
                           where code = v_code and is_core);
    perform public.set_own_module(p_org_id, v_code, true);
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

comment on function public.apply_business_type(uuid, text, text[]) is
  'Records what the company said it does and switches on the modules '
  'it was shown. 0553.';

revoke all on function public.apply_business_type(uuid, text, text[])
  from public, anon;
grant execute on function public.apply_business_type(uuid, text, text[])
  to authenticated;

-- ---------------------------------------------------------------------
-- A person is not a business registration number
-- ---------------------------------------------------------------------
create or replace function app.identify_an_individual()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if new.entity_type = 'individual'::app.entity_type
     and coalesce(new.einvoice_id_type, 'BRN') = 'BRN' then
    -- The two LHDN accepts for a person. A Malaysian is identified by
    -- NRIC; somebody without one is identified by the passport they do
    -- have. `ARMY` is the third and is nobody's default.
    new.einvoice_id_type := case
      when coalesce(new.country_code, 'MYS') = 'MYS' then 'NRIC'
      else 'PASSPORT'
    end;
  end if;
  return new;
end $$;

comment on function app.identify_an_individual() is
  'Files a person under NRIC or PASSPORT rather than BRN, which '
  'MyInvois rejects. 0553.';

drop trigger if exists identify_an_individual on public.organizations;
create trigger identify_an_individual
  before insert or update of entity_type, country_code, einvoice_id_type
  on public.organizations
  for each row execute function app.identify_an_individual();
