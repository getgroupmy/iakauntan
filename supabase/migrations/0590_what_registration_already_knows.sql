-- =====================================================================
-- iAkauntan :: 0590 what registration already knows
--
-- Three things registration is told and setup then asks for again, and
-- one number the register issues that this schema had a column for and
-- no way to type into.
--
-- ---------------------------------------------------------------------
-- 1. An accountant is a third answer, not a kind of business
--
-- `profiles.use_kind` has held 'personal' or 'business' since 0558, and
-- the wizard reads it to skip the question it already answered. An
-- accounting practice signing up is neither of those in the way that
-- matters here: they are not setting up THEIR books first, they are
-- setting up a list of other people''s. What follows from that answer is
-- different from what follows from "a business" -- the Multi-Company
-- module from the start, and no "what kind of business?" question,
-- because the kind of business is not what they are here to tell us.
--
-- Anything that is not one of the three is still no answer at all: the
-- check refuses it, and `handle_new_user` files null rather than taking
-- the whole registration down over a word a client made up.
--
-- ---------------------------------------------------------------------
-- 2. The company name and the entity type, asked once
--
-- Registration asks five things of everybody. A business is now asked
-- two more -- what the company is called, and what legal form it takes
-- -- and both were being asked AGAIN on the first screen of setup, of
-- somebody who had typed them ten seconds earlier.
--
-- They are on the profile rather than in a table of their own because
-- that is what they are: an answer this person gave, kept so a form can
-- offer it back. `country_code` and `state_code` are already there for
-- exactly the same reason and get used the same way. The `signup_`
-- prefix is the honest part -- a business name is not a fact about a
-- person, and a column called `business_name` on `profiles` would read
-- as though it were.
--
-- Nothing reads them after setup, and setup does not clear them.
-- Clearing would mean a second company created on the same sign-in
-- loses the offer, and an answer that was true once is not false later.
--
-- ---------------------------------------------------------------------
-- 3. The old registration number
--
-- `organizations.old_registration_no` has existed since 0001 and
-- `create_organization` never took one, so the only way to fill it was
-- SQL against production. A company incorporated before 2019 has two
-- numbers -- 200201003726 and (571389-H) -- and a business registered
-- under ROB likewise. Both are printed on the letterhead, and the old
-- one is what half the counterparties in the country still have on
-- file.
--
-- NOT required, and that is deliberate: a company incorporated after
-- 2019 has never had one, and a mandatory box in front of somebody with
-- nothing to put in it is a box that gets a made-up number.
--
-- Adding a parameter is a DROP and a re-create rather than a replace:
-- a defaulted parameter added to an existing signature makes a second
-- overload, and then every existing call is ambiguous. The body below
-- is `pg_get_functiondef` of the live function with the parameter and
-- the column threaded through it, and nothing else touched.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What somebody said at registration
-- ---------------------------------------------------------------------

alter table public.profiles
  drop constraint if exists profiles_use_kind_known;

alter table public.profiles
  add constraint profiles_use_kind_known
  check (use_kind is null
         or use_kind in ('personal', 'business', 'accountant'));

alter table public.profiles
  add column if not exists signup_business_name text,
  add column if not exists signup_entity_type text;

comment on column public.profiles.use_kind is
  'What this person said they were signing up for: ''personal'' (one '
  'person invoicing under their own name), ''business'' (a registered '
  'company, whatever its form), or ''accountant'' (a practice keeping '
  'other people''s books, which starts with Multi-Company and is never '
  'asked what kind of business it is). Null for an account made before '
  'the question existed or by an invitation -- those people are asked '
  'at setup, as everybody was before 0558.';

comment on column public.profiles.signup_business_name is
  'The company name a business typed at REGISTRATION, kept only so '
  'setup can offer it back instead of asking again ten seconds later. '
  'Not a fact about the person, which is what the `signup_` prefix is '
  'for, and not read by anything after setup. Never cleared: a second '
  'company opened on the same sign-in would otherwise lose the offer, '
  'and an answer that was true once is not false later.';

comment on column public.profiles.signup_entity_type is
  'The legal form a business chose at registration, as text rather '
  'than `app.entity_type` -- it is an answer to be offered back, not a '
  'classification this schema is standing behind, and a bad one must '
  'not be able to fail a sign-up. Checked against the enum''s labels '
  'on the way in all the same.';

-- ---------------------------------------------------------------------
-- The trigger that files it
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- The door, before anything is written. An invitation opens it: the
  -- same rows, and the same "still in date", that the claim below uses.
  if not app.signups_open()
     and not exists (select 1
                       from public.org_members m
                      where m.invited_email = new.email
                        and m.user_id is null
                        and m.status = 'invited'
                        and (m.invite_expires_at is null
                             or m.invite_expires_at > now())) then
    raise exception '%', app.signup_closed_message()
      using errcode = '42501';
  end if;

  insert into public.profiles (id, email, full_name, avatar_url,
                               salutation, phone, country_code, state_code,
                               use_kind, signup_business_name,
                               signup_entity_type)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name',
             new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url',
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'salutation', '')), ''),
    -- The form sends the two halves and the database puts them
    -- together, so the trunk-prefix zero is dropped by the same rule
    -- whoever is registering somebody.
    app.phone_e164(new.raw_user_meta_data ->> 'phone_dial',
                   new.raw_user_meta_data ->> 'phone_national'),
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'country_code', '')), ''),
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'state_code', '')), ''),
    -- Anything that is not one of the two answers is no answer at all.
    -- The constraint would refuse it and take the whole registration
    -- with it, and a sign-up that fails because a client sent a word
    -- nobody recognises is a worse outcome than a question asked twice.
    case
      when new.raw_user_meta_data ->> 'use_kind'
             in ('personal', 'business', 'accountant')
        then new.raw_user_meta_data ->> 'use_kind'
      else null
    end,
    -- The two a business is asked for at registration, kept so setup
    -- can offer them back rather than asking again. Trimmed to null
    -- when absent, which is every personal and accountant sign-up.
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'business_name', '')), ''),
    -- Checked against the enum the same way `use_kind` is, and for the
    -- same reason: a word nobody recognises would take the whole
    -- registration down with it, and a sign-up that fails because a
    -- client sent nonsense is worse than a question asked twice.
    case
      when new.raw_user_meta_data ->> 'entity_type'
             in ('sdn_bhd', 'bhd', 'enterprise', 'partnership', 'llp',
                 'sole_proprietor', 'association', 'government', 'other')
        then new.raw_user_meta_data ->> 'entity_type'
      else null
    end
  )
  on conflict (id) do nothing;

  -- Claim any pending invitations addressed to this e-mail -- but only
  -- ones still in date. accept_invitation has always refused an expired
  -- invitation; this path used to take it anyway. A null expiry is
  -- honoured for rows raised before invite_member set one.
  update public.org_members
     set user_id  = new.id,
         status   = 'active',
         joined_at = now(),
         invite_token = null
   where invited_email = new.email
     and user_id is null
     and status = 'invited'
     and (invite_expires_at is null or invite_expires_at > now());

  return new;
end;
$function$;

comment on function app.handle_new_user() is
  'Turns a new `auth.users` row into a profile, and claims any '
  'invitation addressed to that e-mail. Refuses the whole registration '
  'when sign-ups are closed and no invitation opens the door. Files '
  '`use_kind`, and the company name and entity type a business gave, '
  'so setup does not ask for what registration already collected -- '
  'each of them null rather than fatal when the value is not one this '
  'schema recognises.';

-- ---------------------------------------------------------------------
-- And the number the register issues first
-- ---------------------------------------------------------------------

drop function if exists public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text);

CREATE OR REPLACE FUNCTION public.create_organization(p_name text, p_slug text DEFAULT NULL::text, p_entity_type app.entity_type DEFAULT 'sdn_bhd'::app.entity_type, p_registration_no text DEFAULT NULL::text, p_tin text DEFAULT NULL::text, p_msic_code text DEFAULT NULL::text, p_business_activity text DEFAULT NULL::text, p_state_code text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_postcode text DEFAULT NULL::text, p_address_line1 text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_is_sst_registered boolean DEFAULT false, p_sst_registration_no text DEFAULT NULL::text, p_fiscal_year_end_month smallint DEFAULT 12, p_country_code text DEFAULT 'MYS'::text, p_old_registration_no text DEFAULT NULL::text)
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
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text, text) is
  'Creates a company and everything it cannot open without: the chart '
  'of accounts, the tax codes, a fiscal calendar, a sales pipeline, and '
  'the caller as its owner. Refuses a second company without the '
  'Multi-Company module, naming the way out. `p_old_registration_no` '
  'is optional and always will be -- a company incorporated after 2019 '
  'has never had one.';

-- 0165 strips EXECUTE from PUBLIC and anon on every function created in
-- `app` or `public`, and a DROP takes the grants with it either way.
-- Said out loud because a silent 42501 on the sign-up path is the one
-- failure nobody can work around.
grant execute on function public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text, text) to authenticated;
