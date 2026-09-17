-- =====================================================================
-- iAkauntan :: the credit note nobody could knock off
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_note_allocation.sql
--
-- `0629`. `payment_allocations.credit_note_id` has existed since
-- `0005`, three migrations restated the constraint that names it, the
-- aged listing works out how much of a credit note has been used, and
-- nothing has ever written the column. Four things have to hold now
-- that something can:
--
--   * **the invoice comes down and the credit note comes down with
--     it.** A credit note that could be spent twice is a receivable
--     written off against nothing.
--   * **it cannot be spread further than it credits.** Every other
--     source on this table is guarded; this one had no guard because it
--     had no writer.
--   * **the aged listing and the document agree to the sen.** The
--     report works the figure out and `balance_amount` holds it; the
--     day they disagree, the statement that goes to the CUSTOMER is the
--     wrong one.
--   * **no journal moves.** The credit note credited the receivable
--     when it was posted. A second entry here would credit it twice.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cust(p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, contact_type, code, name)
  values (p_org, 'customer', p_code, p_name)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.doc(
  p_org uuid, p_contact uuid, p_type app.sales_doc_type, p_no text,
  p_amount numeric, p_date date, p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type, p_no, p_date, p_contact, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount, p_amount);
  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end;
$$;

create or replace function pg_temp.org_with_year(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Both sides come down, and the ledger does not move
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.org_with_year('Nota Kredit Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
  v_gl   integer;
begin
  v_cust := pg_temp.cust(v_org, 'C001', 'Pelanggan Satu Sdn Bhd');
  v_inv  := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-1', 1000,
                        date '2026-02-01');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-1', 300,
                        date '2026-02-10');

  select count(*) into v_gl from public.gl_entries where org_id = v_org;

  perform public.allocate_credit_note(v_cn, v_inv, 300);

  perform pg_temp.check_eq('the invoice comes down by the credit',
    (select balance_amount from public.sales_documents where id = v_inv),
    700::numeric);
  perform pg_temp.check_eq('and the credit note comes down with it',
    (select balance_amount from public.sales_documents where id = v_cn),
    0::numeric);
  perform pg_temp.check_eq('a fully used credit note is completed',
    (select status::text from public.sales_documents where id = v_cn),
    'completed');
  perform pg_temp.check_eq('and a part-paid invoice says so',
    (select status::text from public.sales_documents where id = v_inv),
    'partial');

  -- The assertion the whole design rests on. The credit note credited
  -- the receivable when it was posted; a journal here would credit it
  -- twice and the trial balance would stop agreeing with the ledger.
  perform pg_temp.check_eq('no journal is posted by an allocation',
    (select count(*) from public.gl_entries where org_id = v_org), v_gl);
end $$;

-- ---------------------------------------------------------------------
-- 2. The aged listing and the document agree to the sen
-- ---------------------------------------------------------------------
-- Computed from opposite directions: `report_ar_aging` works out what
-- is left on a credit note from the allocations, and `balance_amount`
-- holds it. The day they disagree, one of them goes to the customer.
do $$
declare
  v_org  uuid := pg_temp.org_with_year('Sepadan Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
begin
  v_cust := pg_temp.cust(v_org, 'C002', 'Pelanggan Dua Sdn Bhd');
  v_inv  := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-2', 1000,
                        date '2026-02-01');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-2', 400,
                        date '2026-02-10');

  -- Before: 1000 owed less a 400 credit sitting on its own.
  perform pg_temp.check_eq('the listing nets an unused credit note',
    (select round(sum(outstanding), 2) from public.report_ar_aging(v_org,
       date '2026-03-01')), 600::numeric);

  -- Part of it used.
  perform public.allocate_credit_note(v_cn, v_inv, 250);

  perform pg_temp.check_eq('and the total does not move when it is used',
    (select round(sum(outstanding), 2) from public.report_ar_aging(v_org,
       date '2026-03-01')), 600::numeric);

  -- The two figures, from opposite directions.
  perform pg_temp.check_eq(
    'what the listing says is left on the credit note',
    (select round(-outstanding, 2) from public.report_ar_aging(v_org,
       date '2026-03-01') where doc_no = 'CN-2'), 150::numeric);
  perform pg_temp.check_eq('is what the document holds',
    (select balance_amount from public.sales_documents where id = v_cn),
    150::numeric);
  perform pg_temp.check_eq('and the invoice agrees too',
    (select round(outstanding, 2) from public.report_ar_aging(v_org,
       date '2026-03-01') where doc_no = 'INV-2'), 750::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 3. It cannot be spread further than it credits
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.org_with_year('Had Kredit Sdn Bhd');
  v_cust uuid;
  v_inv1 uuid;
  v_inv2 uuid;
  v_cn   uuid;
begin
  v_cust := pg_temp.cust(v_org, 'C003', 'Pelanggan Tiga Sdn Bhd');
  v_inv1 := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-3', 1000,
                        date '2026-02-01');
  v_inv2 := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-4', 1000,
                        date '2026-02-02');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-3', 500,
                        date '2026-02-10');

  perform pg_temp.check_refused(
    'a credit note cannot settle more than it credits',
    format('select public.allocate_credit_note(%L, %L, 600)', v_cn, v_inv1),
    '%cannot settle more than it credits%', '23514');

  -- And not in two bites either, which is the way it would actually
  -- happen: 400 against one invoice and 400 against the next.
  perform public.allocate_credit_note(v_cn, v_inv1, 400);
  perform pg_temp.check_refused(
    'nor in two bites that come to more than it is for',
    format('select public.allocate_credit_note(%L, %L, 400)', v_cn, v_inv2),
    '%cannot settle more than it credits%', '23514');

  perform pg_temp.check_eq('and the first allocation stands',
    (select balance_amount from public.sales_documents where id = v_cn),
    100::numeric);

end $$;

-- The other ceiling, which was already there and must still hold when
-- the credit comes through the new door. A credit note larger than the
-- invoice is ordinary -- one credit covering three months of billing --
-- so this is not a contrived fixture.
do $$
declare
  v_org  uuid := pg_temp.org_with_year('Siling Invois Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
begin
  v_cust := pg_temp.cust(v_org, 'C008', 'Pelanggan Lapan Sdn Bhd');
  v_inv  := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-9', 1000,
                        date '2026-02-01');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-8', 2000,
                        date '2026-02-10');

  perform pg_temp.check_refused(
    'an invoice cannot be credited past what it is for',
    format('select public.allocate_credit_note(%L, %L, 1500)', v_cn, v_inv),
    '%cannot be paid more than it is for%', '23514');

  -- And exactly what it is for goes through, which is the boundary the
  -- refusal above must not have moved.
  perform public.allocate_credit_note(v_cn, v_inv, 1000);
  perform pg_temp.check_eq('and exactly what it is for clears it',
    (select balance_amount from public.sales_documents where id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('leaving the rest of the credit note to use',
    (select balance_amount from public.sales_documents where id = v_cn),
    1000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 4. What it refuses to allocate at all
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.org_with_year('Enggan Sdn Bhd');
  v_cust  uuid;
  v_other uuid;
  v_inv   uuid;
  v_cn    uuid;
  v_draft uuid;
  v_inv_o uuid;
begin
  v_cust  := pg_temp.cust(v_org, 'C004', 'Pelanggan Empat Sdn Bhd');
  v_other := pg_temp.cust(v_org, 'C005', 'Orang Lain Sdn Bhd');
  v_inv   := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-5', 1000,
                         date '2026-02-01');
  v_cn    := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-4', 300,
                         date '2026-02-10');
  v_draft := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-5', 300,
                         date '2026-02-11', false);
  v_inv_o := pg_temp.doc(v_org, v_other, 'invoice', 'INV-6', 500,
                         date '2026-02-01');

  -- A draft credits nothing, so allocating one would reduce an invoice
  -- against a document that has not reached the ledger.
  perform pg_temp.check_refused(
    'an unposted credit note allocates nothing',
    format('select public.allocate_credit_note(%L, %L, 100)', v_draft, v_inv),
    '%has not been posted%', '22023');

  -- 0465's rule, reached through the new door.
  perform pg_temp.check_refused(
    'one customer''s credit cannot settle another''s invoice',
    format('select public.allocate_credit_note(%L, %L, 100)', v_cn, v_inv_o),
    '%cannot settle another%', '23514');

  -- An invoice is not a credit note, whatever the caller says.
  perform pg_temp.check_refused(
    'an invoice cannot be used as a credit note',
    format('select public.allocate_credit_note(%L, %L, 100)', v_inv, v_inv),
    '%not a credit note%', '22023');

  perform pg_temp.check_refused(
    'and a credit note cannot be set against a credit note',
    format('select public.allocate_credit_note(%L, %L, 100)', v_cn, v_cn),
    '%set against an invoice or a debit note%', '22023');

  -- Refused twice over: the function says so in words, and
  -- `payment_allocations_amount_check` refuses it in the database
  -- whatever the caller is. Asserting the FUNCTION's wording is what
  -- makes the guard visible -- take the function's line out and this
  -- fails on "refused, but for the wrong reason", which is the
  -- constraint answering instead.
  perform pg_temp.check_refused(
    'an allocation is of something',
    format('select public.allocate_credit_note(%L, %L, 0)', v_cn, v_inv),
    '%allocation is of something%', '23514');
end $$;

-- ---------------------------------------------------------------------
-- 4b. A settlement discount on the allocation is not the credit note's
-- ---------------------------------------------------------------------
-- `allocate_credit_note` never writes one, but `payment_allocations`
-- allows a discount on any row whose `discount_entry_id` is set --
-- `app.allocation_discount_guard` refuses only the unposted kind -- so
-- the question is answerable and has to be answered the same way it is
-- for a receipt: the CASH is what came off the source, and the discount
-- came off the ledger. Counting it here would retire more of the credit
-- note than the credit note supplied, and the customer would be told a
-- credit they still hold is spent.
do $$
declare
  v_org  uuid := pg_temp.org_with_year('Diskaun Penyelesaian Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
  v_gl   uuid;
begin
  v_cust := pg_temp.cust(v_org, 'C009', 'Pelanggan Sembilan Sdn Bhd');
  v_inv  := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-10', 1000,
                        date '2026-02-01');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-9', 300,
                        date '2026-02-10');

  -- Any posted entry of this company will do: what is asserted is the
  -- arithmetic, not which entry it points at.
  select gl_entry_id into v_gl from public.sales_documents where id = v_cn;

  insert into public.payment_allocations
    (org_id, credit_note_id, invoice_id, amount, discount_amount,
     discount_entry_id)
  values (v_org, v_cn, v_inv, 200, 50, v_gl);

  perform pg_temp.check_eq(
    'the invoice comes down by the cash and the discount together',
    (select balance_amount from public.sales_documents where id = v_inv),
    750::numeric);
  perform pg_temp.check_eq(
    'but the credit note comes down by the cash alone',
    (select balance_amount from public.sales_documents where id = v_cn),
    100::numeric);
end $$;

-- ---------------------------------------------------------------------
-- 5. Somebody who may not post cannot knock one off
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.org_with_year('Kuasa Sdn Bhd');
  v_cust   uuid;
  v_inv    uuid;
  v_cn     uuid;
  v_clerk  uuid := pg_temp.another_user('sales@iakauntan.test');
begin
  v_cust := pg_temp.cust(v_org, 'C006', 'Pelanggan Enam Sdn Bhd');
  v_inv  := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-7', 1000,
                        date '2026-02-01');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-6', 300,
                        date '2026-02-10');

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'viewer');
  perform pg_temp.sign_in_as(v_clerk);

  perform pg_temp.check_refused(
    'somebody who may only read cannot knock off a credit note',
    format('select public.allocate_credit_note(%L, %L, 100)', v_cn, v_inv),
    '%not permitted%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- 6. Undoing it puts both sides back
-- ---------------------------------------------------------------------
-- A knock-off screen has to be able to unpick a mistake, and the
-- trigger's own comment says a delete must be allowed to put an
-- over-allocated set of books right.
do $$
declare
  v_org  uuid := pg_temp.org_with_year('Buka Semula Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
  v_all  uuid;
begin
  v_cust := pg_temp.cust(v_org, 'C007', 'Pelanggan Tujuh Sdn Bhd');
  v_inv  := pg_temp.doc(v_org, v_cust, 'invoice', 'INV-8', 1000,
                        date '2026-02-01');
  v_cn   := pg_temp.doc(v_org, v_cust, 'credit_note', 'CN-7', 300,
                        date '2026-02-10');

  v_all := public.allocate_credit_note(v_cn, v_inv, 300);
  delete from public.payment_allocations where id = v_all;

  perform pg_temp.check_eq('the invoice goes back up',
    (select balance_amount from public.sales_documents where id = v_inv),
    1000::numeric);
  perform pg_temp.check_eq('and the credit note is whole again',
    (select balance_amount from public.sales_documents where id = v_cn),
    300::numeric);
  perform pg_temp.check_eq('and neither is left looking part paid',
    (select count(*) from public.sales_documents
      where id in (v_inv, v_cn) and status::text <> 'posted'), 0);
end $$;

rollback;
