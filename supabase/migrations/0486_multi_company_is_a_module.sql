-- ---------------------------------------------------------------------
-- 0486  Multi-company is a module, and adding a company is a door
-- ---------------------------------------------------------------------
-- Holding more than one company on one account is the largest thing
-- this product does that nobody pays for. `create_organization` asks
-- only that somebody be signed in, so a single account can stand up
-- fifty tenants -- chart of accounts, tax codes, fiscal calendar and
-- all -- and `create_firm` asks no more than that either, though a
-- practice exists only to hold other people's companies.
--
-- ### The rule
--
-- **The first company is what signing up is for. Everything after it
-- is Multi-Company.**
--
-- `app.can_add_company()` says so in one place: true when the caller
-- owns no company yet, or when a company they own holds the module.
-- Owns, not belongs to -- somebody invited into a colleague's books
-- has not spent anything, and their own first company must still be
-- free.
--
-- Both doors ask it. `create_organization` refuses the second company
-- without it, and `create_firm` refuses a practice, because a practice
-- is the multi-company case with a nameplate on it. Refusing at
-- `create_firm` rather than only at the companies is deliberate: a
-- firm that could be started for nothing and then used to attach
-- companies would be the module with the price taken off.
--
-- `public.can_add_company()` is the same answer for the app, so the
-- button can be absent rather than present and refusing.
--
-- ### What this does not do
--
-- It does not take a company away from anybody. Every account that
-- already has several keeps them; the gate is on the next one. And
-- every company already attached to a firm is given the module here,
-- because it is a multi-company arrangement by construction and
-- charging for the door after somebody has walked through it would be
-- a bill for something they already have.
--
-- ### Mutants
--
-- Run against `supabase/tests/multi_company.sql`, each named with the
-- assertion that kills it:
--   * the gate dropped from `create_organization` -- "a second company
--     needs the module";
--   * the gate dropped from `create_firm` -- "and so does a practice";
--   * the first company gated too -- "the first company is free";
--   * membership counted instead of ownership -- "somebody invited
--     into a colleague's books still gets their own first company";
--   * the module read on any company rather than one they own --
--     "a module on somebody else's company is not yours";
--   * `is_core` set true on the module -- "it is an add-on, not core".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values
  ('multi_company', 'Multi-Company',
   'More than one company on one sign-in: add companies, switch between '
   'them, pay their bills together and group their figures.',
   false, 39.00,
   coalesce((select max(sort_order) + 10 from public.platform_modules), 100),
   true)
on conflict (code) do update
  set name          = excluded.name,
      description   = excluded.description,
      monthly_price = excluded.monthly_price,
      -- `is_core` too. Without it a deployment that somehow holds this
      -- as a core module keeps it -- and a core module is on for
      -- everybody, which is the one thing this migration exists to
      -- stop. It is also what let the "core" mutant survive: the row
      -- was already right, and re-applying could not make it wrong.
      is_core       = excluded.is_core,
      is_active     = true;

-- Every company already in a firm is a multi-company arrangement, and
-- was one before this migration existed.
insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
select o.id, 'multi_company', true, now(),
       'Enabled by 0486: already attached to a firm.'
  from public.organizations o
 where o.firm_id is not null
on conflict (org_id, module_code) do update
  set is_enabled = true, expires_at = null;

-- ---------------------------------------------------------------------
-- Who may add one
-- ---------------------------------------------------------------------
create or replace function app.can_add_company()
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select auth.uid() is not null
     and (
       -- Nobody's first company is an add-on. Ownership, not
       -- membership: being invited into a colleague's books is not
       -- something the person spent anything on.
       not exists (
         select 1 from public.org_members m
          where m.user_id = auth.uid()
            and m.role = 'owner' and m.status = 'active')
       or exists (
         select 1 from public.org_members m
          where m.user_id = auth.uid()
            and m.role = 'owner' and m.status = 'active'
            and app.has_module(m.org_id, 'multi_company')));
$$;

comment on function app.can_add_company() is
  'True when the caller may stand up another company: their first is '
  'free, and every one after it needs Multi-Company on a company they '
  'own. See 0486.';

revoke all on function app.can_add_company() from public, anon;
grant execute on function app.can_add_company() to authenticated;

-- The same answer, for a screen deciding whether to draw the button.
create or replace function public.can_add_company()
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select app.can_add_company();
$$;

comment on function public.can_add_company() is
  'Whether this account may add another company, so the app can leave '
  'the button out rather than offer one that refuses. See 0486.';

revoke all on function public.can_add_company() from public, anon;
grant execute on function public.can_add_company() to authenticated;

-- ---------------------------------------------------------------------
-- The two doors
-- ---------------------------------------------------------------------
-- Both restated from the built definition rather than from the
-- migration that last wrote them -- 0485 restated a function from an
-- older copy and silently dropped a clause somebody had added in
-- between. The only change in each is the guard.
CREATE OR REPLACE FUNCTION public.create_organization(p_name text, p_slug text DEFAULT NULL::text, p_entity_type app.entity_type DEFAULT 'sdn_bhd'::app.entity_type, p_registration_no text DEFAULT NULL::text, p_tin text DEFAULT NULL::text, p_msic_code text DEFAULT NULL::text, p_business_activity text DEFAULT NULL::text, p_state_code text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_postcode text DEFAULT NULL::text, p_address_line1 text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_is_sst_registered boolean DEFAULT false, p_sst_registration_no text DEFAULT NULL::text, p_fiscal_year_end_month smallint DEFAULT 12, p_country_code text DEFAULT 'MYS'::text)
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
    name, legal_name, slug, entity_type, registration_no, tin, msic_code,
    business_activity, state_code, city, postcode, address_line1,
    phone, email, is_sst_registered, sst_registration_no,
    fiscal_year_end_month, einvoice_tin, einvoice_id_value, einvoice_id_type,
    books_start_date, country_code, created_by
  ) values (
    p_name, p_name, v_slug, p_entity_type, p_registration_no, p_tin, p_msic_code,
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

CREATE OR REPLACE FUNCTION public.create_firm(p_name text, p_registration_no text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id     uuid;
  v_base   text;
  v_slug   text;
  v_suffix integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 0486. A practice is the multi-company case with a nameplate on it,
  -- and a firm that could be started for nothing and then used to
  -- attach companies would be the module with the price taken off.
  if not app.can_add_company() then
    raise exception
      'Starting a practice needs the Multi-Company module. Turn it on '
      'for a company you already own, under Settings, and then start '
      'the practice.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A firm needs a name.' using errcode = '23514';
  end if;

  v_base := trim(both '-' from
    regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g'));
  if v_base = '' then v_base := 'firm'; end if;
  v_slug := v_base;
  while exists (select 1 from public.firms f where f.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := v_base || '-' || v_suffix;
  end loop;

  insert into public.firms (name, slug, registration_no, email, phone,
                            created_by)
  values (btrim(p_name), v_slug, p_registration_no, p_email, p_phone,
          auth.uid())
  returning id into v_id;

  -- The person who starts a practice is a partner in it, or nobody can
  -- do anything with it afterwards.
  insert into public.firm_members (firm_id, user_id, role, status, joined_at)
  values (v_id, auth.uid(), 'partner', 'active', now());

  return v_id;
end;
$function$;

revoke all on function public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text) from public, anon;
grant execute on function public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text) to authenticated;
revoke all on function public.create_firm(text, text, text, text)
  from public, anon;
grant execute on function public.create_firm(text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_org  text := pg_get_functiondef(
    'public.create_organization(text, text, app.entity_type, text, text,
     text, text, text, text, text, text, text, text, boolean, text,
     smallint, text)'::regprocedure);
  v_firm text := pg_get_functiondef(
    'public.create_firm(text, text, text, text)'::regprocedure);
begin
  if position('can_add_company' in v_org) = 0 then
    raise exception '0486: another company is still free';
  end if;
  if position('can_add_company' in v_firm) = 0 then
    raise exception '0486: a practice is still free';
  end if;
  if not exists (select 1 from public.platform_modules
                  where code = 'multi_company' and is_active
                    and not is_core) then
    raise exception '0486: the module is missing, inactive or core';
  end if;
  if not has_function_privilege('authenticated',
       'public.can_add_company()', 'execute') then
    raise exception '0486: the app cannot ask';
  end if;
end $do$;

-- ---------------------------------------------------------------------
-- Somewhere to look at it
-- ---------------------------------------------------------------------
-- `demo_rebuild.sql` holds every active module to having a demo tenant
-- that shows it, and a module registered with nowhere to be seen would
-- fail that gate the moment this migration applied. The practice's
-- companies are the multi-company case, so the detector is told to
-- read them as such -- rather than the module being switched on for a
-- tenant by hand, which is the kind of list somebody has to remember
-- to update. Restated from the built definition.
CREATE OR REPLACE FUNCTION app.demo_modules_in_use()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct x.org_id, x.module_code
      from (
        select org_id, 'pos'          as module_code from public.pos_outlets
        union all
        select org_id, 'loyalty'      from public.loyalty_programs
        union all
        select org_id, 'memberships'  from public.pos_memberships
        union all
        select org_id, 'ticketing'    from public.tickets
        union all
        select org_id, 'hr'           from public.employees
        union all
        select org_id, 'fixed_assets' from public.fixed_assets
        union all
        select org_id, 'inventory'    from public.warehouses
        union all
        select org_id, 'purchases'    from public.purchase_documents
        union all
        -- 0324. Not detected from rows, unlike every line above it.
        -- Attachments hang off records that already exist rather than
        -- having a subject of their own, so a tenant that happens not
        -- to have uploaded a file yet would show nothing about a
        -- feature it can perfectly well demonstrate.
        select id, 'attachments' from public.organizations where is_demo
        union all
        -- 0329, and for the same reason twice over. A name on our
        -- domain exists only once somebody has asked for one and an
        -- operator has agreed; mail arrives only once somebody has
        -- written to the address. A tenant rebuilt this morning has
        -- neither and never will by itself.
        select id, 'workspace_address'
          from public.organizations where is_demo
        union all
        select id, 'mailbox' from public.organizations where is_demo
        union all
        -- 0486. A company attached to a firm is the multi-company case
        -- by construction: somebody is holding it alongside others on
        -- one sign-in, which is the whole of what the module is.
        select id, 'multi_company'
          from public.organizations where is_demo and firm_id is not null
        union all
        -- 0470, and the same reason a third time. Asking a question is
        -- something a visitor does; a tenant rebuilt this morning has
        -- asked nothing and never will by itself. What the module
        -- demonstrates is the books it reads, and those are there.
        select id, 'ai' from public.organizations where is_demo
      ) x
      join public.organizations g on g.id = x.org_id and g.is_demo
     where not exists (
       select 1 from public.org_modules om
        where om.org_id = x.org_id and om.module_code = x.module_code
          and om.is_enabled)
  loop
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
    values (r.org_id, r.module_code, true, now(),
            'Enabled by app.demo_modules_in_use: the tenant has data for it.')
    on conflict (org_id, module_code) do update
      set is_enabled = true, expires_at = null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

revoke all on function app.demo_modules_in_use()
  from public, anon, authenticated;
