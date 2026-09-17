-- =====================================================================
-- iAkauntan :: the supplier's own number
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/import_purchase_transactions.sql
--
-- `0632`. The purchase side of `0631`, and it is not a mirror image: a
-- bill carries TWO numbers -- ours and the supplier's -- and the
-- duplicate question is asked of theirs.
--
-- What is asserted here is what differs from the sales side. The rules
-- `0631` already proves -- grouping, drafts, all-or-nothing, the
-- totals coming from the triggers -- are asserted once there and
-- spot-checked here rather than restated in full.
--
--   * **a bill this supplier has already sent is refused**, using
--     `0628`'s matcher rather than a second one, because two answers to
--     "have we had this before" is how a company pays twice.
--   * **and it is a REFUSAL here where 0628 warns.** A person entering
--     one bill can judge the match; a file of four hundred rows has
--     nobody looking at any one of them.
--   * **two supplier numbers under one of ours is a disagreement.** The
--     sales side has no equivalent, and it means two bills were run
--     together.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.p_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.contacts (org_id, contact_type, code, name)
  values (v_org, 'supplier', 'SUPP1', 'Pembekal Import Sdn Bhd'),
         (v_org, 'supplier', 'SUPP2', 'Pembekal Lain Sdn Bhd');
  return v_org;
end;
$$;

create or replace function pg_temp.p_line(
  p_no text, p_contact text, p_date text, p_desc text,
  p_qty text, p_price text, p_supplier_no text default null,
  p_type text default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'doc_no', p_no, 'contact_code', p_contact, 'doc_date', p_date,
    'description', p_desc, 'quantity', p_qty, 'unit_price', p_price,
    'supplier_doc_no', p_supplier_no, 'doc_type', p_type));
$$;

-- ---------------------------------------------------------------------
-- 1. A good file, with both numbers kept
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.p_org('Import Belian Sdn Bhd');
  v_out jsonb;
begin
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-1', 'SUPP1', '2026-01-05', 'Stationery', '10',
                   '12.50', 'ST-4471'),
    pg_temp.p_line('BILL-1', 'SUPP1', '2026-01-05', 'Delivery', '1',
                   '25', 'ST-4471'),
    pg_temp.p_line('BILL-2', 'SUPP2', '2026-01-06', 'Rent', '1', '3000',
                   'INV-900')
  ), true);

  perform pg_temp.check_eq('two documents came out of three rows',
    (v_out ->> 'documents')::integer, 2);
  perform pg_temp.check_eq('the first has both its lines',
    (select count(*) from public.purchase_document_lines l
       join public.purchase_documents d on d.id = l.document_id
      where d.org_id = v_org and d.doc_no = 'BILL-1'), 2);
  perform pg_temp.check_eq('and adds up to what its lines come to',
    (select total_amount from public.purchase_documents
      where org_id = v_org and doc_no = 'BILL-1'), 150::numeric);

  -- The column the sales side has no equivalent of, and the one 0628
  -- reads. Lost here, the duplicate check below has nothing to work on.
  perform pg_temp.check_eq('the supplier''s own number is kept',
    (select supplier_doc_no from public.purchase_documents
      where org_id = v_org and doc_no = 'BILL-1'), 'ST-4471');

  -- No `doc_type` column in the file, which is the commonest case:
  -- most files are all bills. The validator defaults to `bill` and the
  -- insert must default to the same thing, or a file validates as one
  -- kind and lands as another.
  perform pg_temp.check_eq('a row that does not say what it is, is a bill',
    (select count(*) from public.purchase_documents
      where org_id = v_org and doc_type::text <> 'bill'), 0);

  perform pg_temp.check_eq('everything arrives as a draft',
    (select count(*) from public.purchase_documents
      where org_id = v_org and status <> 'draft'), 0);
  perform pg_temp.check_eq('and nothing is posted to the ledger',
    (select count(*) from public.purchase_documents
      where org_id = v_org and gl_entry_id is not null), 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. A bill this supplier has already sent
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.p_org('Bil Berulang Sdn Bhd');
  v_out jsonb;
  v_msg text;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, supplier_doc_no,
     currency, exchange_rate, subtotal, total_amount, balance_amount,
     status)
  values (v_org, 'bill', 'BILL-OLD', date '2026-01-02',
          (select id from public.contacts
            where org_id = v_org and code = 'SUPP1'),
          'ST-5000', 'MYR', 1, 500, 500, 500, 'posted');

  -- A different number of OURS, the same number of THEIRS. This is the
  -- duplicate that matters and the one a file would slip through.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-NEW', 'SUPP1', '2026-01-20', 'Same again', '1',
                   '500', 'ST-5000')
  ), false);

  v_msg := (select x ->> 'problem'
              from jsonb_array_elements(v_out -> 'rows') x);
  perform pg_temp.check_true('the supplier''s number is recognised',
    v_msg like 'BILL-OLD already has ST-5000 from this supplier%');
  perform pg_temp.check_true('and it says on what grounds',
    v_msg like '%(same number)%');
  perform pg_temp.check_true('and what to do about it',
    v_msg like '%Take it out of the file%');

  -- 0628 normalises the number, and the import must get the same
  -- answer: INV-4471, inv 4471 and INV4471 are one invoice typed by
  -- three people.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-NEW', 'SUPP1', '2026-01-20', 'Same again', '1',
                   '500', 'st 5000')
  ), false);
  perform pg_temp.check_eq('however it was typed',
    (v_out ->> 'errors')::integer, 1);

  -- The false positive that would make somebody turn this off.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-NEW', 'SUPP2', '2026-01-20', 'Different firm',
                   '1', '500', 'ST-5000')
  ), false);
  perform pg_temp.check_eq(
    'but another supplier sending the same number is not a duplicate',
    (v_out ->> 'errors')::integer, 0);

  perform pg_temp.check_refused(
    'and a file carrying one is refused rather than warned about',
    format('select public.import_purchase_transactions(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.p_line('BILL-NEW', 'SUPP1', '2026-01-20', 'Same', '1',
                            '500', 'ST-5000'))::text),
    '%Nothing was imported%', '22023');
end $$;

-- ---------------------------------------------------------------------
-- 3. Two supplier numbers under one of ours
-- ---------------------------------------------------------------------
-- The sales side has no equivalent. It means two bills were run
-- together, and importing them as one is a payable for the wrong money
-- addressed to a number the supplier will not recognise.
do $$
declare
  v_org uuid := pg_temp.p_org('Dua Nombor Sdn Bhd');
  v_out jsonb;
begin
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-3', 'SUPP1', '2026-01-05', 'One', '1', '100',
                   'ST-1'),
    pg_temp.p_line('BILL-3', 'SUPP1', '2026-01-05', 'Two', '1', '100',
                   'ST-2')
  ), false);

  perform pg_temp.check_true('a second supplier number is caught',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2)
      like 'Row 1 gives BILL-3 the supplier''s number st-1 and this row gives it ST-2.');

  -- A number on one line and none on the next is the same mistake, and
  -- says so rather than showing an empty pair of quotes.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-4', 'SUPP1', '2026-01-05', 'One', '1', '100',
                   'ST-3'),
    pg_temp.p_line('BILL-4', 'SUPP1', '2026-01-05', 'Two', '1', '100')
  ), false);
  perform pg_temp.check_true('and a missing one reads as (none)',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) like '%gives it (none).');

  -- And a group that agrees is no problem, which stops the two above
  -- passing for the wrong reason.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-5', 'SUPP1', '2026-01-05', 'One', '1', '100',
                   'ST-4'),
    pg_temp.p_line('BILL-5', 'SUPP1', '2026-01-05', 'Two', '1', '100',
                   'ST-4')
  ), false);
  perform pg_temp.check_eq('a group that agrees passes',
    (v_out ->> 'errors')::integer, 0);

  -- A bill with NO supplier number at all is ordinary -- a subscription
  -- receipt, a toll -- and must not be treated as a disagreement with
  -- itself.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-6', 'SUPP1', '2026-01-05', 'One', '1', '100'),
    pg_temp.p_line('BILL-6', 'SUPP1', '2026-01-05', 'Two', '1', '100')
  ), false);
  perform pg_temp.check_eq('and so does one with no supplier number',
    (v_out ->> 'errors')::integer, 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. The kinds this side takes
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.p_org('Jenis Belian Sdn Bhd');
  v_out jsonb;
begin
  perform public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('PCN-1', 'SUPP1', '2026-01-05', 'Returned', '1', '80',
                   'CN-1', 'purchase_credit_note')
  ), true);
  perform pg_temp.check_eq('a purchase credit note comes in as one',
    (select doc_type::text from public.purchase_documents
      where org_id = v_org and doc_no = 'PCN-1'), 'purchase_credit_note');

  -- A SALES kind is not one of them, which is the copy-and-paste
  -- mistake this side is most exposed to.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('X-1', 'SUPP1', '2026-01-05', 'Wrong side', '1', '80',
                   null, 'invoice')
  ), false);
  perform pg_temp.check_true('but a sales invoice is not',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x)
      like 'invoice is not a kind of document this imports.%');
  perform pg_temp.check_true('and it lists the ones that are',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x)
      like '%bill, purchase_credit_note or purchase_debit_note.');
end $$;

-- ---------------------------------------------------------------------
-- 5. The rules 0631 proves, spot-checked on this side
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.p_org('Peraturan Sama Sdn Bhd');
  v_out jsonb;
  v_reader uuid := pg_temp.another_user('buyer@iakauntan.test');
begin
  -- A dry run writes nothing.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-7', 'SUPP1', '2026-01-05', 'Work', '1', '100')
  ), false);
  perform pg_temp.check_eq('a dry run writes nothing',
    (select count(*) from public.purchase_documents where org_id = v_org), 0);

  -- A bad row takes its whole document with it.
  perform pg_temp.check_refused(
    'and a bad row refuses the whole file',
    format('select public.import_purchase_transactions(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.p_line('BILL-8', 'SUPP1', '2026-01-05', 'Good', '1', '100'),
             pg_temp.p_line('BILL-8', 'SUPP1', '2026-01-05', 'Bad', '1', null)
           )::text),
    '%Nothing was imported%', '22023');
  perform pg_temp.check_eq('so the good line did not land either',
    (select count(*) from public.purchase_documents where org_id = v_org), 0);

  -- An unknown supplier says where to start.
  v_out := public.import_purchase_transactions(v_org, jsonb_build_array(
    pg_temp.p_line('BILL-9', 'NOBODY', '2026-01-05', 'Work', '1', '100')
  ), false);
  perform pg_temp.check_true('an unknown supplier says to import contacts',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x)
      like 'There is no supplier with the code NOBODY.%');

  -- And a reader cannot import, nor try one out.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_reader, 'viewer');
  perform pg_temp.sign_in_as(v_reader);
  perform pg_temp.check_refused(
    'somebody who may only read cannot import',
    format('select public.import_purchase_transactions(%L, %L::jsonb, false)',
           v_org, jsonb_build_array(
             pg_temp.p_line('BILL-9', 'SUPP1', '2026-01-05', 'Work', '1', '1')
           )::text),
    '%not permitted to import%', '42501');
end $$;

rollback;
