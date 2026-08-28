-- ---------------------------------------------------------------------
-- Which country the company is in, asked before anything else.
--
-- `organizations.country_code` has been on the table since `0003` with
-- a default of MYS, and `create_organization` never took it: every
-- company set up through the product was Malaysian whether it was or
-- not. The column was right and nothing filled it.
--
-- So the setup screen asks first — the answer changes what the rest of
-- the form is even asking about, since an SSM number and an LHDN TIN
-- are Malaysian things and a company in Singapore has neither — and the
-- answer arrives here.
--
-- Appended last, with the default the column already had. Every
-- existing caller passes its arguments positionally and by name; a
-- parameter in the middle would have silently shifted them, and a
-- required one would have broken the callers that predate it. A company
-- set up by anything that has not been updated is still Malaysian,
-- which is what it was yesterday.
--
-- `ref_countries` already holds the list — 56 rows of alpha-2, alpha-3
-- and dialling code since `0011` — so there is nothing to seed and no
-- second list to keep in step.
-- ---------------------------------------------------------------------

-- The old sixteen-argument version, dropped rather than left beside
-- this one.
--
-- A default does not replace a function, it overloads it: with both in
-- place a caller that omits `p_country_code` resolves to the *old* one
-- and sets no country at all, which is the failure this migration
-- exists to end, now arriving silently and only for callers that were
-- not updated. One function, so there is one answer.
drop function if exists public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint);

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
    current_date, coalesce(nullif(btrim(p_country_code), ''), 'MYS'),
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

-- `0165`'s event trigger strips PUBLIC and anon from anything created
-- or replaced in `public`, so the grant goes back on. Authenticated
-- only: creating an organization is something a signed-in person does.
revoke all on function public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text) from public;
grant execute on function public.create_organization(
  text, text, app.entity_type, text, text, text, text, text, text, text,
  text, text, text, boolean, text, smallint, text) to authenticated;
