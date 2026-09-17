-- =====================================================================
-- iAkauntan :: billing another company in the group
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/intercompany_billing.sql
--
-- The assertion this file exists for is the boundary. Inter-company
-- billing has to let a clerk in the subsidiary handle a bill from the
-- holding company *without* access to the holding company's ledger — so
-- it cannot use `app.group_orgs`, which requires membership of both.
--
-- What opens one company's document to another is the addressing: an
-- invoice raised on a customer whose `linked_org_id` is B has been sent
-- to B by name. Same group is necessary and not sufficient, and there is
-- a third company here to prove it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ic_org(p_name text, p_owner uuid, p_group uuid)
returns uuid language plpgsql as $$
declare v uuid; v_out uuid; v_in uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by, group_id)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner, p_group)
  returning id into v;

  perform app.seed_chart_of_accounts(v);
  select id into v_out from public.accounts where org_id = v and code = '2130';
  select id into v_in  from public.accounts where org_id = v and code = '1410';

  insert into public.tax_codes (org_id, code, name, tax_type_code, rate,
    applies_to, sales_tax_account_id, purchase_tax_account_id,
    is_exempt, is_default)
  values (v, 'NA',  'Not Applicable', '06', 0, 'both', v_out, v_in, false, true),
         (v, 'ST8', 'Service Tax 8%', '02', 8, 'both', v_out, v_in, false, false);
  return v;
end; $$;

do $$
declare
  v_alice uuid := pg_temp.another_user('alice@ic.test');
  v_bob   uuid := pg_temp.another_user('bob@ic.test');
  v_zara  uuid := pg_temp.another_user('zara@ic.test');
  v_group uuid; v_a uuid; v_b uuid; v_c uuid;
  v_cust uuid; v_sup uuid; v_inv uuid; v_bill uuid; v_other uuid;
  v_terms uuid;
  v_n int; v_refused boolean; v_msg text; v_status text; v_lines int;
  v_taxcode text; v_supdoc text; v_total numeric;
begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan IC', v_alice) returning id into v_group;

  v_a := pg_temp.ic_org('IC Holdings Sdn Bhd', v_alice, v_group);
  v_b := pg_temp.ic_org('IC Sub Sdn Bhd', v_bob, v_group);
  v_c := pg_temp.ic_org('IC Other Sdn Bhd', v_zara, v_group);

  -- The premise. If this ever stops being true the rest of the file is
  -- testing something easier than the real thing.
  perform pg_temp.check_true(
    'the person who will accept the bill is not a member of the company '
    'that issued it',
    not exists (select 1 from public.org_members
                 where org_id = v_a and user_id = v_bob));

  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_a, 'C-SUB', 'IC Sub', 'customer', v_b) returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type, linked_org_id)
  values (v_b, 'S-HOLD', 'IC Holdings', 'supplier', v_a) returning id into v_sup;

  -- A management fee from the holding company to the subsidiary.
  -- With a due date, which is the normal case and the one `0439` found
  -- was not being copied. Thirty days: the terms two companies in a
  -- group settle on with each other.
  insert into public.payment_terms (org_id, code, name, days, term_type)
  values (v_a, 'NET30', '30 Days', 30, 'net')
  on conflict (org_id, code) do update set days = 30
  returning id into v_terms;

  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
    doc_date, due_date, payment_term_id,
    subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_a, 'invoice', 'INV-IC-1', v_cust, current_date,
          current_date + 30, v_terms,
          10000, 800, 10800, 10800, 'posted')
  returning id into v_inv;

  insert into public.sales_document_lines (org_id, document_id, line_no,
    description, quantity, unit_price, tax_code_id, tax_rate, tax_amount,
    line_subtotal, line_total)
  values (v_a, v_inv, 1, 'Management fee', 1, 8000,
          (select id from public.tax_codes where org_id = v_a and code = 'ST8'),
          8, 640, 8000, 8640),
         (v_a, v_inv, 2, 'Company secretarial', 1, 2000,
          (select id from public.tax_codes where org_id = v_a and code = 'ST8'),
          8, 160, 2000, 2160);

  -- One A raised on somebody outside the group, which must never appear.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_a, 'C-OUT', 'An outsider', 'customer') returning id into v_other;
  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
    doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_a, 'invoice', 'INV-OUT-1', v_other, current_date,
          5000, 0, 5000, 5000, 'posted');

  -- ---------------------------------------------------------------
  -- Who may see it
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_bob);
  select count(*) into v_n from public.intercompany_inbox(v_b);
  perform pg_temp.check_eq(
    'the company an invoice was addressed to sees it, and does not see the '
    'one addressed to an outsider', v_n, 1);

  perform pg_temp.sign_in_as(v_zara);
  select count(*) into v_n from public.intercompany_inbox(v_c);
  perform pg_temp.check_eq(
    'while a third company in the same group sees nothing — being in the '
    'group is not what opens a document, the addressing is', v_n, 0);

  -- ---------------------------------------------------------------
  -- Accepting
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_bob);
  v_bill := public.accept_intercompany_bill(v_inv, v_b);

  select status::text, supplier_doc_no, total_amount
    into v_status, v_supdoc, v_total
    from public.purchase_documents where id = v_bill;
  select count(*) into v_lines
    from public.purchase_document_lines where document_id = v_bill;

  perform pg_temp.check_true(
    'the bill arrives as a draft — posting entries into a company nobody '
    'in it entered is how a ledger stops reconciling', v_status = 'draft');
  perform pg_temp.check_true('carrying their number, which an SST audit asks for',
    v_supdoc = 'INV-IC-1');
  perform pg_temp.check_eq('and the same money', v_total, 10800);
  perform pg_temp.check_eq('with both lines', v_lines, 2);

  -- `0439`. The date it falls due was the one figure on the invoice
  -- that was not copied. `report_ap_aging` buckets on
  -- `coalesce(due_date, doc_date)`, so a null aged the bill from the
  -- day it was raised and the group showed itself thirty days in
  -- arrears for the whole of the credit period it had agreed -- on both
  -- sides of the same transaction, since the seller's ledger has the
  -- real date and the buyer's did not.
  perform pg_temp.check_eq(
    'and the date it falls due, which the ageing buckets on',
    (select due_date::text from public.purchase_documents where id = v_bill),
    (current_date + 30)::text);
  perform pg_temp.check_eq(
    'and the terms it was raised on, not only the date they produce',
    (select payment_term_id from public.purchase_documents where id = v_bill),
    v_terms);

  -- The control: the two sides agree. A bill that took the invoice's
  -- date but from the wrong column -- `doc_date`, say -- would pass the
  -- first assertion if the fixture happened to have them equal.
  perform pg_temp.check_true(
    'and the two sides of the transaction fall due on the same day',
    (select b.due_date from public.purchase_documents b where b.id = v_bill)
      = (select d.due_date from public.sales_documents d where d.id = v_inv)
    and (select b.due_date <> b.doc_date from public.purchase_documents b
          where b.id = v_bill));

  select t.code into v_taxcode
    from public.purchase_document_lines l
    join public.tax_codes t on t.id = l.tax_code_id
   where l.document_id = v_bill and l.line_no = 1;
  perform pg_temp.check_true('the tax code carried across by code', v_taxcode = 'ST8');
  perform pg_temp.check_true(
    'and it is the receiving company''s own row — an id from the issuer''s '
    'masters would point at nothing here, or at something else by accident',
    (select org_id from public.tax_codes
      where id = (select tax_code_id from public.purchase_document_lines
                   where document_id = v_bill and line_no = 1)) = v_b);
  perform pg_temp.check_eq(
    'and no expense account is guessed, because that is a decision in the '
    'receiving company''s own chart',
    (select count(*) from public.purchase_document_lines
      where document_id = v_bill and account_id is not null), 0);

  -- ---------------------------------------------------------------
  -- Twice
  -- ---------------------------------------------------------------
  v_refused := false; v_msg := '';
  begin
    perform public.accept_intercompany_bill(v_inv, v_b);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.sign_in_as(v_bob);
  perform pg_temp.check_true(
    'accepting the same invoice twice is refused, and for that reason '
    'rather than any other: ' || v_msg,
    v_refused and v_msg like '%already been billed%');
  perform pg_temp.check_eq('so there is one bill, not two',
    (select count(*) from public.purchase_documents
      where source_sales_document_id = v_inv), 1);
  perform pg_temp.check_true(
    'and the inbox says it was dealt with rather than hiding it',
    (select already_billed from public.intercompany_inbox(v_b)
      where sales_document_id = v_inv));

  -- ---------------------------------------------------------------
  -- Somebody else's company
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_zara);
  v_refused := false;
  begin
    perform public.accept_intercompany_bill(v_inv, v_b);
  exception when others then v_refused := true;
  end;
  perform pg_temp.sign_in_as(v_zara);
  perform pg_temp.check_true(
    'and somebody outside the receiving company cannot raise a bill in it',
    v_refused);

  -- ---------------------------------------------------------------
  -- 0146's correction to 0145
  --
  -- A purchase document records tax a supplier charged us, and a
  -- supplier charges what their own registration says. 0145 policed
  -- this and should not have.
  -- ---------------------------------------------------------------
  perform pg_temp.sign_in_as(v_bob);
  -- Through the function, because since 0181 there is no other way in:
  -- a direct write to sst_registered_from is refused by
  -- app.guard_sst_registration(). The assertion below is unchanged by
  -- that — app.reject_tax_before_registration() keys off
  -- `sst_registered_from` alone and never reads `is_sst_registered`, so
  -- registering B properly from a date thirty days out sets up the same
  -- "dated before its own registration" case the direct update did.
  perform public.set_sst_registration(
    v_b, true, current_date + 30, 'W10-1808-31000002', 'ST8');

  insert into public.purchase_documents (org_id, doc_type, doc_no, doc_date,
    contact_id, subtotal, tax_amount, total_amount, base_total_amount, status)
  values (v_b, 'bill', 'BILL-TAXED', current_date, v_sup,
          1000, 80, 1080, 1080, 'draft');
  perform pg_temp.check_true(
    'a company can record a supplier''s tax whatever its own registration '
    'date says',
    exists (select 1 from public.purchase_documents where doc_no = 'BILL-TAXED'));

  -- The control: one trigger was removed, not the rule.
  v_refused := false;
  begin
    insert into public.sales_documents (org_id, doc_type, doc_no, contact_id,
      doc_date, subtotal, tax_amount, total_amount, base_total_amount, status)
    values (v_b, 'invoice', 'SALE-TAXED', v_sup, current_date,
            1000, 80, 1080, 1080, 'draft');
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true(
    'while it still cannot charge tax before its own registration date',
    v_refused);
end $$;

rollback;
