-- =====================================================================
-- iAkauntan :: 0607 a company is a kind of business too
--
-- `0605` made the list of business kinds a table and moved
-- `contacts.entity_type` onto it. It deliberately left
-- `organizations.entity_type` on the `app.entity_type` enum, and said
-- why: that one has a statutory reader and deserves its own commit.
--
-- This is that commit.
--
-- ---------------------------------------------------------------------
-- The statutory reader
--
-- `fs_deadlines` -- built in `0172`, restated in `0419` and again in
-- `0497` -- decides whether a company files its financial statements as
-- a public company:
--
--     select o.entity_type = 'bhd' into v_public
--
-- That is the difference between CA 2016 s.340 (laid at the AGM) and
-- s.258 (circulated to members). It is the only place in the schema
-- where a company's kind changes what the law requires of it.
--
-- A string comparison against one member of a list an administrator can
-- now add to is exactly the wrong shape: an administrator adding
-- `berhad_public` would get a company whose accounts are filed under
-- the private-company rule, silently, and nobody would find out until a
-- lodgement was late. So the comparison moves onto the column `0605`
-- put there for it -- `entity_types.is_public_company` -- and a new kind
-- has to SAY whether it is public rather than being guessed at by name.
--
-- The answer does not change for any of the ten: `bhd` is the only row
-- seeded `is_public_company`, which is precisely what `= 'bhd'` meant.
-- `entity_types.sql` asserts that, and `mbrs.sql` asserts the deadline
-- either side of it.
--
-- ---------------------------------------------------------------------
-- And a second one, which this migration did not expect
--
-- `app.identify_an_individual`, from `0553`, is a BEFORE trigger on
-- `organizations` that reads:
--
--     if new.entity_type = 'individual'::app.entity_type
--
-- and files that company under NRIC or PASSPORT instead of BRN,
-- because MyInvois rejects a business registration number for a
-- person. It is the same shape of defect as the MBRS one and was found
-- the same way the MBRS one was not: Postgres refused the ALTER,
-- because a trigger that names a column in `update of` pins that
-- column's type.
--
-- So it gets the same treatment -- `entity_types.is_individual`, added
-- here, true for the one row that shipped meaning it. An administrator
-- adding `foreign_individual` now has somewhere to say so, instead of
-- getting a person invoiced under a company number.
--
-- The trigger is dropped before the ALTER and recreated after it,
-- naming the same three columns.
--
-- ---------------------------------------------------------------------
-- What else reads the column
--
--   * `create_organization` takes it as `app.entity_type`, so a company
--     cannot be created as a kind the enum does not have -- which is
--     every kind an administrator adds. The parameter becomes `text`.
--     That is a new signature, so the enum one is dropped: leaving both
--     would make every call ambiguous.
--
--   * `platform_organizations` RETURNS it as `app.entity_type`. A
--     plpgsql function whose query no longer matches its declared
--     result type fails at run time, not at create time, so this has to
--     move in the same migration as the column. Return types cannot be
--     replaced in place either -- it is dropped and recreated.
--
--   * `app.demo_company` still takes `app.entity_type`. Left alone: the
--     demo seed names three kinds, all of them built in, and an enum
--     goes into a text column through the ordinary assignment cast.
--
--   * `profiles.signup_entity_type` has been `text` since `0590` and
--     gets no foreign key here. `0590` chose that deliberately -- it
--     records what somebody typed into the registration form, "null
--     rather than fatal when the value is not one this schema
--     recognises", and a key on it would turn a retired kind into a
--     registration that cannot be saved.
--
-- ---------------------------------------------------------------------
-- The enum is still not dropped
--
-- `app.demo_company` takes it. Two hundred lines of demo seed pass
-- literals cast to it. Dropping it is a tidying migration with no
-- reader left to please, and it is not this one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The column
--
-- The cast is exact, the same way `contacts` was: every value in the
-- column is a member of the enum, every member of the enum is a row in
-- `entity_types`, so no company changes its kind.
--
-- `on delete restrict`, and `platform_delete_entity_type` refuses a
-- delete that would hit it. A kind is retired by switching it off.
-- ---------------------------------------------------------------------
-- The second answer that has to live on the row rather than in a
-- string comparison. Same reasoning as `is_public_company` in 0605:
-- what a kind MEANS belongs to the kind.
alter table public.entity_types
  add column if not exists is_individual boolean not null default false;

comment on column public.entity_types.is_individual is
  'True where this kind of business is a natural person. LHDN will not '
  'accept a business registration number for one, so '
  '`app.identify_an_individual` files them under NRIC or PASSPORT. '
  'Added by 0607; true for `individual` alone, which is what the '
  'trigger''s `= ''individual''` meant.';

update public.entity_types set is_individual = true where code = 'individual';

-- A trigger that names a column in `update of` pins that column's
-- type, so this has to go before the ALTER and come back after it.
drop trigger if exists identify_an_individual on public.organizations;

alter table public.organizations
  alter column entity_type drop default;

alter table public.organizations
  alter column entity_type type text using entity_type::text;

alter table public.organizations
  alter column entity_type set default 'sdn_bhd';

alter table public.organizations
  add constraint organizations_entity_type_fkey
  foreign key (entity_type) references public.entity_types (code)
  on update cascade on delete restrict;

comment on column public.organizations.entity_type is
  'What kind of business this company is, from `entity_types`. Read '
  'for meaning in exactly one place: `fs_deadlines` joins to '
  '`entity_types.is_public_company` to choose between CA 2016 s.340 '
  'and s.258. See 0607.';

-- ---------------------------------------------------------------------
-- A person is not a business registration number
--
-- Restated from `0553` with the enum comparison replaced by the column
-- above. The behaviour for all ten kinds is identical: `individual` is
-- the only row with `is_individual`, which is exactly what
-- `= 'individual'::app.entity_type` selected.
--
-- `coalesce(..., false)` because the lookup can miss for one row in
-- one direction: the foreign key is checked at the END of the
-- statement and this is a BEFORE trigger, so an insert naming a kind
-- that does not exist reaches here before it is refused. Treating that
-- as "not a person" leaves `einvoice_id_type` alone and the foreign
-- key still refuses the row a moment later.
-- ---------------------------------------------------------------------
create or replace function app.identify_an_individual()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if coalesce((select t.is_individual from public.entity_types t
                where t.code = new.entity_type), false)
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
  'MyInvois rejects. Which kinds are people is '
  '`entity_types.is_individual` from 0607, not the string '
  '''individual''. 0553.';

create trigger identify_an_individual
  before insert or update of entity_type, country_code, einvoice_id_type
  on public.organizations
  for each row execute function app.identify_an_individual();

-- ---------------------------------------------------------------------
-- Deleting a kind now has a second thing to check
--
-- `0605` refused a delete that would leave contacts pointing at
-- nothing. Companies point at it too from here, and the foreign key
-- above would refuse the delete anyway -- with a constraint name, at
-- the end of a console form, which is not an answer either. The count
-- is named the same way the contact count is.
-- ---------------------------------------------------------------------
create or replace function public.platform_delete_entity_type(p_code text)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_used bigint;
  v_orgs bigint;
  v_builtin boolean;
begin
  if not app.is_platform_admin() then
    raise exception 'The kinds of business are the whole platform''s list '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  select is_builtin into v_builtin
    from public.entity_types where code = p_code;
  if v_builtin is null then
    raise exception 'No such kind of business' using errcode = 'P0002';
  end if;
  if v_builtin then
    raise exception 'The kinds this shipped with cannot be removed, only '
                    'switched off — a company''s own record still holds '
                    'them'
      using errcode = '23503';
  end if;

  select count(*) into v_used
    from public.contacts where entity_type = p_code;
  if v_used > 0 then
    raise exception 'Switch it off instead: % contact(s) are filed as this '
                    'kind, and removing it would leave them pointing at '
                    'nothing', v_used
      using errcode = '23503';
  end if;

  select count(*) into v_orgs
    from public.organizations where entity_type = p_code;
  if v_orgs > 0 then
    raise exception 'Switch it off instead: % company/companies are filed '
                    'as this kind, and removing it would leave them '
                    'pointing at nothing', v_orgs
      using errcode = '23503';
  end if;

  delete from public.entity_types where code = p_code;
  return true;
end;
$function$;

comment on function public.platform_delete_entity_type(text) is
  'Removes a kind of business that nothing is filed as. Refuses a '
  'built-in one, and refuses one that any contact or any company is '
  'filed as, naming how many — all three are cases where switching it '
  'off is what was wanted. 0607 added the company half.';

-- ---------------------------------------------------------------------
-- Creating a company
--
-- The parameter was `app.entity_type`, which is to say: a company could
-- only ever be created as one of the ten this shipped with. An
-- administrator who adds `co_operative` to the list would see it in the
-- registration dropdown and get a 22P02 on submit.
--
-- Restated from `0590`'s definition with the third parameter as `text`
-- and nothing else changed. The old signature is dropped rather than
-- left beside it: two overloads differing only in that parameter make
-- every call ambiguous, and the call that would fail is the sign-up
-- path.
--
-- The foreign key is what validates it now. A code that is not a row
-- raises 23503 and names the constraint, which is a worse message than
-- the enum's -- so the function says it first, in words, and names the
-- console page where the list lives.
-- ---------------------------------------------------------------------
drop function if exists public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text, text);

CREATE OR REPLACE FUNCTION public.create_organization(p_name text, p_slug text DEFAULT NULL::text, p_entity_type text DEFAULT 'sdn_bhd'::text, p_registration_no text DEFAULT NULL::text, p_tin text DEFAULT NULL::text, p_msic_code text DEFAULT NULL::text, p_business_activity text DEFAULT NULL::text, p_state_code text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_postcode text DEFAULT NULL::text, p_address_line1 text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_is_sst_registered boolean DEFAULT false, p_sst_registration_no text DEFAULT NULL::text, p_fiscal_year_end_month smallint DEFAULT 12, p_country_code text DEFAULT 'MYS'::text, p_old_registration_no text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org_id uuid; v_slug text; v_ar_id uuid; v_ap_id uuid;
  v_out_tax_id uuid; v_in_tax_id uuid; v_svc_tax uuid; v_na_tax uuid;
  v_pipeline_id uuid; v_suffix integer := 0; v_base text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 0607. The column is a foreign key now, so an unknown kind is a
  -- 23503 naming a constraint at the end of a form somebody has just
  -- filled in. Said in words first, and said where the list is.
  if not exists (select 1 from public.entity_types t
                  where t.code = p_entity_type) then
    raise exception '% is not a kind of business this platform knows. '
                    'A platform administrator adds one under Console → '
                    'Kinds of business.', coalesce(p_entity_type, '(none)')
      using errcode = '23503';
  end if;

  -- 0486. The first company is what signing up is for; every one after
  -- it is the Multi-Company module. The message names the way out,
  -- because somebody who has just typed a company's details into a
  -- form is owed better than a refusal.
  if not app.can_add_company() then
    raise exception
      'Adding another company needs the Multi-Company module. Turn it '
      'on for a company you already own, under Settings, and then add '
      'this one.'
      using errcode = '42501';
  end if;

  v_base := trim(both '-' from regexp_replace(lower(coalesce(p_slug, p_name)), '[^a-z0-9]+', '-', 'g'));
  if v_base = '' then v_base := 'org'; end if;
  v_slug := v_base;
  while exists (select 1 from public.organizations o where o.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.organizations (
    name, legal_name, slug, entity_type, registration_no,
    old_registration_no, tin, msic_code,
    business_activity, state_code, city, postcode, address_line1,
    phone, email, is_sst_registered, sst_registration_no,
    fiscal_year_end_month, einvoice_tin, einvoice_id_value, einvoice_id_type,
    books_start_date, country_code, created_by
  ) values (
    p_name, p_name, v_slug, p_entity_type, p_registration_no,
    nullif(btrim(coalesce(p_old_registration_no, '')), ''), p_tin, p_msic_code,
    p_business_activity, p_state_code, p_city, p_postcode, p_address_line1,
    p_phone, p_email, p_is_sst_registered, p_sst_registration_no,
    p_fiscal_year_end_month, p_tin, p_registration_no, 'BRN',
    app.today(), coalesce(nullif(btrim(p_country_code), ''), 'MYS'),
    auth.uid()
  ) returning id into v_org_id;

  perform app.seed_chart_of_accounts(v_org_id);

  select id into v_ar_id from public.accounts where org_id = v_org_id and code = '1210';
  select id into v_ap_id from public.accounts where org_id = v_org_id and code = '2110';
  select id into v_out_tax_id from public.accounts where org_id = v_org_id and code = '2130';
  select id into v_in_tax_id from public.accounts where org_id = v_org_id and code = '1410';

  insert into public.tax_codes (
    org_id, code, name, tax_type_code, rate, applies_to,
    sales_tax_account_id, purchase_tax_account_id, is_exempt, is_default
  ) values
    (v_org_id,'NA','Not Applicable','06',0,'both',v_out_tax_id,v_in_tax_id,false,true),
    (v_org_id,'ST8','Service Tax 8%','02',8,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'ST6','Service Tax 6%','02',6,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'SL10','Sales Tax 10%','01',10,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'SL5','Sales Tax 5%','01',5,'both',v_out_tax_id,v_in_tax_id,false,false),
    (v_org_id,'TTX','Tourism Tax','03',0,'sales',v_out_tax_id,null,false,false),
    (v_org_id,'EXM','Exempt','E',0,'both',v_out_tax_id,v_in_tax_id,true,false),
    (v_org_id,'ZR','Zero Rated / Export','06',0,'sales',v_out_tax_id,null,false,false)
  on conflict (org_id, code) do nothing;

  select id into v_na_tax from public.tax_codes where org_id = v_org_id and code = 'NA';
  select id into v_svc_tax from public.tax_codes where org_id = v_org_id and code = 'ST8';

  update public.organizations
     set default_sales_tax_code_id = case when p_is_sst_registered then v_svc_tax else v_na_tax end,
         default_purchase_tax_code_id = case when p_is_sst_registered then v_svc_tax else v_na_tax end
   where id = v_org_id;

  insert into public.payment_terms (org_id, code, name, days, term_type, is_default) values
    (v_org_id,'COD','Cash on Delivery',0,'cod',false),
    (v_org_id,'PREPAID','Prepaid',0,'prepaid',false),
    (v_org_id,'NET7','7 Days',7,'net',false),
    (v_org_id,'NET14','14 Days',14,'net',false),
    (v_org_id,'NET30','30 Days',30,'net',true),
    (v_org_id,'NET60','60 Days',60,'net',false),
    (v_org_id,'NET90','90 Days',90,'net',false),
    (v_org_id,'EOM30','End of Month + 30',30,'eom',false)
  on conflict (org_id, code) do nothing;

  insert into public.warehouses (org_id, code, name, is_default, state_code, city)
  values (v_org_id, 'MAIN', 'Main Warehouse', true, p_state_code, p_city)
  on conflict (org_id, code) do nothing;

  insert into public.price_levels (org_id, code, name, is_default) values
    (v_org_id,'STD','Standard Price',true),
    (v_org_id,'WHL','Wholesale',false),
    (v_org_id,'RTL','Retail',false)
  on conflict (org_id, code) do nothing;

  insert into public.pipelines (org_id, name, description, is_default)
  values (v_org_id, 'Sales Pipeline', 'Default sales process', true)
  returning id into v_pipeline_id;

  insert into public.pipeline_stages (org_id, pipeline_id, name, probability, stage_type, color, sort_order) values
    (v_org_id,v_pipeline_id,'Qualification',10,'open','#94A3B8',1),
    (v_org_id,v_pipeline_id,'Needs Analysis',25,'open','#60A5FA',2),
    (v_org_id,v_pipeline_id,'Proposal Sent',50,'open','#818CF8',3),
    (v_org_id,v_pipeline_id,'Negotiation',75,'open','#FBBF24',4),
    (v_org_id,v_pipeline_id,'Closed Won',100,'won','#34D399',5),
    (v_org_id,v_pipeline_id,'Closed Lost',0,'lost','#F87171',6);

  perform public.create_fiscal_year(v_org_id, null);

  update public.profiles set last_org_id = v_org_id where id = auth.uid();
  return v_org_id;
end; $function$;

comment on function public.create_organization(
  text, text, text, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text, text) is
  'Creates a company and everything it cannot open without: the chart '
  'of accounts, the tax codes, a fiscal calendar, a sales pipeline, and '
  'the caller as its owner. Refuses a second company without the '
  'Multi-Company module, naming the way out. `p_old_registration_no` '
  'is optional and always will be -- a company incorporated after 2019 '
  'has never had one. `p_entity_type` became text in 0607 so a kind of '
  'business added in the console can actually be chosen.';

-- 0165 strips EXECUTE from PUBLIC and anon on every function created in
-- `app` or `public`, and a DROP takes the grants with it either way.
-- Said out loud because a silent 42501 on the sign-up path is the one
-- failure nobody can work around.
revoke all on function public.create_organization(
  text, text, text, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text, text) from public, anon;
grant execute on function public.create_organization(
  text, text, text, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- The console's list of companies
--
-- `platform_organizations` declares `entity_type app.entity_type` in its
-- RETURNS TABLE. The column is text from here, so the query no longer
-- matches -- and a plpgsql result-type mismatch is a run-time 42804,
-- raised the first time a platform administrator opens the companies
-- page rather than when this migration runs. That is why it moves in
-- the same file as the column.
--
-- A return type cannot be replaced by CREATE OR REPLACE. Dropped and
-- recreated, with the grant restated after it for the reason above.
-- ---------------------------------------------------------------------
drop function if exists public.platform_organizations();

create or replace function public.platform_organizations()
returns table (
  id uuid, name text, slug text, status text, entity_type text,
  registration_no text, tin text, einvoice_enabled boolean,
  einvoice_environment text, created_at timestamptz,
  member_count bigint, invoice_count bigint, invoiced_value numeric,
  modules text[])
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501';
  end if;

  return query
    select o.id, o.name, o.slug::text, o.status, o.entity_type,
           o.registration_no, o.tin, o.einvoice_enabled,
           o.einvoice_environment, o.created_at,
           (select count(*) from public.org_members m
             where m.org_id = o.id and m.status = 'active'),
           (select count(*) from public.sales_documents d
             where d.org_id = o.id and d.doc_type = 'invoice' and d.deleted_at is null),
           (select coalesce(sum(d.base_total_amount), 0) from public.sales_documents d
             where d.org_id = o.id and d.doc_type = 'invoice'
               and d.status not in ('draft','void') and d.deleted_at is null),
           (select coalesce(array_agg(om.module_code order by om.module_code), '{}')
              from public.org_modules om
             where om.org_id = o.id and om.is_enabled)
      from public.organizations o
     where o.deleted_at is null
     order by o.created_at desc;
end;
$$;

revoke all on function public.platform_organizations() from public, anon;
grant execute on function public.platform_organizations() to authenticated;

-- ---------------------------------------------------------------------
-- CA 2016 s.340 or s.258
--
-- The one statutory read. Restated from `0497` with the string
-- comparison replaced by the column `0605` put on the row for it, and
-- nothing else changed -- same `app.fs_lodge_by`, same `app.today()`,
-- same two sentences of basis.
--
-- `coalesce(..., false)` is kept, and now covers a second case as well
-- as the first: a filing whose company has been deleted (no row, so
-- null), and a company whose kind has somehow no matching row (the
-- foreign key says it cannot, and a deadline is not the place to find
-- out that it did). Private is the safe default of the two: it is the
-- earlier obligation, so a company wrongly treated as private is told
-- about a deadline sooner rather than later.
-- ---------------------------------------------------------------------
create or replace function public.fs_deadlines(p_filing_id uuid)
returns table(circulate_by date, lodge_by date, outside_limit date,
              circulated_on date, lodged_on date, days_left integer,
              is_late boolean, basis text)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  v_public boolean;
  v_circulate date;
  v_lodge date;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.is_org_member(f.org_id) then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  -- 0607. Was `o.entity_type = 'bhd'`.
  select t.is_public_company into v_public
    from public.organizations o
    join public.entity_types t on t.code = o.entity_type
   where o.id = f.org_id;

  v_circulate := (f.fy_end + interval '6 months')::date;

  -- Thirty days from what actually happened, falling back to thirty days
  -- from the deadline when it has not happened yet. The rule itself is
  -- in `app.fs_lodge_by`, which the nightly notification pass also
  -- calls -- see 0497.
  v_lodge := app.fs_lodge_by(f.fy_end, f.circulated_on);

  return query select
    v_circulate,
    v_lodge,
    (v_circulate + 30)::date,
    f.circulated_on,
    f.lodged_on,
    (v_lodge - app.today())::integer,
    f.lodged_on is null and app.today() > v_lodge,
    case when coalesce(v_public, false)
      then 'CA 2016 s.340 — laid at the AGM within six months of the year '
           'end — and s.259, lodged within thirty days of that meeting.'
      else 'CA 2016 s.258 — circulated to members within six months of the '
           'year end — and s.259, lodged within thirty days of circulation.'
    end;
end $$;

comment on function public.fs_deadlines(uuid) is
  'CA 2016 s.258/s.259, or s.340/s.259 for a public company. Which of '
  'the two is decided by `entity_types.is_public_company` from 0607, '
  'not by comparing the company''s kind against the string ''bhd''.';

-- ---------------------------------------------------------------------
-- The demo seed's own front door
--
-- `app.demo_company` takes `app.entity_type` and hands it straight to
-- `create_organization`, whose third parameter is now text. Function
-- resolution does not apply an I/O conversion cast in an implicit
-- context, so that call would stop finding a function at all -- and it
-- would stop at the first `demo_rebuild`, not here.
--
-- One cast in the body fixes it. The signature is left alone
-- deliberately: two hundred lines of demo seed across a dozen
-- migrations pass `'sdn_bhd'::app.entity_type` to it, and those are
-- applied migrations that cannot be edited.
-- ---------------------------------------------------------------------
create or replace function app.demo_company(
  p_owner            uuid,
  p_name             text,
  p_entity_type      app.entity_type,
  p_registration_no  text,
  p_tin              text,
  p_msic_code        text,
  p_activity         text,
  p_state_code       text,
  p_city             text,
  p_postcode         text,
  p_address          text,
  p_phone            text,
  p_email            text,
  p_fye_month        smallint default 12)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  perform app.demo_act_as(p_owner);

  -- Deliberately not registered for SST here; see 0185. Where a demo
  -- company should be registered, the caller uses
  -- set_sst_registration() afterwards.
  v_org := public.create_organization(
    p_name, null, p_entity_type::text, p_registration_no, p_tin, p_msic_code,
    p_activity, p_state_code, p_city, p_postcode, p_address,
    p_phone, p_email, false, null, p_fye_month);

  update public.organizations set is_demo = true where id = v_org;
  return v_org;
end $$;

-- ---------------------------------------------------------------------
-- The one form with nobody signed in
--
-- The registration form asks for a kind of business, and `0605`
-- granted `entity_types` to `authenticated` alone -- correctly, for a
-- dropdown inside the app. Registration is the one screen outside it.
--
-- So the list joins the three `signup_reference` already answers with:
-- one SECURITY DEFINER call, answered as `anon`, handing back public
-- facts. Granting `anon` a policy on the table itself would work and is
-- worse -- it widens what an unauthenticated session can read from the
-- schema in order to fill in one dropdown.
--
-- `for_organizations`, because this form is a company registering
-- itself and a company is not an `individual`. That is the same
-- distinction `0605` put the column there for, now with a reader.
--
-- Restated whole from `0563`: everything else here is unchanged.
-- ---------------------------------------------------------------------
create or replace function public.signup_reference()
returns jsonb
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object(
    'signups_open', app.signups_open(),
    -- Null while it is open, so a form cannot accidentally draw the
    -- closed notice from a field that is always populated.
    'signups_closed_message',
      case when app.signups_open() then null
           else app.signup_closed_message() end,
    'dial_codes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', c.code, 'name', c.name,
               'alpha2', c.alpha2, 'dial_code', c.dial_code)
             order by c.name), '[]'::jsonb)
        from public.ref_countries c
       where c.is_active
         and coalesce(c.dial_code, '') <> ''),
    'salutations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', s.code, 'name', s.name,
               'grouping', s.grouping, 'note', s.note)
             order by s.sort_order, s.name), '[]'::jsonb)
        from public.salutations s
       where s.is_active),
    -- The thirteen states and three federal territories. Offered only
    -- where they mean something -- the form draws a box instead
    -- outside Malaysia -- but sent always, because the country can be
    -- changed after the list has loaded and a second round trip to
    -- fetch sixteen rows would draw an empty picker in the meantime.
    'states', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', st.code, 'name', st.name)
             order by st.code), '[]'::jsonb)
        from public.ref_states st),
    -- 0607. The kinds a COMPANY may be, which is not quite the list a
    -- contact may be: `individual` is `for_organizations = false`.
    'entity_types', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', t.code, 'label', t.label, 'label_my', t.label_my)
             order by t.sort_order, t.code), '[]'::jsonb)
        from public.entity_types t
       where t.is_active and t.for_organizations));
$function$;

comment on function public.signup_reference() is
  'Everything the registration form needs before anybody is signed in: '
  'whether registration is open and what to say if not, the dialling '
  'codes, the salutations, the Malaysian states, and the kinds of '
  'business a company may be. One call, answered as anon, all of it '
  'public. 0607 added the kinds.';

revoke all on function public.signup_reference() from public;
grant execute on function public.signup_reference() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Saying a kind is a person
--
-- `is_individual` is a decision about a kind of business, so the person
-- adding the kind is the one who has to make it -- and until the setter
-- takes it, the only way to set it is a hand-written UPDATE, which is
-- not a feature.
--
-- The eight-argument signature is dropped rather than left beside the
-- nine: PostgREST resolves an RPC by the NAMES of the arguments it was
-- given, and two candidates whose names are a prefix of one another is
-- how a console save silently reaches the older one.
-- ---------------------------------------------------------------------
drop function if exists public.platform_save_entity_type(
  text, text, text, integer, boolean, boolean, boolean, boolean);

create or replace function public.platform_save_entity_type(
  p_code text,
  p_label text,
  p_label_my text default null,
  p_sort_order integer default null,
  p_is_active boolean default null,
  p_is_public_company boolean default null,
  p_for_contacts boolean default null,
  p_for_organizations boolean default null,
  p_is_individual boolean default null)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_code text;
  v_existing public.entity_types%rowtype;
begin
  if not app.is_platform_admin() then
    raise exception 'The kinds of business are the whole platform''s list '
                    'and may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  v_code := lower(btrim(coalesce(p_code, '')));
  if v_code = '' then
    raise exception 'A kind of business needs a code' using errcode = '23514';
  end if;
  if coalesce(btrim(p_label), '') = '' then
    raise exception 'A kind of business needs a name' using errcode = '23514';
  end if;

  -- 0607. A kind cannot be both. A public company is a company with
  -- shareholders and an AGM; a natural person has neither, and a row
  -- claiming both would send the same company down two rules that
  -- contradict each other.
  if coalesce(p_is_individual, false) and coalesce(p_is_public_company, false)
  then
    raise exception 'A kind of business cannot be both a person and a '
                    'public company'
      using errcode = '23514';
  end if;

  select * into v_existing from public.entity_types where code = v_code;

  if v_existing.code is null then
    -- The check constraint says what a code may look like; this says it
    -- in words, because an administrator typing "Sdn Bhd" into the code
    -- box should be told what is wrong rather than shown a constraint
    -- name.
    if v_code !~ '^[a-z][a-z0-9_]{1,40}$' then
      raise exception 'A code is lower-case letters, digits and '
                      'underscores, starting with a letter — for example '
                      'co_operative'
        using errcode = '23514';
    end if;
    insert into public.entity_types
      (code, label, label_my, sort_order, is_active, is_public_company,
       for_contacts, for_organizations, is_individual, is_builtin, updated_by)
    values
      (v_code, btrim(p_label), nullif(btrim(p_label_my), ''),
       coalesce(p_sort_order, 100),
       coalesce(p_is_active, true),
       coalesce(p_is_public_company, false),
       coalesce(p_for_contacts, true),
       coalesce(p_for_organizations, true),
       coalesce(p_is_individual, false),
       false, auth.uid());
    return v_code;
  end if;

  -- An absent argument means "leave it", the same shape
  -- `platform_save_landing_section` uses. Correcting a label must not
  -- silently switch a kind off.
  --
  -- Which is also why the either/or above is re-checked against what is
  -- already on the row: an update that sets only one of the two can
  -- still produce a row holding both.
  if coalesce(p_is_individual, v_existing.is_individual)
     and coalesce(p_is_public_company, v_existing.is_public_company) then
    raise exception 'A kind of business cannot be both a person and a '
                    'public company'
      using errcode = '23514';
  end if;

  update public.entity_types set
    label             = coalesce(nullif(btrim(p_label), ''), label),
    label_my          = coalesce(nullif(btrim(p_label_my), ''), label_my),
    sort_order        = coalesce(p_sort_order, sort_order),
    is_active         = coalesce(p_is_active, is_active),
    is_public_company = coalesce(p_is_public_company, is_public_company),
    for_contacts      = coalesce(p_for_contacts, for_contacts),
    for_organizations = coalesce(p_for_organizations, for_organizations),
    is_individual     = coalesce(p_is_individual, is_individual),
    updated_by        = auth.uid()
   where code = v_code;

  return v_code;
end;
$function$;

comment on function public.platform_save_entity_type(
  text, text, text, integer, boolean, boolean, boolean, boolean, boolean) is
  'Adds or amends a kind of business. An absent argument means "leave '
  'it alone", so correcting a label cannot switch a kind off. 0607 '
  'added `p_is_individual` and the rule that a kind cannot be both a '
  'person and a public company.';

revoke all on function public.platform_save_entity_type(
  text, text, text, integer, boolean, boolean, boolean, boolean, boolean)
  from public, anon;
grant execute on function public.platform_save_entity_type(
  text, text, text, integer, boolean, boolean, boolean, boolean, boolean)
  to authenticated;
