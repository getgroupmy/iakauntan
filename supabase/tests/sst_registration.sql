-- =====================================================================
-- iAkauntan :: SST registration
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sst_registration.sql
--
-- Registering for SST is four facts, not one: the flag, the number, the
-- date it took effect, and the tax code new lines default to. Any three
-- of them is a company that believes it is charging tax and is not —
-- which was the state of this application until 0145, because
-- `is_sst_registered` was read by one settings card and nothing else.
--
-- The assertion that matters most is the last group: a document dated
-- before the effective date cannot carry tax. Collecting service tax you
-- are not registered for is not a rounding error.
--
-- Every refusal is paired with the thing that must still work, and the
-- refusal on the trigger checks the *message* as well — an insert can
-- fail for a missing column just as easily as for the rule under test,
-- and a test that only asks "did it fail?" passes either way.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- A company with the tax codes a real one is seeded with. Hand-written
-- rather than through `create_organization`, which needs auth.uid() and
-- brings a chart of accounts this file has no use for.
create or replace function pg_temp.sst_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v_org uuid; v_out uuid; v_in uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v_org;

  perform app.seed_chart_of_accounts(v_org);
  select id into v_out from public.accounts
   where org_id = v_org and code = '2130';
  select id into v_in from public.accounts
   where org_id = v_org and code = '1410';

  insert into public.tax_codes (
    org_id, code, name, tax_type_code, rate, applies_to,
    sales_tax_account_id, purchase_tax_account_id, is_exempt, is_default)
  values
    (v_org, 'NA',  'Not Applicable', '06', 0, 'both', v_out, v_in, false, true),
    (v_org, 'ST8', 'Service Tax 8%', '02', 8, 'both', v_out, v_in, false, false),
    (v_org, 'ZR',  'Zero Rated',     '06', 0, 'sales', v_out, null, false, false);

  return v_org;
end; $$;

do $$
declare
  v_owner uuid := pg_temp.another_user('owner@sst.test');
  v_clerk uuid := pg_temp.another_user('clerk@sst.test');
  v_org uuid; v_contact uuid; v_doc uuid;
  v_refused boolean; v_msg text; v_role text;
  v_code text; v_flag boolean; v_from date; v_no text;
begin
  v_org := pg_temp.sst_org('SST Test Sdn Bhd', v_owner);
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accountant', 'active', now());

  perform pg_temp.sign_in_as(v_owner);

  -- ---------------------------------------------------------------
  -- Registering needs every one of the four facts
  -- ---------------------------------------------------------------
  v_refused := false;
  begin
    perform public.set_sst_registration(v_org, true, null, 'W10-1234', 'ST8');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true(
    'registering without the effective date is refused — without it there '
    'is nothing to judge an invoice''s date against', v_refused);

  v_refused := false;
  begin
    perform public.set_sst_registration(v_org, true, date '2026-09-01', null, 'ST8');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true(
    'and without the number, which has to print on every tax invoice',
    v_refused);

  v_refused := false;
  begin
    perform public.set_sst_registration(
      v_org, true, date '2026-09-01', 'W10-1234', 'ZR');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true(
    'and a zero-rated default, which would leave every line at nothing '
    'while the company believed it was charging tax', v_refused);

  v_refused := false;
  begin
    perform public.set_sst_registration(
      v_org, true, date '2026-09-01', 'W10-1234', 'ST99');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and a code this company does not have', v_refused);

  -- Somebody who can post but not administer.
  perform pg_temp.sign_in_as(v_clerk);
  v_refused := false;
  begin
    perform public.set_sst_registration(
      v_org, true, date '2026-09-01', 'W10-1234', 'ST8');
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true(
    'and an accountant cannot register the company for tax', v_refused);

  -- ---------------------------------------------------------------
  -- The control: a complete registration, which moves the default
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.set_sst_registration(
      v_org, true, date '2026-09-01', 'W10-1234567890', 'ST8');
  end;
  reset role;

  perform pg_temp.check_true('registering ran as a client, not a superuser',
    v_role = 'authenticated');

  select is_sst_registered, sst_registered_from, sst_registration_no
    into v_flag, v_from, v_no from public.organizations where id = v_org;
  select code into v_code from public.tax_codes
   where org_id = v_org and is_default;

  perform pg_temp.check_true('the flag', v_flag);
  perform pg_temp.check_true('the date', v_from = date '2026-09-01');
  perform pg_temp.check_true('the number', v_no = 'W10-1234567890');
  perform pg_temp.check_true(
    'and the default tax code — the one thing the old switch never did, '
    'and the only one of the four that changes what an invoice says',
    v_code = 'ST8');
  perform pg_temp.check_eq('with exactly one default',
    (select count(*) from public.tax_codes
      where org_id = v_org and is_default), 1);

  -- ---------------------------------------------------------------
  -- A document dated before it carries no tax
  -- ---------------------------------------------------------------
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'A customer', 'customer') returning id into v_contact;

  v_refused := false; v_msg := '';
  begin
    insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
      doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
    values (v_org, 'invoice', 'PRE-1', v_contact, date '2026-08-15',
            1000, 80, 1080, 1080, 'draft');
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'a document dated before registration cannot carry tax, and is '
    'refused for that reason rather than any other: ' || v_msg,
    v_refused and v_msg like '%before SST registration took effect%');

  -- Two controls. Without them the refusal above would pass for a
  -- database that rejects every insert into this table.
  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
    doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_org, 'invoice', 'PRE-2', v_contact, date '2026-08-15',
          1000, 0, 1000, 1000, 'draft');
  perform pg_temp.check_true('while the same document without tax goes in',
    exists (select 1 from public.sales_documents where doc_no = 'PRE-2'));

  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
    doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_org, 'invoice', 'POST-1', v_contact, date '2026-09-02',
          1000, 80, 1080, 1080, 'draft') returning id into v_doc;
  perform pg_temp.check_true('and a taxed one on or after the date goes in',
    v_doc is not null);

  -- Inserting is not the only way in.
  v_refused := false;
  begin
    update public.sales_documents set doc_date = date '2026-08-01'
     where id = v_doc;
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true(
    'and a taxed document cannot be backdated past it either', v_refused);

  -- And explicitly *not* the same rule on the purchase side.
  --
  -- 0145 put the trigger on both tables and 0146 took it off this one.
  -- A purchase document records tax a *supplier* charged, and a supplier
  -- charges what their own registration says, not what ours does — an
  -- unregistered company can be charged service tax any day of the week
  -- and has to be able to record the bill. Asserted rather than merely
  -- deleted, because "we stopped checking" and "we decided not to check"
  -- look identical in a diff a year from now.
  insert into public.purchase_documents (org_id, doc_type, doc_no, contact_id,
    doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_org, 'bill', 'PB-1', v_contact, date '2026-08-15',
          1000, 80, 1080, 1080, 'draft');
  perform pg_temp.check_true(
    'a bill carrying a supplier''s tax records whatever our own '
    'registration date says',
    exists (select 1 from public.purchase_documents where doc_no = 'PB-1'));

  -- ---------------------------------------------------------------
  -- Coming off the register
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  perform public.set_sst_registration(v_org, false);

  select is_sst_registered, sst_registered_from, sst_registration_no
    into v_flag, v_from, v_no from public.organizations where id = v_org;
  select code into v_code from public.tax_codes
   where org_id = v_org and is_default;

  perform pg_temp.check_true('deregistering clears the flag', not v_flag);
  perform pg_temp.check_true(
    'and the number, which must not appear on a later invoice', v_no is null);
  perform pg_temp.check_true('and the date', v_from is null);
  perform pg_temp.check_true('and puts the default back to NA', v_code = 'NA');

  -- With the date gone, the guard stops policing. That is the same rule
  -- as a company that never set one, which is deliberate: 0145 refuses
  -- to judge a company by a date nobody has stated.
  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
    doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_org, 'invoice', 'OLD-1', v_contact, date '2026-08-15',
          1000, 80, 1080, 1080, 'draft');
  perform pg_temp.check_true(
    'and a company with no stated effective date is not policed at all',
    exists (select 1 from public.sales_documents where doc_no = 'OLD-1'));
end $$;

rollback;
