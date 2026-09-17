-- =====================================================================
-- iAkauntan :: the bill that arrived twice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/duplicate_bills.sql
--
-- `0628`. Paying a supplier's invoice twice is the most expensive
-- routine mistake in accounts payable. Four things have to hold:
--
--   * **the same supplier's number twice is a duplicate.** This is the
--     pair `0406` never considered: it swept COLUMNS for missing unique
--     indexes and left `supplier_doc_no` alone because two SUPPLIERS may
--     both send an `INV-1`. True, and a different question.
--   * **punctuation is not an invoice number.** `INV-4471`, `inv 4471`
--     and `INV4471` are one invoice typed by three people. A check that
--     called them three is a check that never fires.
--   * **a different supplier's identical number is not a duplicate.**
--     The false positive that would make somebody turn this off.
--   * **a void is withdrawn.** Entering a bill, voiding it and entering
--     it again is how a mistake is corrected, and warning about the
--     mistake somebody has just fixed is worse than silence.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.supplier(
  p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, contact_type, code, name)
  values (p_org, 'supplier', p_code, p_name)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.a_bill(
  p_org uuid, p_contact uuid, p_no text, p_supplier_no text,
  p_amount numeric, p_date date, p_status app.doc_status default 'posted',
  p_type app.purchase_doc_type default 'bill')
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, supplier_doc_no,
     currency, exchange_rate, subtotal, total_amount, balance_amount,
     status)
  values (p_org, p_type, p_no, p_date, p_contact, p_supplier_no, 'MYR', 1,
          p_amount, p_amount, p_amount, p_status)
  returning id into v_doc;
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. The same supplier's number twice, however it was typed
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Bil Berganda Sdn Bhd');
  v_sup  uuid;
  v_othr uuid;
begin
  v_sup  := pg_temp.supplier(v_org, 'S001', 'Pembekal Satu Sdn Bhd');
  v_othr := pg_temp.supplier(v_org, 'S002', 'Pembekal Dua Sdn Bhd');

  perform pg_temp.a_bill(v_org, v_sup, 'BILL-1', 'INV-4471', 1200,
                         date '2026-05-01');

  perform pg_temp.check_eq('the same number from the same supplier is found',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-4471')), 1);
  perform pg_temp.check_eq('and it says why',
    (select reason from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-4471')), 'same number');

  -- The three spellings of one number.
  perform pg_temp.check_eq('punctuation is not part of the number',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'inv 4471')), 1);
  perform pg_temp.check_eq('and neither is the case or the dash',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'inv4471')), 1);

  -- The false positive that would make somebody turn this off.
  perform pg_temp.check_eq(
    'another supplier sending the same number is not a duplicate',
    (select count(*) from public.duplicate_purchase_documents(
       v_othr, 'bill', 'INV-4471')), 0);

  -- And a document of another KIND carrying the same number is not one
  -- either. A supplier's credit note against invoice 4471 is routinely
  -- numbered after it, and a check that called that a duplicate bill
  -- would fire on the correction rather than on the mistake.
  perform pg_temp.a_bill(v_org, v_sup, 'PO-1', 'INV-4471', 1200,
                         date '2026-05-01', 'posted', 'purchase_order');
  perform pg_temp.check_eq(
    'a purchase order carrying the same number is not a duplicate bill',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-4471')), 1);
  perform pg_temp.check_eq('though it is a duplicate of its own kind',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'purchase_order', 'INV-4471')), 1);

  perform pg_temp.check_eq('and a number nobody has sent is not either',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-9999')), 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. A void is withdrawn, and so is the document being edited
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Dibatalkan Sdn Bhd');
  v_sup uuid;
  v_one uuid;
begin
  v_sup := pg_temp.supplier(v_org, 'S003', 'Pembekal Tiga Sdn Bhd');
  perform pg_temp.a_bill(v_org, v_sup, 'BILL-V', 'INV-5000', 800,
                         date '2026-05-02', 'void');

  perform pg_temp.check_eq(
    'a voided bill is not something the next one duplicates',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-5000')), 0);

  -- And the document doing the asking is never its own duplicate,
  -- which is what the editor needs: it asks about a bill that is
  -- already saved.
  v_one := pg_temp.a_bill(v_org, v_sup, 'BILL-2', 'INV-5001', 800,
                          date '2026-05-03');
  perform pg_temp.check_eq('a saved bill is not its own duplicate',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-5001', null, null, v_one)), 0);
  perform pg_temp.check_eq('but it is somebody else''s',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', 'INV-5001')), 1);
end $$;

-- ---------------------------------------------------------------------
-- 3. The document with no number on it
-- ---------------------------------------------------------------------
-- Most till receipts, and a good share of what the scanner reads.
do $$
declare
  v_org uuid := pg_temp.test_org('Resit Tanpa Nombor Sdn Bhd');
  v_sup uuid;
begin
  v_sup := pg_temp.supplier(v_org, 'S004', 'Kedai Runcit Sdn Bhd');
  perform pg_temp.a_bill(v_org, v_sup, 'BILL-3', null, 45.90,
                         date '2026-05-04');

  perform pg_temp.check_eq('the same amount on the same day is found',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', null, date '2026-05-04', 45.90)), 1);
  perform pg_temp.check_eq('and is reported as the weaker reason it is',
    (select reason from public.duplicate_purchase_documents(
       v_sup, 'bill', null, date '2026-05-04', 45.90)),
    'same amount on the same day');

  perform pg_temp.check_eq('a different day is not a duplicate',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', null, date '2026-05-05', 45.90)), 0);
  perform pg_temp.check_eq('nor a different amount',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', null, date '2026-05-04', 45.91)), 0);

  -- Nothing to go on is not a match against everything, which is the
  -- mutant that would make this warn on every bill ever entered.
  perform pg_temp.check_eq('a question with nothing in it finds nothing',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill')), 0);

  -- A zero total is nothing to go on either, and there has to be a
  -- zero-total document on the books for that to be a real question:
  -- without one the assertion below passes whether the guard is there
  -- or not, and the mutation sweep said exactly that. A nil bill is an
  -- ordinary thing -- a warranty replacement, a sample.
  perform pg_temp.a_bill(v_org, v_sup, 'BILL-NIL', null, 0,
                         date '2026-05-04');
  perform pg_temp.check_eq('and neither does a zero total',
    (select count(*) from public.duplicate_purchase_documents(
       v_sup, 'bill', null, date '2026-05-04', 0)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. A supplier filed twice is one supplier
-- ---------------------------------------------------------------------
-- `0477` links a company's records through `party_id`. A duplicate
-- check that missed the duplicate because the SUPPLIER was duplicated
-- would be the joke version of this.
do $$
declare
  v_org   uuid := pg_temp.test_org('Satu Syarikat Sdn Bhd');
  v_a     uuid;
  v_b     uuid;
  v_party uuid := gen_random_uuid();
begin
  v_a := pg_temp.supplier(v_org, 'S005', 'Pembekal Lima Sdn Bhd');
  v_b := pg_temp.supplier(v_org, 'S006', 'PEMBEKAL LIMA SDN BHD');
  update public.contacts set party_id = v_party where id in (v_a, v_b);

  perform pg_temp.a_bill(v_org, v_a, 'BILL-4', 'INV-6000', 300,
                         date '2026-05-06');

  perform pg_temp.check_eq(
    'the same company filed twice still catches its own duplicate',
    (select count(*) from public.duplicate_purchase_documents(
       v_b, 'bill', 'INV-6000')), 1);
end $$;

-- ---------------------------------------------------------------------
-- 5. One company's bills are not another's
-- ---------------------------------------------------------------------
do $$
declare
  v_a   uuid;
  v_b   uuid;
  v_sa  uuid;
  v_sb  uuid;
begin
  perform pg_temp.test_org('Sempadan Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.test_org('Syarikat Bil A Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_b := pg_temp.test_org('Syarikat Bil B Sdn Bhd');

  v_sa := pg_temp.supplier(v_a, 'S007', 'Pembekal Kongsi Sdn Bhd');
  v_sb := pg_temp.supplier(v_b, 'S007', 'Pembekal Kongsi Sdn Bhd');

  perform pg_temp.a_bill(v_a, v_sa, 'BILL-5', 'INV-7000', 900,
                         date '2026-05-07');

  perform pg_temp.check_eq('A finds its own',
    (select count(*) from public.duplicate_purchase_documents(
       v_sa, 'bill', 'INV-7000')), 1);
  perform pg_temp.check_eq('and B finds nothing of A''s',
    (select count(*) from public.duplicate_purchase_documents(
       v_sb, 'bill', 'INV-7000')), 0);

  -- An EQUIVALENT MUTANT lives here and is worth writing down rather
  -- than chasing. Deleting `d.org_id = me.org_id` from the function
  -- changes nothing that can be observed: the contact subquery below it
  -- is already scoped to `c2.org_id = me.org_id`, and
  -- `purchase_documents_contact_same_org` makes a document whose
  -- contact is in this company a document in this company. The clause
  -- stays because it is what the query plan uses, not because it is
  -- what makes this assertion pass -- and the assertion above still
  -- holds if somebody weakens the contact scope instead, which is the
  -- change that WOULD leak.
end $$;

-- ---------------------------------------------------------------------
-- 6. It warns; it refuses nothing
-- ---------------------------------------------------------------------
-- The line `0625` drew, asserted the same way: out of the catalogue
-- rather than by grepping the prose. A duplicate check that REFUSED
-- would refuse a supplier's corrected re-issue, and the workaround
-- people find for a constraint that is wrong a tenth of the time is to
-- type the number differently -- which destroys the only field this
-- runs on.
do $$
declare
  v_org uuid := pg_temp.test_org('Amaran Sahaja Sdn Bhd');
  v_sup uuid;
begin
  v_sup := pg_temp.supplier(v_org, 'S008', 'Pembekal Lapan Sdn Bhd');
  perform pg_temp.a_bill(v_org, v_sup, 'BILL-6', 'INV-8000', 100,
                         date '2026-05-08');

  -- The parentheses are load-bearing: `and` binds tighter than `or`, so
  -- the obvious spelling of this counts the public function whatever
  -- its volatility and asserts nothing about it.
  perform pg_temp.check_eq('nothing in 0628 can write',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where ((n.nspname = 'public'
              and p.proname = 'duplicate_purchase_documents')
             or (n.nspname = 'app' and p.proname = 'supplier_doc_key'))
        and p.provolatile = 'v'), 0);

  -- And that both of them are actually there, because a count of zero
  -- volatile functions is also what you get when neither exists.
  perform pg_temp.check_eq('and both of them exist to be checked',
    (select count(*) from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where (n.nspname = 'public'
             and p.proname = 'duplicate_purchase_documents')
         or (n.nspname = 'app' and p.proname = 'supplier_doc_key')), 2);

  -- And the second bill goes in. This is the assertion that says the
  -- feature is a warning: if anything here refused, this would raise.
  perform pg_temp.a_bill(v_org, v_sup, 'BILL-7', 'INV-8000', 100,
                         date '2026-05-08');
  perform pg_temp.check_eq('the duplicate is still allowed to be entered',
    (select count(*) from public.purchase_documents
      where org_id = v_org and supplier_doc_no = 'INV-8000'), 2);
end $$;

rollback;
