-- `create_organization`: the repository carries a statement that has
-- never done anything.
--
-- First of the three functions the drift check flagged and `0175` left
-- open. Like `0174` and `0175`, **production is the correct side** — but
-- for a different reason. There the repository was missing something
-- real. Here the repository has something extra, and the extra thing is
-- dead.
--
-- ## The difference
--
-- Three things, all in the repository's favour to lose:
--
-- 1. A declared `v_sales_tax` that is selected into and never read.
-- 2. A slug loop that re-derives the whole slug from `p_name` on every
--    iteration instead of appending to a base computed once.
-- 3. This, at `0012_bootstrap.sql:339`:
--
--        update public.accounts set is_system = true
--         where org_id = v_org_id
--           and code in ('1210','2110','2130','1410','3300','4990');
--
-- ## Why the third one does nothing
--
-- `app.seed_chart_of_accounts` runs fifty lines earlier and inserts
-- every account in the chart with `is_system` hardcoded — not
-- `v_row.is_system`, which is what the loop variable would suggest, but
-- a literal `true`:
--
--        is_group, is_system, sort_order
--      ) values (
--        p_org_id, v_row.code, v_row.name, ...
--        v_row.is_group, true, v_row.sort_order
--
-- All six of those codes are seeded accounts. They are already
-- `is_system` before the update runs, so the update matches six rows and
-- changes none of them. It was dead when it was written, in the same
-- file, a hundred and forty-six lines below the statement that made it
-- redundant — which is exactly the kind of thing nobody catches by
-- reading, because both halves look right on their own.
--
-- Confirmed on the hosted project, which has been running without the
-- block: all three tenants, all six codes, `is_system` true everywhere.
--
-- ## What this does not fix
--
-- `accounts.is_system` is documented in `0003_masters.sql` as "created
-- by setup, cannot be deleted". Nothing enforces that. No policy, no
-- constraint, no trigger and no function reads the column — every
-- mention in the schema writes it. And because the seed sets it `true`
-- for the entire chart rather than for the accounts that genuinely
-- cannot go, a check written against it today would refuse to delete
-- any seeded account at all, which is not what the comment means either.
--
-- That is a real gap and it is deliberately not closed here. This
-- migration reconciles a drift finding; giving `is_system` teeth is a
-- change of behaviour that needs its own decision about which accounts
-- are actually undeletable. Left as it is, and now written down.

create or replace function public.create_organization(
  p_name                  text,
  p_slug                  text default null,
  p_entity_type           app.entity_type default 'sdn_bhd',
  p_registration_no       text default null,
  p_tin                   text default null,
  p_msic_code             text default null,
  p_business_activity     text default null,
  p_state_code            text default null,
  p_city                  text default null,
  p_postcode              text default null,
  p_address_line1         text default null,
  p_phone                 text default null,
  p_email                 text default null,
  p_is_sst_registered     boolean default false,
  p_sst_registration_no   text default null,
  p_fiscal_year_end_month smallint default 12
)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
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
    books_start_date, created_by
  ) values (
    p_name, p_name, v_slug, p_entity_type, p_registration_no, p_tin, p_msic_code,
    p_business_activity, p_state_code, p_city, p_postcode, p_address_line1,
    p_phone, p_email, p_is_sst_registered, p_sst_registration_no,
    p_fiscal_year_end_month, p_tin, p_registration_no, 'BRN',
    current_date, auth.uid()
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
end; $$;
