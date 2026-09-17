-- =====================================================================
-- iAkauntan :: the year before this one
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/import_transactions.sql
--
-- `0631`. A company moving in March has two months of invoices it would
-- like to keep. One row per LINE, grouped by document number, which
-- makes the interesting problem a grouping problem:
--
--   * **a bad row poisons its whole document.** Importing four of an
--     invoice's five lines produces an invoice for the wrong money that
--     looks perfectly well formed.
--   * **the header has to agree across a group**, and a disagreement is
--     reported against the row it disagrees WITH. "INV-1 has two dates"
--     is not findable in a thousand-line spreadsheet.
--   * **drafts, never posts.** This is the one importer that could
--     create five hundred documents in a statement.
--   * **run it twice and nothing happens twice.**
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.i_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.contacts (org_id, contact_type, code, name)
  values (v_org, 'customer', 'CUST1', 'Pelanggan Import Sdn Bhd'),
         (v_org, 'customer', 'CUST2', 'Pelanggan Lain Sdn Bhd');
  return v_org;
end;
$$;

-- One line of a file, as the importer receives it.
create or replace function pg_temp.line(
  p_no text, p_contact text, p_date text, p_desc text,
  p_qty text, p_price text, p_type text default null,
  p_currency text default null)
returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'doc_no', p_no, 'contact_code', p_contact, 'doc_date', p_date,
    'description', p_desc, 'quantity', p_qty, 'unit_price', p_price,
    'doc_type', p_type, 'currency', p_currency));
$$;

-- ---------------------------------------------------------------------
-- 1. A good file, and the totals are the ledger's arithmetic
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.i_org('Import Urus Niaga Sdn Bhd');
  v_out jsonb;
begin
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-100', 'CUST1', '2026-01-05', 'Consulting', '2', '500'),
    pg_temp.line('INV-100', 'CUST1', '2026-01-05', 'Travel', '1', '250'),
    pg_temp.line('INV-101', 'CUST2', '2026-01-06', 'Retainer', '1', '900')
  ), true);

  perform pg_temp.check_eq('two documents came out of three rows',
    (v_out ->> 'documents')::integer, 2);
  perform pg_temp.check_eq('and nothing was wrong with the file',
    (v_out ->> 'errors')::integer, 0);

  perform pg_temp.check_eq('the first invoice has both its lines',
    (select count(*) from public.sales_document_lines l
       join public.sales_documents d on d.id = l.document_id
      where d.org_id = v_org and d.doc_no = 'INV-100'), 2);

  -- The totals are `app.calc_document_line` and
  -- `app.recalc_sales_totals`, not this importer's arithmetic, so an
  -- imported invoice adds up the way a typed one does.
  perform pg_temp.check_eq('and adds up to what its lines come to',
    (select total_amount from public.sales_documents
      where org_id = v_org and doc_no = 'INV-100'), 1250::numeric);
  perform pg_temp.check_eq('the second is its own document',
    (select total_amount from public.sales_documents
      where org_id = v_org and doc_no = 'INV-101'), 900::numeric);

  -- The line the header calls the slowest to change.
  perform pg_temp.check_eq('everything arrives as a draft',
    (select count(*) from public.sales_documents
      where org_id = v_org and status <> 'draft'), 0);
  perform pg_temp.check_eq('and nothing is posted to the ledger',
    (select count(*) from public.sales_documents
      where org_id = v_org and gl_entry_id is not null), 0);
end $$;

-- ---------------------------------------------------------------------
-- 2. A dry run changes nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.i_org('Cuba Dahulu Sdn Bhd');
  v_out jsonb;
begin
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-200', 'CUST1', '2026-01-05', 'Work', '1', '100')
  ), false);

  perform pg_temp.check_eq('a dry run reports the rows',
    jsonb_array_length(v_out -> 'rows'), 1);
  perform pg_temp.check_eq('and says it did not commit',
    (v_out ->> 'committed')::boolean::text, 'false');
  perform pg_temp.check_eq('and nothing was created',
    (select count(*) from public.sales_documents where org_id = v_org), 0);
end $$;

-- ---------------------------------------------------------------------
-- 3. A bad row poisons its whole document
-- ---------------------------------------------------------------------
-- Four of an invoice's five lines is an invoice for the wrong money
-- that looks perfectly well formed, which is worse than a refusal.
do $$
declare
  v_org uuid := pg_temp.i_org('Baris Rosak Sdn Bhd');
  v_out jsonb;
begin
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-300', 'CUST1', '2026-01-05', 'Good', '1', '100'),
    pg_temp.line('INV-300', 'CUST1', '2026-01-05', 'Bad', '1', null),
    pg_temp.line('INV-301', 'CUST1', '2026-01-06', 'Fine', '1', '200')
  ), false);

  perform pg_temp.check_eq('the bad row is reported',
    (v_out ->> 'errors')::integer, 1);
  perform pg_temp.check_eq('and named by its line',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2), 'No unit price on this line.');

  perform pg_temp.check_refused(
    'and the whole file is refused rather than half imported',
    format('select public.import_sales_transactions(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.line('INV-300', 'CUST1', '2026-01-05', 'Good', '1', '100'),
             pg_temp.line('INV-300', 'CUST1', '2026-01-05', 'Bad', '1', null)
           )::text),
    '%Nothing was imported%', '22023');

  perform pg_temp.check_eq('so the good line did not land either',
    (select count(*) from public.sales_documents where org_id = v_org), 0);
end $$;

-- ---------------------------------------------------------------------
-- 4. The header has to agree across a group
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.i_org('Tajuk Bercanggah Sdn Bhd');
  v_out jsonb;
  v_msg text;
begin
  -- Two dates for one invoice.
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-400', 'CUST1', '2026-01-05', 'One', '1', '100'),
    pg_temp.line('INV-400', 'CUST1', '2026-01-09', 'Two', '1', '100')
  ), false);
  v_msg := (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
             where (x ->> 'row')::integer = 2);
  perform pg_temp.check_true('a second date is caught', v_msg is not null);
  -- The row it disagrees WITH, which is the whole point: "INV-400 has
  -- two dates" is not findable in a thousand-line file.
  perform pg_temp.check_true('and names the row it disagrees with',
    v_msg like 'Row 1 dates INV-400 2026-01-05 and this row dates it 2026-01-09.');

  -- Two customers for one invoice.
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-401', 'CUST1', '2026-01-05', 'One', '1', '100'),
    pg_temp.line('INV-401', 'CUST2', '2026-01-05', 'Two', '1', '100')
  ), false);
  perform pg_temp.check_true('a second customer is caught',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) like 'Row 1 puts INV-401 against customer cust1%');

  -- Two kinds of document under one number.
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-402', 'CUST1', '2026-01-05', 'One', '1', '100'),
    pg_temp.line('INV-402', 'CUST1', '2026-01-05', 'Two', '1', '100',
                 'credit_note')
  ), false);
  perform pg_temp.check_true('a second kind is caught',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) like 'Row 1 calls INV-402 a invoice%');

  -- Two currencies.
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-403', 'CUST1', '2026-01-05', 'One', '1', '100'),
    pg_temp.line('INV-403', 'CUST1', '2026-01-05', 'Two', '1', '100',
                 null, 'USD')
  ), false);
  perform pg_temp.check_true('and so is a second currency',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) like 'Row 1 puts INV-403 in MYR%');

  -- And a group that agrees is no problem at all, which is the
  -- assertion that stops the four above passing for the wrong reason.
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-404', 'CUST1', '2026-01-05', 'One', '1', '100'),
    pg_temp.line('INV-404', 'CUST1', '2026-01-05', 'Two', '1', '100')
  ), false);
  perform pg_temp.check_eq('a group that agrees passes',
    (v_out ->> 'errors')::integer, 0);
end $$;

-- ---------------------------------------------------------------------
-- 5. Run it twice and nothing happens twice
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.i_org('Sekali Sahaja Sdn Bhd');
  v_file jsonb := jsonb_build_array(
    pg_temp.line('INV-500', 'CUST1', '2026-01-05', 'Work', '1', '400'));
  v_out  jsonb;
begin
  perform public.import_sales_transactions(v_org, v_file, true);
  perform pg_temp.check_eq('the first run lands',
    (select count(*) from public.sales_documents where org_id = v_org), 1);

  -- The document is there, so THAT is what the second run says. The
  -- `import_ref` check below it is for a case this one cannot see.
  v_out := public.import_sales_transactions(v_org, v_file, false);
  perform pg_temp.check_true('and the second is refused by name',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x)
      like 'There is already a invoice numbered INV-500 here.');

  perform pg_temp.check_refused(
    'and committing it changes nothing',
    format('select public.import_sales_transactions(%L, %L::jsonb, true)',
           v_org, v_file::text),
    '%Nothing was imported%', '22023');
  perform pg_temp.check_eq('there is still one of it',
    (select count(*) from public.sales_documents where org_id = v_org), 1);

  -- And the case the number check CANNOT see: the document was
  -- deleted, so nothing is numbered INV-500 any more -- but
  -- `sales_documents_import_key` is a unique index with no
  -- `deleted_at` predicate, so the row still holds the key. Without
  -- this branch the second run dies on a raw constraint violation
  -- instead of a sentence, which is the difference between "running
  -- the same file twice does not import it twice" and
  -- `23505`.
  update public.sales_documents set deleted_at = now()
   where org_id = v_org and doc_no = 'INV-500';

  v_out := public.import_sales_transactions(v_org, v_file, false);
  perform pg_temp.check_true(
    'a file re-run after the import was deleted says so in words',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x)
      like '%was imported before. Running the same file twice does not %');
  perform pg_temp.check_refused(
    'and is still refused rather than raising a constraint',
    format('select public.import_sales_transactions(%L, %L::jsonb, true)',
           v_org, v_file::text),
    '%Nothing was imported%', '22023');
end $$;

-- A number that is already here by hand is the same refusal for a
-- different reason, and it must say which.
do $$
declare
  v_org uuid := pg_temp.i_org('Sudah Ada Sdn Bhd');
  v_out jsonb;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-600', date '2026-01-01',
          (select id from public.contacts
            where org_id = v_org and code = 'CUST1'),
          'MYR', 1, 100, 100, 100, 'draft');

  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('INV-600', 'CUST1', '2026-01-05', 'Work', '1', '400')
  ), false);

  perform pg_temp.check_true('a number already here is refused',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x)
      like 'There is already a invoice numbered INV-600 here.');
end $$;

-- ---------------------------------------------------------------------
-- 6. What a row on its own has to carry
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.i_org('Baris Sendiri Sdn Bhd');
  v_out jsonb;
  function_result text;
begin
  v_out := public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line(null, 'CUST1', '2026-01-05', 'No number', '1', '100'),
    pg_temp.line('INV-701', 'NOBODY', '2026-01-05', 'No customer', '1', '100'),
    pg_temp.line('INV-702', 'CUST1', 'not a date', 'Bad date', '1', '100'),
    pg_temp.line('INV-703', 'CUST1', '2026-01-05', 'Bad kind', '1', '100',
                 'quotation'),
    jsonb_build_object('doc_no', 'INV-704', 'contact_code', 'CUST1',
      'doc_date', '2026-01-05', 'description', 'Bad tax', 'quantity', '1',
      'unit_price', '100', 'tax_code', 'NOSUCH'),
    jsonb_build_object('doc_no', 'INV-705', 'contact_code', 'CUST1',
      'doc_date', '2026-01-05', 'description', 'Bad item', 'quantity', '1',
      'unit_price', '100', 'item_code', 'NOSUCH'),
    -- A quantity with its unit typed into it. `app.import_number`
    -- returns the DEFAULT for a blank cell and NULL for one it cannot
    -- read, so without a check this is neither reported nor imported as
    -- 1 -- it dies on `quantity` being NOT NULL, which is a constraint
    -- name where a sentence belongs.
    pg_temp.line('INV-706', 'CUST1', '2026-01-05', 'Hours', '2.5 hrs', '100')
  ), false);

  perform pg_temp.check_eq('every one of them is a problem',
    (v_out ->> 'errors')::integer, 7);
  -- Each says WHICH thing is wrong, because "row 3 is invalid" sends
  -- somebody back to a spreadsheet to guess.
  perform pg_temp.check_true('a missing number says what it is for',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 1) like '%groups the lines%');
  perform pg_temp.check_true('an unknown customer says to import contacts',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 2) like '%Import the contacts first.');
  perform pg_temp.check_true('an unreadable date names the document',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 3) like 'INV-702 has no date%');
  perform pg_temp.check_true('an unknown kind lists the ones there are',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 4) like '%invoice, credit_note or debit_note.');
  perform pg_temp.check_true('an unknown tax code says so',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 5) like 'There is no tax code NOSUCH%');
  perform pg_temp.check_true('and an unknown item',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 6) like 'There is no item with the code NOSUCH.');
  perform pg_temp.check_true('a quantity with a unit typed into it says so',
    (select x ->> 'problem' from jsonb_array_elements(v_out -> 'rows') x
      where (x ->> 'row')::integer = 7) like '2.5 hrs is not a quantity%');

  -- And a BLANK quantity is not the same thing: one line in a hundred
  -- leaves it empty and means one. `app.import_number` returns the
  -- default for that, and the check above must not swallow it.
  perform pg_temp.check_eq('but a blank quantity is one, not a problem',
    (select (x ->> 'status') from jsonb_array_elements(
       public.import_sales_transactions(v_org, jsonb_build_array(
         jsonb_build_object('doc_no', 'INV-707', 'contact_code', 'CUST1',
           'doc_date', '2026-01-05', 'description', 'One of them',
           'unit_price', '100')), false) -> 'rows') x), 'ok');
end $$;

-- ---------------------------------------------------------------------
-- 7. A credit note is a kind this imports, and it is still a draft
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.i_org('Nota Kredit Import Sdn Bhd');
begin
  perform public.import_sales_transactions(v_org, jsonb_build_array(
    pg_temp.line('CN-800', 'CUST1', '2026-01-05', 'Returned', '1', '300',
                 'credit_note')
  ), true);

  perform pg_temp.check_eq('a credit note comes in as one',
    (select doc_type::text from public.sales_documents
      where org_id = v_org and doc_no = 'CN-800'), 'credit_note');
  perform pg_temp.check_eq('and as a draft like everything else',
    (select status::text from public.sales_documents
      where org_id = v_org and doc_no = 'CN-800'), 'draft');
end $$;

-- ---------------------------------------------------------------------
-- 8. Somebody who may not write cannot import
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.i_org('Kebenaran Import Sdn Bhd');
  v_reader uuid := pg_temp.another_user('reader@iakauntan.test');
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_reader, 'viewer');
  perform pg_temp.sign_in_as(v_reader);

  perform pg_temp.check_refused(
    'somebody who may only read cannot import',
    format('select public.import_sales_transactions(%L, %L::jsonb, true)',
           v_org, jsonb_build_array(
             pg_temp.line('INV-900', 'CUST1', '2026-01-05', 'Work', '1', '1')
           )::text),
    '%not permitted to import%', '42501');

  -- And not even a dry run, which would otherwise be a way to ask
  -- whether a document number exists.
  perform pg_temp.check_refused(
    'nor try one out',
    format('select public.import_sales_transactions(%L, %L::jsonb, false)',
           v_org, jsonb_build_array(
             pg_temp.line('INV-900', 'CUST1', '2026-01-05', 'Work', '1', '1')
           )::text),
    '%not permitted to import%', '42501');
end $$;

rollback;
