-- =====================================================================
-- iAkauntan :: both sides of one account
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/knock_off.sql
--
-- `0630`. The question a knock-off screen asks -- what does this
-- customer owe, and what have they got in hand -- and the action that
-- answers it. Four things have to hold:
--
--   * **both sides, and only what is left of each.** An invoice that is
--     settled is not owed and a credit note that is spent is not in
--     hand.
--   * **all or nothing.** A clerk matching six credits against nine
--     invoices is making ONE decision. A loop that fails on the seventh
--     leaves a set of books in a state nobody chose.
--   * **only the kinds that need no journal.** A deposit posts
--     something when it is applied. It is SHOWN, because a clerk
--     looking at what a customer has in hand needs to see all of it,
--     and it is not allocatable here.
--   * **one party, one account.** A customer filed twice is one
--     account, and a credit cannot cross to somebody else's invoice.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.k_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.k_cust(p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, contact_type, code, name)
  values (p_org, 'customer', p_code, p_name)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.k_doc(
  p_org uuid, p_contact uuid, p_type app.sales_doc_type, p_no text,
  p_amount numeric, p_date date)
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
  values (p_org, v_doc, 1, 'Work', 1, p_amount, p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

create or replace function pg_temp.k_receipt(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount,
     unapplied_amount, currency, exchange_rate)
  values (p_org, p_no, p_date, p_contact, p_amount, p_amount, 'MYR', 1)
  returning id into v_id;
  perform public.post_receipt(v_id);
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. Both sides, and only what is left of each
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.k_org('Dua Belah Sdn Bhd');
  v_cust uuid;
  v_inv1 uuid;
  v_inv2 uuid;
  v_cn   uuid;
  v_rcp  uuid;
begin
  v_cust := pg_temp.k_cust(v_org, 'K001', 'Pelanggan Kira Sdn Bhd');
  v_inv1 := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-1', 1000,
                          date '2026-02-01');
  v_inv2 := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-2', 500,
                          date '2026-02-05');
  v_cn   := pg_temp.k_doc(v_org, v_cust, 'credit_note', 'KC-1', 300,
                          date '2026-02-10');
  v_rcp  := pg_temp.k_receipt(v_org, v_cust, 'KR-1', 200,
                              date '2026-02-12');

  perform pg_temp.check_eq('two invoices are owed',
    (select count(*) from public.open_items(v_cust) where side = 'owes'), 2);
  perform pg_temp.check_eq('and two credits are in hand',
    (select count(*) from public.open_items(v_cust) where side = 'credit'), 2);
  perform pg_temp.check_eq('what is owed altogether',
    (select round(sum(remaining), 2) from public.open_items(v_cust)
      where side = 'owes'), 1500::numeric);
  perform pg_temp.check_eq('and what is in hand',
    (select round(sum(remaining), 2) from public.open_items(v_cust)
      where side = 'credit'), 500::numeric);

  -- Now spend some of both.
  perform public.allocate_credit_note(v_cn, v_inv1, 300);
  perform public.allocate_with_discount(v_rcp, v_inv1, 200, 0);

  perform pg_temp.check_eq('a spent credit note leaves the list',
    (select count(*) from public.open_items(v_cust)
      where item_id = v_cn), 0);
  perform pg_temp.check_eq('and a fully applied receipt goes with it',
    (select count(*) from public.open_items(v_cust)
      where item_id = v_rcp), 0);
  perform pg_temp.check_eq('the invoice shows only what is left',
    (select remaining from public.open_items(v_cust)
      where item_id = v_inv1), 500::numeric);
  perform pg_temp.check_eq('and the untouched one is unchanged',
    (select remaining from public.open_items(v_cust)
      where item_id = v_inv2), 500::numeric);
end $$;

-- A settled invoice is not owed, and a draft is not either: the first
-- because it is paid and the second because it has not reached the
-- ledger.
do $$
declare
  v_org  uuid := pg_temp.k_org('Tiada Baki Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_dft  uuid;
begin
  v_cust := pg_temp.k_cust(v_org, 'K002', 'Pelanggan Lunas Sdn Bhd');
  v_inv  := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-3', 400,
                          date '2026-02-01');
  perform public.allocate_with_discount(
    pg_temp.k_receipt(v_org, v_cust, 'KR-2', 400, date '2026-02-02'),
    v_inv, 400, 0);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'KI-4', date '2026-02-03', v_cust, 'MYR', 1,
          900, 900, 900, 'draft')
  returning id into v_dft;

  perform pg_temp.check_eq('a settled invoice is not owed',
    (select count(*) from public.open_items(v_cust)
      where item_id = v_inv), 0);
  perform pg_temp.check_eq('and a draft has not reached the ledger',
    (select count(*) from public.open_items(v_cust)
      where item_id = v_dft), 0);
  perform pg_temp.check_eq('so the account is clear',
    (select count(*) from public.open_items(v_cust)), 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. A deposit is shown and is not allocatable here
-- ---------------------------------------------------------------------
-- Applying one POSTS something, and `deposit_apply_sheet.dart` is where
-- that decision is made. Left off the list entirely, a clerk would
-- knock off what they could see and believe the account was clear.
do $$
declare
  v_org  uuid := pg_temp.k_org('Wang Pendahuluan Sdn Bhd');
  v_cust uuid;
  v_dep  uuid;
  v_inv  uuid;
begin
  v_cust := pg_temp.k_cust(v_org, 'K003', 'Pelanggan Deposit Sdn Bhd');
  v_inv  := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-5', 1000,
                          date '2026-02-01');

  insert into public.deposit_notes
    (org_id, deposit_no, deposit_date, kind, contact_id, currency,
     exchange_rate, amount, balance_amount)
  values (v_org, 'DEP-1', date '2026-02-02', 'customer', v_cust, 'MYR', 1,
          700, 700)
  returning id into v_dep;

  perform pg_temp.check_eq('the deposit is on the list',
    (select count(*) from public.open_items(v_cust)
      where item_id = v_dep), 1);
  perform pg_temp.check_true('and is marked as not settled here',
    (select not allocatable from public.open_items(v_cust)
      where item_id = v_dep));
  perform pg_temp.check_true('while the invoice is',
    (select allocatable from public.open_items(v_cust)
      where item_id = v_inv));

  perform pg_temp.check_refused(
    'and knocking one off here is refused in words',
    format('select public.knock_off(%L, %L::jsonb)', v_cust,
      json_build_array(json_build_object(
        'kind', 'deposit', 'source_id', v_dep,
        'invoice_id', v_inv, 'amount', 100))::text),
    '%applied from its own screen%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- 3. All or nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.k_org('Semua Atau Tiada Sdn Bhd');
  v_cust uuid;
  v_inv1 uuid;
  v_inv2 uuid;
  v_cn   uuid;
  v_rcp  uuid;
begin
  v_cust := pg_temp.k_cust(v_org, 'K004', 'Pelanggan Kumpul Sdn Bhd');
  v_inv1 := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-6', 1000,
                          date '2026-02-01');
  v_inv2 := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-7', 1000,
                          date '2026-02-02');
  v_cn   := pg_temp.k_doc(v_org, v_cust, 'credit_note', 'KC-2', 300,
                          date '2026-02-10');
  v_rcp  := pg_temp.k_receipt(v_org, v_cust, 'KR-3', 400,
                              date '2026-02-12');

  perform pg_temp.check_eq('four lines go in as one',
    public.knock_off(v_cust, json_build_array(
      json_build_object('kind', 'credit_note', 'source_id', v_cn,
                        'invoice_id', v_inv1, 'amount', 200),
      json_build_object('kind', 'credit_note', 'source_id', v_cn,
                        'invoice_id', v_inv2, 'amount', 100),
      json_build_object('kind', 'receipt', 'source_id', v_rcp,
                        'invoice_id', v_inv1, 'amount', 250),
      json_build_object('kind', 'receipt', 'source_id', v_rcp,
                        'invoice_id', v_inv2, 'amount', 150))::jsonb), 4);

  perform pg_temp.check_eq('the first invoice took both',
    (select balance_amount from public.sales_documents where id = v_inv1),
    550::numeric);
  perform pg_temp.check_eq('and so did the second',
    (select balance_amount from public.sales_documents where id = v_inv2),
    750::numeric);
  perform pg_temp.check_eq('the credit note is spent',
    (select balance_amount from public.sales_documents where id = v_cn),
    0::numeric);
  perform pg_temp.check_eq('and the receipt is applied',
    (select unapplied_amount from public.receipts where id = v_rcp),
    0::numeric);
end $$;

-- And the half that matters: a batch whose LAST line is impossible
-- leaves the first lines undone.
do $$
declare
  v_org  uuid := pg_temp.k_org('Gagal Separuh Sdn Bhd');
  v_cust uuid;
  v_inv  uuid;
  v_cn   uuid;
begin
  v_cust := pg_temp.k_cust(v_org, 'K005', 'Pelanggan Separuh Sdn Bhd');
  v_inv  := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-8', 1000,
                          date '2026-02-01');
  v_cn   := pg_temp.k_doc(v_org, v_cust, 'credit_note', 'KC-3', 300,
                          date '2026-02-10');

  perform pg_temp.check_refused(
    'a batch that cannot finish does nothing at all',
    format('select public.knock_off(%L, %L::jsonb)', v_cust,
      json_build_array(
        json_build_object('kind', 'credit_note', 'source_id', v_cn,
                          'invoice_id', v_inv, 'amount', 100),
        json_build_object('kind', 'credit_note', 'source_id', v_cn,
                          'invoice_id', v_inv, 'amount', 900))::text),
    '%cannot settle more than it credits%', '23514');

  -- The assertion the "all or nothing" claim rests on. Without the
  -- rollback the first 100 would have landed.
  perform pg_temp.check_eq('the first line did not land',
    (select balance_amount from public.sales_documents where id = v_inv),
    1000::numeric);
  perform pg_temp.check_eq('and the credit note is untouched',
    (select balance_amount from public.sales_documents where id = v_cn),
    300::numeric);
  perform pg_temp.check_eq('and nothing was recorded',
    (select count(*) from public.payment_allocations
      where credit_note_id = v_cn), 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. An empty batch, and somebody who may not post
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.k_org('Kosong Sdn Bhd');
  v_cust  uuid;
  v_inv   uuid;
  v_cn    uuid;
  v_clerk uuid := pg_temp.another_user('clerk@iakauntan.test');
begin
  v_cust := pg_temp.k_cust(v_org, 'K006', 'Pelanggan Kosong Sdn Bhd');
  v_inv  := pg_temp.k_doc(v_org, v_cust, 'invoice', 'KI-9', 1000,
                          date '2026-02-01');
  v_cn   := pg_temp.k_doc(v_org, v_cust, 'credit_note', 'KC-4', 300,
                          date '2026-02-10');

  perform pg_temp.check_refused(
    'an empty batch is not a batch',
    format('select public.knock_off(%L, %L::jsonb)', v_cust, '[]'),
    '%Nothing to set against anything%', '23514');

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'viewer');
  perform pg_temp.sign_in_as(v_clerk);

  -- The OUTER function's wording, not just "not permitted". Both
  -- layers refuse this -- `knock_off` at the top and
  -- `allocate_credit_note` on every line -- so an assertion matching
  -- either one passes with the outer guard deleted, and the mutation
  -- sweep said exactly that. Matching the outer wording is what makes
  -- the outer guard testable; the inner one has its own file.
  perform pg_temp.check_refused(
    'somebody who may only read cannot knock off',
    format('select public.knock_off(%L, %L::jsonb)', v_cust,
      json_build_array(json_build_object(
        'kind', 'credit_note', 'source_id', v_cn,
        'invoice_id', v_inv, 'amount', 100))::text),
    '%not permitted to knock off%', '42501');

  -- And cannot see the account either way round.
  perform pg_temp.check_eq('but may still read the account',
    (select count(*) from public.open_items(v_cust)), 2);
end $$;

-- ---------------------------------------------------------------------
-- 5. One party, one account; and one company's, not another's
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.k_org('Satu Pihak Sdn Bhd');
  v_a     uuid;
  v_b     uuid;
  v_party uuid := gen_random_uuid();
  v_inv   uuid;
begin
  v_a := pg_temp.k_cust(v_org, 'K007', 'Kumpulan Satu Sdn Bhd');
  v_b := pg_temp.k_cust(v_org, 'K008', 'KUMPULAN SATU SDN BHD');
  update public.contacts set party_id = v_party where id in (v_a, v_b);

  v_inv := pg_temp.k_doc(v_org, v_a, 'invoice', 'KI-10', 600,
                         date '2026-02-01');
  perform pg_temp.k_doc(v_org, v_b, 'credit_note', 'KC-5', 200,
                        date '2026-02-10');

  -- Asked from either record, the account is the same account.
  perform pg_temp.check_eq('the same company filed twice is one account',
    (select count(*) from public.open_items(v_a)), 2);
  perform pg_temp.check_eq('whichever record is asked',
    (select count(*) from public.open_items(v_b)), 2);
end $$;

do $$
declare
  v_a   uuid;
  v_b   uuid;
  v_ca  uuid;
  v_cb  uuid;
begin
  perform pg_temp.k_org('Sempadan Kira Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.k_org('Kira A Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_b := pg_temp.k_org('Kira B Sdn Bhd');

  v_ca := pg_temp.k_cust(v_a, 'K009', 'Pelanggan Kongsi Sdn Bhd');
  v_cb := pg_temp.k_cust(v_b, 'K009', 'Pelanggan Kongsi Sdn Bhd');
  perform pg_temp.k_doc(v_a, v_ca, 'invoice', 'KI-11', 800,
                        date '2026-02-01');

  perform pg_temp.check_eq('A sees its own',
    (select count(*) from public.open_items(v_ca)), 1);
  perform pg_temp.check_eq('and B sees none of it',
    (select count(*) from public.open_items(v_cb)), 0);

  -- An EQUIVALENT MUTANT lives here, the same one `duplicate_bills.sql`
  -- records. Deleting `d.org_id = me.org_id` from the `owes` arm
  -- changes nothing observable: the `family` CTE is already scoped to
  -- `c2.org_id = me.org_id`, and `sales_documents_contact_same_org`
  -- makes a document whose contact is in this company a document in
  -- this company. The clause stays because it is what the plan uses,
  -- and the assertion above still fails if somebody weakens the
  -- CONTACT scope instead, which is the change that would actually
  -- leak.
end $$;

rollback;
