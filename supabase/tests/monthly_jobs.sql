-- =====================================================================
-- iAkauntan :: the jobs that only run on the first of the month
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/monthly_jobs.sql
--
-- `app.roll_einvoice_consolidation` compared `d.status in ('posted',
-- 'partial', 'paid')`, and `app.doc_status` has no `paid`. It raised
-- `22P02` on every call and had done since `0058`.
--
-- Nothing caught it because of how it was reached: `run_daily_jobs`
-- calls it only when the day of the month is 1, and every test in this
-- repository called `run_daily_jobs` with the real current date. The
-- branch was therefore tested on whichever day the suite happened to
-- run, and for hundreds of runs that was never the first.
--
-- So the rule this file exists to keep: **a job with a calendar branch
-- is tested on the date that takes the branch**, pinned, not on today.
-- Every call below names its own date.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.mj_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'einvoice', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end $$;

-- A posted invoice to a buyer with no TIN, which is what a consolidated
-- e-Invoice is for.
create or replace function pg_temp.mj_invoice(
  p_org uuid, p_no text, p_date date, p_contact uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', p_no, p_date, p_contact, 'MYR', 1, 'draft')
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_id, 1, 'Walk-in sale', 1, p_amount);
  perform public.post_sales_document(v_id);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- The month's sales to buyers who asked for no invoice
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.mj_org('Runcit Bulanan Sdn Bhd');
  v_walk uuid;
  v_firm uuid;
  v_id   uuid;
  v_paid uuid;
  v_bank uuid;
  v_rcp  uuid;
  v_c    record;
  v_n    integer;
begin
  -- A consumer: no TIN, so no individual e-Invoice can be issued and
  -- the sale belongs in the consolidation.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan Kaunter', 'customer')
  returning id into v_walk;
  -- A business with a TIN gets its own e-Invoice and stays out.
  insert into public.contacts (org_id, code, name, contact_type, tin)
  values (v_org, 'C2', 'Syarikat Bertin Sdn Bhd', 'customer', 'C1234567890')
  returning id into v_firm;

  perform pg_temp.mj_invoice(v_org, 'INV-1', date '2026-06-03', v_walk, 100);
  v_paid := pg_temp.mj_invoice(v_org, 'INV-2', date '2026-06-20', v_walk, 250);

  -- Paid off in full, which takes the invoice to `completed`. This is
  -- the case the whole consolidation is about: a walk-in customer pays
  -- cash at the counter and asks for no invoice. Dropping `completed`
  -- from the status list would leave every settled counter sale out of
  -- the return, and the ones remaining would be the few nobody paid.
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, currency)
  values (v_org, (select id from public.accounts
                   where org_id = v_org and code = '1110'),
          'Cash', 'Counter', 'MYR')
  returning id into v_bank;
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     amount, unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-1', date '2026-06-20', v_walk, v_bank, 250, 250,
          'MYR', 1)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);
  perform public.allocate_with_discount(v_rcp, v_paid, 250, null);
  perform pg_temp.check_eq('the counter sale is settled',
    (select status::text from public.sales_documents where id = v_paid),
    'completed');

  perform pg_temp.mj_invoice(v_org, 'INV-3', date '2026-06-20', v_firm, 900);
  -- The month after, which this consolidation is not about.
  perform pg_temp.mj_invoice(v_org, 'INV-4', date '2026-07-02', v_walk, 400);

  -- Called directly first, so the failure is this function's own rather
  -- than something the loop swallowed.
  v_id := app.roll_einvoice_consolidation(v_org, date '2026-06-01');
  perform pg_temp.check_true('June is gathered at all', v_id is not null);

  select * into v_c from public.einvoice_consolidations where id = v_id;
  perform pg_temp.check_eq('the period is the month',
    v_c.period_start::text || '..' || v_c.period_end::text,
    '2026-06-01..2026-06-30');
  perform pg_temp.check_eq('two sales, not three',
    v_c.document_count, 2);
  perform pg_temp.check_eq('and their total',
    round(v_c.total_amount, 2), 350);
  -- LHDN gives seven calendar days after the month end.
  perform pg_temp.check_eq('due seven days after the month ends',
    v_c.due_date::text, '2026-07-07');

  perform pg_temp.check_eq('a buyer with a TIN gets their own e-Invoice',
    (select count(*)::integer from public.einvoice_consolidation_items i
       join public.sales_documents d on d.id = i.sales_document_id
      where i.consolidation_id = v_id and d.contact_id = v_firm), 0);
  perform pg_temp.check_eq('and next month is next month''s',
    (select count(*)::integer from public.einvoice_consolidation_items i
       join public.sales_documents d on d.id = i.sales_document_id
      where i.consolidation_id = v_id and d.doc_no = 'INV-4'), 0);

  -- Twice is once. The scheduler runs every day and the first of the
  -- month comes round again next year.
  perform pg_temp.check_true('gathering it again gathers nothing',
    app.roll_einvoice_consolidation(v_org, date '2026-06-01') is null);
  select count(*)::integer into v_n from public.einvoice_consolidations
   where org_id = v_org;
  perform pg_temp.check_eq('and leaves one consolidation', v_n, 1);

  -- A month with nothing in it is not a consolidation of nothing.
  perform pg_temp.check_true('an empty month raises nothing',
    app.roll_einvoice_consolidation(v_org, date '2026-05-01') is null);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The day the branch is taken
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.mj_org('Kerja Harian Sdn Bhd');
  v_walk uuid;
  v_off  uuid;
  v_walk2 uuid;
  v_n    integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan Kaunter', 'customer')
  returning id into v_walk;
  perform pg_temp.mj_invoice(v_org, 'INV-1', date '2026-06-10', v_walk, 500);

  -- The tenth of the month: the branch is not taken and nothing is
  -- gathered. This is the case every existing test happened to run.
  perform app.run_daily_jobs(date '2026-07-10');
  select count(*)::integer into v_n from public.einvoice_consolidations
   where org_id = v_org;
  perform pg_temp.check_eq('mid-month, the consolidation is not due', v_n, 0);

  -- A company that never bought the module gets nothing gathered, on
  -- the first or any other day. `0232` made entitlement real, and
  -- e-Invoice rows appearing for a company that is not on e-Invoice is
  -- the module leaking.
  v_off := pg_temp.test_org('Tiada Modul Sdn Bhd');
  perform public.create_fiscal_year(v_off, date '2026-01-01');
  update public.org_modules set is_enabled = false
   where org_id = v_off and module_code = 'einvoice';
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_off, 'C1', 'Kaunter', 'customer') returning id into v_walk2;
  perform pg_temp.mj_invoice(v_off, 'INV-1', date '2026-06-11', v_walk2, 90);
  perform app.run_daily_jobs(date '2026-07-01');
  select count(*)::integer into v_n from public.einvoice_consolidations
   where org_id = v_off;
  perform pg_temp.check_eq(
    'a company not on the module gathers nothing', v_n, 0);

  -- The first: the branch is taken, and this is the call that raised
  -- `22P02` for as long as the function has existed.
  perform app.run_daily_jobs(date '2026-07-01');
  select count(*)::integer into v_n from public.einvoice_consolidations
   where org_id = v_org;
  perform pg_temp.check_eq('on the first, June is gathered', v_n, 1);
  perform pg_temp.check_eq('for the month that just ended',
    (select period_start::text from public.einvoice_consolidations
      where org_id = v_org), '2026-06-01');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- One company's bad month is one company's bad month
--
-- The isolation `0375` gave the daily steps and not the monthly ones.
-- Asserted by breaking one organization on purpose and checking the
-- next one still gets its work.
-- ---------------------------------------------------------------------
do $$
declare
  v_bad  uuid := pg_temp.mj_org('Rosak Sdn Bhd');
  v_good uuid := pg_temp.mj_org('Elok Sdn Bhd');
  v_w1   uuid;
  v_w2   uuid;
  v_n    integer;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_bad, 'C1', 'Kaunter', 'customer') returning id into v_w1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_good, 'C1', 'Kaunter', 'customer') returning id into v_w2;
  perform pg_temp.mj_invoice(v_bad, 'INV-1', date '2026-06-05', v_w1, 100);
  perform pg_temp.mj_invoice(v_good, 'INV-1', date '2026-06-05', v_w2, 200);

  -- A consolidation row for the same period with a period_end that
  -- contradicts the one the roll computes. The roll sees the existing
  -- row and returns null rather than failing — so to make one company
  -- genuinely fail, take the table away from it: a check constraint
  -- that refuses its insert and nobody else's.
  alter table public.einvoice_consolidations
    add constraint mj_break check (total_amount <> 100);

  perform app.run_daily_jobs(date '2026-07-01');

  select count(*)::integer into v_n from public.einvoice_consolidations
   where org_id = v_bad;
  perform pg_temp.check_eq('the broken company gathers nothing', v_n, 0);
  select count(*)::integer into v_n from public.einvoice_consolidations
   where org_id = v_good;
  -- The point of the whole migration: without the handler, whichever
  -- organization came second in the loop got no daily jobs at all.
  perform pg_temp.check_eq(
    'and the next company still gets its consolidation', v_n, 1);

  alter table public.einvoice_consolidations drop constraint mj_break;
  perform pg_temp.sign_out();
end $$;

rollback;
