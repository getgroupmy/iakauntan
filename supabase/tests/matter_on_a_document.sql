-- =====================================================================
-- iAkauntan :: the matter a bill and an invoice belong to
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/matter_on_a_document.sql
--
-- `0691`. `0687` put the matter on `gl_lines` and `0688` made the
-- posting path carry it, but the two functions that turn a fee note and
-- a supplier bill into ledger entries read their dimensions off
-- `sales_document_lines` and `purchase_document_lines` -- and neither
-- had the column. So a matter's trial balance reported its journals and
-- its client money and NOT ITS FEES.
--
-- The assertions that would fail if the wiring moved:
--
--   * A FEE LINE'S MATTER REACHES THE LEDGER. The whole point, and the
--     one thing a reviewer would assume rather than check.
--   * THE RECEIVABLE DOES NOT CARRY IT. 1210 is what the client owes
--     the firm, not what the file earned. Put the matter on both and
--     the matter's trial balance counts the same fee twice and still
--     balances -- which is the shape of wrong that never gets noticed.
--   * NOR THE TAX. Output and input tax are the firm's account with
--     the Customs Department and belong to no client.
--   * TWO MATTERS ON ONE DOCUMENT STAY APART. A fee note covering two
--     files is ordinary. A header field could not express it and a
--     per-line one that leaked would merge two clients' ledgers.
--   * A LINE WITH NO MATTER STAYS THE FIRM'S. Rent and salaries must
--     not land under whichever client was billed last.
--   * AND THE REPORT ACTUALLY MOVES. `report_matter_trial_balance` is
--     what all of this is for; asserting the column and not the report
--     would pass while the report stayed empty.
--
-- Plus the two structural rules: another firm's matter cannot be put on
-- this firm's line, and deleting a matter detaches the line rather than
-- taking `org_id` down with it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A one-line sales invoice, posted, with an optional matter on the line.
create or replace function pg_temp.fee_note(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_matter uuid default null, p_tax numeric default 0)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, tax_amount, total_amount, balance_amount,
     status)
  values (p_org, 'invoice', p_no, app.today(), p_contact, 'MYR', 1,
          p_amount, p_tax, p_amount + p_tax, p_amount + p_tax, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_rate, tax_amount, line_subtotal, line_total, matter_id)
  values (p_org, v_doc, 1, 'Professional fees', 1, p_amount,
          case when p_amount = 0 then 0 else p_tax * 100 / p_amount end,
          p_tax, p_amount, p_amount + p_tax, p_matter);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

-- A one-line supplier bill, posted, with an optional matter on the line.
create or replace function pg_temp.searcher_bill(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_matter uuid default null, p_tax numeric default 0)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, tax_amount, total_amount, balance_amount,
     status)
  values (p_org, 'bill', p_no, app.today(), p_contact, 'MYR', 1,
          p_amount, p_tax, p_amount + p_tax, p_amount + p_tax, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_rate, tax_amount, line_subtotal, line_total, matter_id)
  values (p_org, v_doc, 1, 'Land search', 1, p_amount,
          case when p_amount = 0 then 0 else p_tax * 100 / p_amount end,
          p_tax, p_amount, p_amount + p_tax, p_matter);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

-- The matters on the ledger lines a document posted, by account code.
create or replace function pg_temp.posted_matters(p_doc uuid)
returns table (code text, matter_id uuid)
language sql as $$
  select a.code, l.matter_id
    from public.gl_entries e
    join public.gl_lines l on l.entry_id = e.id
    join public.accounts a on a.id = l.account_id
   where e.source_id = p_doc
   order by a.code, l.line_no;
$$;

do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid;
  v_client uuid;
  v_supp   uuid;
  v_m1     uuid;
  v_m2     uuid;
  v_m3     uuid;
  v_deleted boolean;
  v_doc    uuid;
  v_n      integer;
  v_got    uuid;
  v_fees   numeric;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Shaharudin & Partners');
  perform public.create_fiscal_year(v_org, date_trunc('year', app.today())::date);
  perform public.setup_legal_module(v_org);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_client;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SP1', 'Pejabat Tanah', 'supplier') returning id into v_supp;

  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_client, v_owner)
  returning id into v_m1;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-2', 'A tenancy dispute', v_client, v_owner)
  returning id into v_m2;

  -- -----------------------------------------------------------------
  -- 1. A fee note billed to a matter
  -- -----------------------------------------------------------------
  v_doc := pg_temp.fee_note(v_org, v_client, 'FN-1', 1000.00, v_m1, 80.00);

  select matter_id into v_got from pg_temp.posted_matters(v_doc)
   where code = '4100';
  if v_got is distinct from v_m1 then
    raise exception 'the fee did not reach the matter: got %, wanted %',
      v_got, v_m1;
  end if;

  -- The receivable is the client's debt to the firm, not the file's
  -- earnings. Both carrying the matter would double the fee on the
  -- matter's own trial balance -- and it would still balance.
  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code = '1210' and matter_id is not null;
  if v_n <> 0 then
    raise exception 'the receivable leg carried a matter';
  end if;

  -- Output tax is owed to the Customs Department by the firm.
  --
  -- Asserted PRESENT first. `purchase_documents.tax_amount` is
  -- recalculated from the lines by a trigger, so a fixture that puts
  -- the tax on the header alone posts no tax leg at all -- and then
  -- "no tax leg carries a matter" is true because there is no tax leg,
  -- which is how the mutant that charges tax to the matter survived the
  -- first sweep this file was written for.
  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code = '2130';
  if v_n <> 1 then
    raise exception 'the fee note posted % output tax legs, wanted 1', v_n;
  end if;
  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code = '2130' and matter_id is not null;
  if v_n <> 0 then
    raise exception 'the output tax leg carried a matter';
  end if;

  -- And once it is posted the matter stops moving. `0691` adds it to
  -- `0402`'s frozen list because the journal is now built from it:
  -- changing it afterwards leaves the ledger saying one file and the
  -- invoice saying another, with nothing to reconcile them. Asserted
  -- on THIS note, whose matter is on the line and not on the header,
  -- so it is the line's own freeze being tested rather than the
  -- header's.
  begin
    update public.sales_document_lines
       set matter_id = v_m2 where document_id = v_doc;
    v_deleted := true;
  exception
    when insufficient_privilege then
      v_deleted := false;
  end;
  if v_deleted then
    raise exception 'a posted invoice line was moved to another matter';
  end if;

  -- -----------------------------------------------------------------
  -- 2. A disbursement bought for a matter
  -- -----------------------------------------------------------------
  v_doc := pg_temp.searcher_bill(v_org, v_supp, 'PB-1', 50.00, v_m1, 4.00);

  select matter_id into v_got from pg_temp.posted_matters(v_doc)
   where code = '5100';
  if v_got is distinct from v_m1 then
    raise exception 'the disbursement did not reach the matter: got %', v_got;
  end if;

  -- Both present, for the reason above: a missing leg would make the
  -- assertion below pass by having nothing to check.
  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code in ('2110', '1410');
  if v_n <> 2 then
    raise exception 'the bill posted % of the payable and input tax legs', v_n;
  end if;
  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code in ('2110', '1410') and matter_id is not null;
  if v_n <> 0 then
    raise exception 'the payable or input tax leg carried a matter';
  end if;

  -- -----------------------------------------------------------------
  -- 3. The firm's own costs stay the firm's
  -- -----------------------------------------------------------------
  v_doc := pg_temp.searcher_bill(v_org, v_supp, 'PB-2', 700.00, null);

  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where matter_id is not null;
  if v_n <> 0 then
    raise exception 'a bill with no matter put % lines on one', v_n;
  end if;

  -- -----------------------------------------------------------------
  -- 4. One document, two matters, kept apart
  -- -----------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'FN-2', app.today(), v_client, 'MYR', 1,
          300.00, 300.00, 300.00, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total, matter_id)
  values (v_org, v_doc, 1, 'Fees on the sale', 1, 100.00, 100.00, 100.00, v_m1),
         (v_org, v_doc, 2, 'Fees on the tenancy', 1, 200.00, 200.00, 200.00, v_m2),
         (v_org, v_doc, 3, 'A general attendance', 1, 0.00, 0.00, 0.00, null);
  perform public.post_sales_document(v_doc);

  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code = '4100' and matter_id = v_m1;
  if v_n <> 1 then
    raise exception 'M-1 got % revenue lines off the shared note', v_n;
  end if;
  select count(*) into v_n from pg_temp.posted_matters(v_doc)
   where code = '4100' and matter_id = v_m2;
  if v_n <> 1 then
    raise exception 'M-2 got % revenue lines off the shared note', v_n;
  end if;

  -- -----------------------------------------------------------------
  -- 4b. The matter the document knew all along
  --
  -- `0021` put `matter_id` on `sales_documents` and `bill_matter_time`
  -- has set it on every fee note raised from a matter's time entries
  -- since. Nothing carried it down to a line, so the one document in
  -- the product that ALWAYS knows its matter posted a journal that
  -- never mentioned it.
  -- -----------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status,
     matter_id)
  values (v_org, 'invoice', 'FN-3', app.today(), v_client, 'MYR', 1,
          400.00, 400.00, 400.00, 'draft', v_m1)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_doc, 1, 'Fees to date', 1, 400.00, 400.00, 400.00);
  perform public.post_sales_document(v_doc);

  select matter_id into v_got from pg_temp.posted_matters(v_doc)
   where code = '4100';
  if v_got is distinct from v_m1 then
    raise exception
      'a fee note raised on a matter posted with % on its revenue line',
      v_got;
  end if;

  -- And the line still wins where it has one, or a note covering two
  -- files would collapse onto whichever matter the header named.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status,
     matter_id)
  values (v_org, 'invoice', 'FN-4', app.today(), v_client, 'MYR', 1,
          500.00, 500.00, 500.00, 'draft', v_m1)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total, matter_id)
  values (v_org, v_doc, 1, 'Fees on the tenancy', 1, 500.00, 500.00,
          500.00, v_m2);
  perform public.post_sales_document(v_doc);

  select matter_id into v_got from pg_temp.posted_matters(v_doc)
   where code = '4100';
  if v_got is distinct from v_m2 then
    raise exception 'the header beat the line: got % rather than M-2', v_got;
  end if;

  -- -----------------------------------------------------------------
  -- 5. The report this was all for
  --
  -- 1,000 from the fee note, 100 from the shared one and 400 from the
  -- one raised on the matter itself is 1,500 on M-1's side. The
  -- tenancy's 200 and 500 and the firm's own 700 bill must not be.
  -- -----------------------------------------------------------------
  select coalesce(sum(credit - debit), 0) into v_fees
    from public.report_matter_trial_balance(
           v_org, v_m1, date '1900-01-01', date '2999-12-31')
   where code = '4100';
  if v_fees <> 1500.00 then
    raise exception 'M-1''s fees came to % rather than 1500', v_fees;
  end if;

  select coalesce(sum(debit - credit), 0) into v_fees
    from public.report_matter_trial_balance(
           v_org, v_m1, date '1900-01-01', date '2999-12-31')
   where code = '5100';
  if v_fees <> 50.00 then
    raise exception 'M-1''s disbursements came to % rather than 50', v_fees;
  end if;

  -- -----------------------------------------------------------------
  -- 6. Deleting the matter detaches a draft line and keeps the org
  --
  -- On a DRAFT. `0402` freezes every line column the journal was built
  -- from, and `matter_id` is now one of them, so a matter a POSTED
  -- invoice was billed to cannot be detached at all -- asserted just
  -- below, because it is the more surprising half.
  --
  -- What is checked here is the shape of the key: the line survives and
  -- keeps its `org_id`. A bare `on delete set null` on the composite
  -- key would try to null `org_id` too, which is NOT NULL, so the
  -- delete would raise instead of detaching.
  -- -----------------------------------------------------------------
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_org, 'M-3', 'A probate', v_client, v_owner)
  returning id into v_m3;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'FN-5', app.today(), v_client, 'MYR', 1,
          90.00, 90.00, 90.00, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total, matter_id)
  values (v_org, v_doc, 1, 'Fees', 1, 90.00, 90.00, 90.00, v_m3);

  delete from public.matters where id = v_m3;

  select count(*) into v_n from public.sales_document_lines
   where document_id = v_doc and org_id = v_org;
  if v_n <> 1 then
    raise exception 'deleting a matter took the draft line with it';
  end if;
  select count(*) into v_n from public.sales_document_lines
   where document_id = v_doc and matter_id is not null;
  if v_n <> 0 then
    raise exception 'deleting M-3 left the matter on the draft line';
  end if;

  -- And a matter a posted invoice was billed to cannot be deleted at
  -- all. Detaching it would leave the ledger saying one thing and the
  -- invoice saying nothing, with no way back to which file the fee was
  -- earned on.
  -- `insufficient_privilege`, which is the code `0402` raises: the
  -- refusal is "you may not change a posted document", and detaching
  -- the matter is a change to one.
  begin
    delete from public.matters where id = v_m1;
    v_deleted := true;
  exception
    when insufficient_privilege then
      v_deleted := false;
  end;
  if v_deleted then
    raise exception 'a matter with posted fees on it was deleted';
  end if;

  raise notice 'matter on a document: the posting paths carry it';
end $$;

-- ---------------------------------------------------------------------
-- Another firm's matter, on this firm's line
--
-- RLS scopes a row by its own `org_id` and says nothing about the ids
-- it carries. Only the composite key refuses this.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner   uuid := pg_temp.test_user();
  v_mine    uuid;
  v_theirs  uuid;
  v_c       uuid;
  v_their_m uuid;
  v_doc     uuid;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_mine   := pg_temp.test_org('Guaman Satu');
  v_theirs := pg_temp.test_org('Guaman Dua');
  perform public.setup_legal_module(v_theirs);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_theirs, 'CL9', 'Their client', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (v_theirs, 'M-9', 'Their matter', v_c, v_owner)
  returning id into v_their_m;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_mine, 'CL1', 'My client', 'customer') returning id into v_c;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_mine, 'invoice', 'FN-X', app.today(), v_c, 'MYR', 1,
          10.00, 10.00, 10.00, 'draft')
  returning id into v_doc;

  begin
    insert into public.sales_document_lines
      (org_id, document_id, line_no, description, quantity, unit_price,
       line_subtotal, line_total, matter_id)
    values (v_mine, v_doc, 1, 'Fees', 1, 10.00, 10.00, 10.00, v_their_m);
    raise exception 'another firm''s matter went onto my invoice line';
  exception
    when foreign_key_violation then null;
  end;

  raise notice 'matter on a document: a matter belongs to one firm';
end $$;

rollback;
