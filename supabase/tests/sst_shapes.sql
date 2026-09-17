-- =====================================================================
-- iAkauntan :: the documents an SST return has to survive
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sst_shapes.sql
--
-- `sst_taxable_period.sql` pins the two-month cycle and
-- `service_tax_on_payment.sql` pins section 11's payment basis, and both
-- are good files. A mutation sweep of the two functions under them --
-- `app.sst_period_for` and `app.sst_output_due` -- still killed only 25
-- of 46 one-line mutants.
--
-- What was missing was, again, the SHAPES: a taxable period the Director
-- General fixed by hand, a draft invoice, a voided receipt, a refund
-- note, a service charge, an invoice that carries no service tax at all,
-- and the day the twelve-month clock actually strikes.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ss_org(p_name text, p_from date)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'));
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'SL10', 'Sales Tax 10%', '01', 10,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'));
  -- Zero rated, and still service tax: an exempt supply under the
  -- First Schedule is coded, declared and taxed at nothing.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST0', 'Service Tax, exempt', '02', 0,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'));
  perform public.set_sst_registration(
    v_org, true, p_from, 'W10-1808-31000456', 'ST8');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer');
  return v_org;
end $$;

create or replace function pg_temp.ss_doc(
  p_org uuid, p_type text, p_no text, p_date date, p_net numeric,
  p_code text default 'ST8', p_status text default 'posted')
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, p_type::app.sales_doc_type, p_no, p_date,
          (select id from public.contacts where org_id = p_org and code = 'C1'),
          'MYR', 1, p_status::app.doc_status)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     tax_code_id, tax_rate)
  values (p_org, v_doc, 1, 'Khidmat', 1, p_net,
          (select id from public.tax_codes where org_id = p_org and code = p_code),
          (select rate from public.tax_codes where org_id = p_org and code = p_code));
  return v_doc;
end $$;

create or replace function pg_temp.ss_pay(
  p_org uuid, p_doc uuid, p_on date, p_amount numeric, p_no text,
  p_status text default 'posted')
returns void language plpgsql as $$
declare v_rec uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, currency, exchange_rate,
     amount, status)
  values (p_org, p_no, p_on,
          (select id from public.contacts where org_id = p_org and code = 'C1'),
          'MYR', 1, p_amount, p_status::app.doc_status)
  returning id into v_rec;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount)
  values (p_org, v_rec, p_doc, p_amount);
end $$;

-- =====================================================================
-- 1. The registration invariant, which two mutants depend on
-- =====================================================================
--
-- `app.sst_period_for` opens with four conditions, and two of them --
-- `not is_sst_registered` and `sst_registered_from is null` -- MASK EACH
-- OTHER. A company registered with no date, or unregistered with one,
-- would tell them apart, and neither state exists: `set_sst_registration`
-- writes the boolean and the date together, and `guard_sst_registration`
-- refuses any other writer.
--
-- So the two mutants are equivalent BECAUSE OF THAT PAIRING, and the
-- pairing is what this block asserts. It is the third time in this
-- campaign that a surviving mutant turned out to depend on an invariant
-- enforced somewhere else and re-checked nowhere.
-- =====================================================================
do $$
declare
  v_org uuid;
  r     record;
begin
  v_org := pg_temp.ss_org('Invarian SST Sdn Bhd', date '2026-01-15');

  select * into r from public.organizations where id = v_org;
  perform pg_temp.check_true('registering sets both the flag and the date',
    r.is_sst_registered and r.sst_registered_from is not null);

  -- The guard, in its own words.
  begin
    update public.organizations set is_sst_registered = false where id = v_org;
    raise exception 'FAIL: SST registration was set field by field';
  exception when sqlstate '42501' then
    raise notice 'ok   SST registration cannot be set one field at a time';
  end;
  begin
    update public.organizations set sst_registered_from = null where id = v_org;
    raise exception 'FAIL: the registration date was cleared on its own';
  exception when sqlstate '42501' then
    raise notice 'ok   nor can the date be cleared on its own';
  end;

  -- And coming off the register takes the date with it, so the pair
  -- cannot come apart in that direction either.
  insert into public.tax_codes (org_id, code, name, tax_type_code, rate)
  values (v_org, 'NA', 'Not applicable', '06', 0);
  perform public.set_sst_registration(v_org, false);
  select * into r from public.organizations where id = v_org;
  perform pg_temp.check_true('deregistering clears both',
    not r.is_sst_registered and r.sst_registered_from is null);
  perform pg_temp.check_eq('and there is no taxable period after that',
    (select count(*) from app.sst_period_for(v_org, date '2026-06-15')), 0);

  raise notice 'ok   the registration invariant';
end $$;

-- =====================================================================
-- 2. A taxable period the Director General fixed by hand
-- =====================================================================
--
-- Section 8 of the Service Tax Regulations 2018 lets the Director
-- General assign a different taxable period on application. The column
-- is there, the code has three branches for it, and NOTHING in the
-- suite had ever set it -- so a mutant ignoring it, one skipping the
-- step back to registration, and one dropping the wrap into the
-- following year all lived.
-- =====================================================================
do $$
declare
  v_org uuid;
  r     record;
begin
  perform pg_temp.allow_many_companies();
  -- Registered 15 January 2026. Left alone, the cycle would end
  -- February, April, June: the first period runs to 28 February.
  v_org := pg_temp.ss_org('Tempoh Ditetapkan Sdn Bhd', date '2026-01-15');

  select * into r from app.sst_period_for(v_org, date '2026-02-10');
  perform pg_temp.check_eq('by default the first period ends in February',
    r.period_end::text, '2026-02-28');

  -- The Director General fixes the cycle on odd month-ends instead:
  -- January, March, May. Only the parity matters, so naming any odd
  -- month sets the same cycle.
  update public.organizations set sst_period_ends_month = 5 where id = v_org;

  -- MUTANT: `if v_org.sst_period_ends_month is not null then` -> false,
  -- and the step-back loop deleted. May is the month named; the loop
  -- walks it back two at a time to the first such month-end on or after
  -- registration, which is January.
  select * into r from app.sst_period_for(v_org, date '2026-01-20');
  perform pg_temp.check_eq('the fixed cycle puts the first period end in January',
    r.period_end::text, '2026-01-31');
  perform pg_temp.check_eq('starting at the registration, not the month',
    r.period_start::text, '2026-01-15');
  perform pg_temp.check_true('and it is the first period', r.is_first);
  perform pg_temp.check_eq('due at the end of the month after it ends',
    r.due_date::text, '2026-02-28');

  select * into r from app.sst_period_for(v_org, date '2026-03-10');
  perform pg_temp.check_eq('the next one runs February to March',
    r.period_start::text || '..' || r.period_end::text,
    '2026-02-01..2026-03-31');
  select * into r from app.sst_period_for(v_org, date '2026-05-01');
  perform pg_temp.check_eq('and the one after that April to May',
    r.period_start::text || '..' || r.period_end::text,
    '2026-04-01..2026-05-31');

  -- MUTANT: the `+ 12` wrap deleted. A month named EARLIER in the
  -- calendar than the registration month belongs to the following year
  -- before the step-back can walk it anywhere useful. Registered in
  -- November and told to end in January: that January is next year's.
  v_org := pg_temp.ss_org('November Sdn Bhd', date '2026-11-10');
  update public.organizations set sst_period_ends_month = 1 where id = v_org;

  -- The step-back walks that January back two months at a time to
  -- November, the registration month itself -- so the first period is
  -- the twenty-one days from the 10th to the 30th, and the cycle proper
  -- begins in December.
  select * into r from app.sst_period_for(v_org, date '2026-11-20');
  perform pg_temp.check_eq('the first period is the rest of November',
    r.period_start::text || '..' || r.period_end::text,
    '2026-11-10..2026-11-30');
  perform pg_temp.check_true('and it is the first', r.is_first);

  select * into r from app.sst_period_for(v_org, date '2026-12-01');
  perform pg_temp.check_eq('then the January cycle proper',
    r.period_start::text || '..' || r.period_end::text,
    '2026-12-01..2027-01-31');

  raise notice 'ok   a taxable period fixed by hand';
end $$;

-- =====================================================================
-- 3. A monthly filer's first period
-- =====================================================================
do $$
declare
  v_org uuid;
  r     record;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ss_org('Bulanan Sdn Bhd', date '2026-03-10');
  update public.organizations set sst_period_months = 1 where id = v_org;

  -- MUTANT: `v_start = v_org.sst_registered_from` -> false. The flag is
  -- what tells a screen that a period is short because the company had
  -- only just registered, rather than because something is wrong.
  select * into r from app.sst_period_for(v_org, date '2026-03-20');
  perform pg_temp.check_eq('the first monthly period starts at registration',
    r.period_start::text, '2026-03-10');
  perform pg_temp.check_true('and says so', r.is_first);

  select * into r from app.sst_period_for(v_org, date '2026-04-20');
  perform pg_temp.check_eq('the next one is a whole month',
    r.period_start::text || '..' || r.period_end::text,
    '2026-04-01..2026-04-30');
  perform pg_temp.check_true('and is not the first', not r.is_first);
  perform pg_temp.check_eq('due at the end of the month after it',
    r.due_date::text, '2026-05-31');

  raise notice 'ok   a monthly filer''s first period';
end $$;

-- =====================================================================
-- 4. Which documents reach the return
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_inv  uuid;
  v_sl   uuid;
  v_draft uuid;
  v_void uuid;
  v_quote uuid;
  v_ref  uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ss_org('Dokumen Cukai Sdn Bhd', date '2026-01-01');

  -- Sales tax, which is due on the document and not on the payment.
  v_sl := pg_temp.ss_doc(v_org, 'invoice', 'INV-SL', date '2026-03-10',
                         1000, 'SL10');
  -- MUTANT: `d.status not in ('draft','void')` dropped. A draft invoice
  -- is a document nobody has issued; declaring its tax pays SSM out of
  -- a sale that has not happened.
  v_draft := pg_temp.ss_doc(v_org, 'invoice', 'INV-DR', date '2026-03-11',
                            5000, 'SL10', 'draft');
  v_void := pg_temp.ss_doc(v_org, 'invoice', 'INV-VD', date '2026-03-12',
                           7000, 'SL10', 'void');
  -- MUTANT: `d.doc_type in (...)` dropped. A quotation carries lines and
  -- a tax code and is not a tax invoice.
  v_quote := pg_temp.ss_doc(v_org, 'quotation', 'QT-1', date '2026-03-13',
                            9000, 'SL10');

  perform pg_temp.check_eq('only the issued invoice is declared',
    (select d.taxable_amount from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') d
      where d.tax_type_code = '01'), 1000);
  perform pg_temp.check_eq('and its tax with it',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') d
      where d.tax_type_code = '01'), 100);

  -- MUTANT: the credit note sign narrowed so a refund note adds rather
  -- than subtracts. A refund note is money going back to the customer;
  -- the tax on it goes back too.
  v_ref := pg_temp.ss_doc(v_org, 'refund_note', 'RF-1', date '2026-03-20',
                          400, 'SL10');
  perform pg_temp.check_eq('a refund note reduces what is declared',
    (select d.taxable_amount from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') d
      where d.tax_type_code = '01'), 600);
  perform pg_temp.check_eq('and reduces the tax',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') d
      where d.tax_type_code = '01'), 60);

  -- MUTANT: `and (x.net <> 0 or x.tax <> 0)` dropped, and `x.tax is not
  -- null` with it. A return with a line of nothing on it is a return
  -- somebody has to explain.
  perform pg_temp.check_eq('a period with nothing in it declares nothing',
    (select count(*) from app.sst_output_due(
       v_org, date '2026-08-01', date '2026-09-30')), 0);

  -- And a credit note cancelling an invoice exactly nets to no line at
  -- all, rather than to a line of zero.
  perform pg_temp.ss_doc(v_org, 'invoice', 'INV-N', date '2026-06-05',
                         800, 'SL10');
  perform pg_temp.ss_doc(v_org, 'credit_note', 'CN-N', date '2026-06-06',
                         800, 'SL10');
  perform pg_temp.check_eq('and a credit note that cancels an invoice leaves none',
    (select count(*) from app.sst_output_due(
       v_org, date '2026-06-01', date '2026-07-31')), 0);

  raise notice 'ok   which documents reach the return';
end $$;

-- =====================================================================
-- 5. Which receipts count as payment
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_other uuid;
  v_inv   uuid;
  v_a     uuid;
  v_b     uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ss_org('Resit Sdn Bhd', date '2026-01-01');

  -- Three invoices, because `apply_allocation` counts every allocation
  -- against an invoice whatever the receipt's status -- so a draft and a
  -- void receipt cannot be stacked on the one invoice to prove they do
  -- not count.
  v_inv := pg_temp.ss_doc(v_org, 'invoice', 'INV-S1', date '2026-02-10', 1000);
  v_a   := pg_temp.ss_doc(v_org, 'invoice', 'INV-S2', date '2026-02-11', 1000);
  v_b   := pg_temp.ss_doc(v_org, 'invoice', 'INV-S3', date '2026-02-12', 1000);

  -- MUTANT: `r.status not in ('draft','void')` dropped. A receipt
  -- somebody keyed and voided is not money received, and service tax
  -- becomes due when the money arrives.
  perform pg_temp.ss_pay(v_org, v_a, date '2026-03-05', 1080, 'RC-1',
                         'draft');
  perform pg_temp.ss_pay(v_org, v_b, date '2026-03-06', 1080, 'RC-2',
                         'void');
  perform pg_temp.check_eq('a draft or voided receipt is not payment',
    (select count(*) from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30')), 0);

  perform pg_temp.ss_pay(v_org, v_inv, date '2026-03-07', 540, 'RC-3');
  perform pg_temp.check_eq('a posted one is',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') d
      where d.basis = 'payment'), 40);
  perform pg_temp.check_eq('and half the invoice is half the tax',
    (select d.taxable_amount from app.sst_output_due(
       v_org, date '2026-03-01', date '2026-04-30') d
      where d.basis = 'payment'), 500);

  raise notice 'ok   which receipts count as payment';
end $$;

-- =====================================================================
-- 6. The day the twelve-month clock strikes
-- =====================================================================
--
-- Section 11(2): where payment is not received within twelve months
-- from the date of the invoice, the tax is due on the DAY FOLLOWING
-- that period. A mutant taking the anniversary itself rather than the
-- day after lived, because nothing had ever paid an invoice on exactly
-- its anniversary -- which is the one day the two readings disagree.
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_on   uuid;   -- paid on the anniversary itself
  v_late uuid;   -- paid the day after
  v_full uuid;   -- paid in full, long before
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ss_org('Dua Belas Bulan Sdn Bhd', date '2025-01-01');

  v_on   := pg_temp.ss_doc(v_org, 'invoice', 'INV-A', date '2026-01-15', 1000);
  v_late := pg_temp.ss_doc(v_org, 'invoice', 'INV-B', date '2026-01-15', 1000);
  v_full := pg_temp.ss_doc(v_org, 'invoice', 'INV-C', date '2026-01-15', 1000);

  -- Paid on 15 January 2027: the anniversary itself, inside the twelve
  -- months, so it is declared on the PAYMENT basis and never reaches
  -- the clock.
  perform pg_temp.ss_pay(v_org, v_on, date '2027-01-15', 1080, 'RC-A');
  -- Paid on the 16th: one day late, so the tax fell due on the 16th on
  -- the clock, and the payment must not declare it a second time.
  perform pg_temp.ss_pay(v_org, v_late, date '2027-01-16', 1080, 'RC-B');
  -- And one settled immediately.
  perform pg_temp.ss_pay(v_org, v_full, date '2026-02-01', 1080, 'RC-C');

  -- MUTANT: `+ interval '12 months' + interval '1 day'` without the day.
  -- On that reading the 15th is already past the deadline, so INV-A's
  -- payment is ignored and the whole invoice falls due on the clock.
  perform pg_temp.check_eq(
    'payment on the anniversary itself is payment, not default',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2027-01-01', date '2027-01-15') d
      where d.basis = 'payment'), 80);
  perform pg_temp.check_eq('and nothing is on the clock that day',
    (select count(*) from app.sst_output_due(
       v_org, date '2027-01-01', date '2027-01-15') d
      where d.basis = 'twelve months'), 0);

  -- The 16th: one invoice falls due on the clock, and the one paid that
  -- day is NOT declared again on the payment basis.
  perform pg_temp.check_eq('the day after, what is unpaid falls due',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2027-01-16', date '2027-01-16') d
      where d.basis = 'twelve months'), 80);
  perform pg_temp.check_eq('and the payment that arrives that day is not declared',
    (select count(*) from app.sst_output_due(
       v_org, date '2027-01-16', date '2027-01-16') d
      where d.basis = 'payment'), 0);

  -- MUTANT: `and an.total > an.paid_by_then` dropped. An invoice settled
  -- a year ago must not come back on its anniversary; it was declared
  -- when the money arrived.
  perform pg_temp.check_eq('an invoice paid in full does not fall due again',
    (select coalesce(sum(d.tax_amount), 0) from app.sst_output_due(
       v_org, date '2027-01-16', date '2027-01-16') d
      where d.basis = 'twelve months'), 80);

  raise notice 'ok   the day the twelve-month clock strikes';
end $$;


-- =====================================================================
-- 7. The service charge, the exempt supply, and the sen
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_sc   uuid;
  v_no   uuid;
  v_zero uuid;
  v_part uuid;
  v_free uuid;
  v_total numeric;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.ss_org('Caj Perkhidmatan Sdn Bhd', date '2026-01-01');

  -- MUTANT: `and coalesce(d.service_charge_amount, 0) <> 0` -> false,
  -- which drops the whole second arm of the union. The service charge
  -- is not a line on the bill -- it is a percentage of all of them, and
  -- it lives on the HEADER. `0418` put it there and this is the return
  -- reading it back. A restaurant's ten per cent is service tax it owes.
  --
  -- It is service tax on an invoice, so it is due when the money
  -- arrives, not when the bill is raised -- which is why the charge only
  -- shows up here once the document is paid.
  v_sc := pg_temp.ss_doc(v_org, 'invoice', 'INV-SC', date '2026-02-05',
                         1000, 'SL10');
  update public.sales_documents set
    service_charge_amount = 100, service_charge_tax = 8,
    service_charge_tax_code_id =
      (select id from public.tax_codes where org_id = v_org and code = 'ST8')
   where id = v_sc;
  select total_amount into v_total
    from public.sales_documents where id = v_sc;
  perform pg_temp.ss_pay(v_org, v_sc, date '2026-02-20', v_total, 'RC-SC');

  perform pg_temp.check_eq('the service charge is declared as service tax',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '02'), 8);
  perform pg_temp.check_eq('on the charge itself, not on the bill',
    (select d.taxable_amount from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '02'), 100);
  perform pg_temp.check_eq('and the goods on it are still sales tax',
    (select d.tax_amount from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '01'), 100);
  perform pg_temp.check_eq('due on the document, which is the other basis',
    (select d.basis from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '01'), 'invoice');
  perform pg_temp.check_eq('while the charge is due on the payment',
    (select d.basis from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '02'), 'payment');

  -- MUTANT: `<> 0` -> `true`. A document with a service charge tax code
  -- and no charge on it -- which is every document raised by a company
  -- that has set a default -- would join the union as a line of nothing,
  -- and worse, as a row in `service` with an anniversary of its own.
  v_no := pg_temp.ss_doc(v_org, 'invoice', 'INV-NC', date '2026-02-06',
                         500, 'SL10');
  update public.sales_documents set
    service_charge_amount = 0, service_charge_tax = 0,
    service_charge_tax_code_id =
      (select id from public.tax_codes where org_id = v_org and code = 'ST8')
   where id = v_no;

  perform pg_temp.check_eq('a document with no charge on it adds nothing',
    (select d.taxable_amount from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '02'), 100);

  -- MUTANT: `having sum(l.tax) <> 0` dropped. An exempt supply carries
  -- service tax's code and no tax at all. Without the guard it becomes a
  -- row in `service`, which means an anniversary, which means the whole
  -- exempt invoice is declared as taxable turnover a year later.
  v_zero := pg_temp.ss_doc(v_org, 'invoice', 'INV-EX', date '2026-02-07',
                           4000, 'ST0');
  perform pg_temp.check_eq('an exempt supply is not put on the clock',
    (select count(*) from app.sst_output_due(
       v_org, date '2027-02-01', date '2027-03-31') d
      where d.basis = 'twelve months'), 0);
  perform pg_temp.check_eq('and the period it was invoiced in is unchanged',
    (select d.taxable_amount from app.sst_output_due(
       v_org, date '2026-02-01', date '2026-03-31') d
      where d.tax_type_code = '02'), 100);

  -- MUTANT: `round(x.net, 2)` and `round(x.tax, 2)` dropped. The payment
  -- basis apportions by `p.amount / s.total`, which is a third of a
  -- ringgit as often as not: a return has to be in sen, because it is
  -- typed into a form that has two decimal places on it.
  v_part := pg_temp.ss_doc(v_org, 'invoice', 'INV-TH', date '2026-04-10',
                           1000, 'ST8');
  perform pg_temp.ss_pay(v_org, v_part, date '2026-04-20', 360, 'RC-TH');
  perform pg_temp.check_eq('a third of an invoice is declared to the sen',
    (select d.taxable_amount::text from app.sst_output_due(
       v_org, date '2026-04-01', date '2026-05-31') d
      where d.basis = 'payment'), '333.33');
  perform pg_temp.check_eq('and its tax likewise',
    (select d.tax_amount::text from app.sst_output_due(
       v_org, date '2026-04-01', date '2026-05-31') d
      where d.basis = 'payment'), '26.67');

  -- MUTANT: `and max(l.total_amount) > 0` dropped from the `having`.
  -- `p.amount / s.total` and `(an.total - an.paid_by_then) / an.total`
  -- both divide by the document total, and an invoice CAN total nothing
  -- while carrying tax: a thousand ringgit of consulting, eighty of
  -- service tax, and a goodwill credit of the whole 1,080 written on the
  -- same document. Subtotal minus eighty, tax eighty, total nought.
  --
  -- Without the guard that is a division by zero, and the whole return
  -- fails rather than one document -- so a company cannot file at all
  -- until somebody works out which invoice did it.
  v_free := pg_temp.ss_doc(v_org, 'invoice', 'INV-FR', date '2026-06-01',
                           1000, 'ST8');
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_free, 2, 'Kredit muhibah', 1, -1080);
  perform pg_temp.check_eq('an invoice totalling nothing really does',
    (select total_amount from public.sales_documents where id = v_free), 0);
  perform pg_temp.check_true('and the return still comes back',
    (select count(*) from app.sst_output_due(
       v_org, date '2026-06-01', date '2026-07-31')) >= 0);
  perform pg_temp.check_true('a year later, when its anniversary falls, too',
    (select count(*) from app.sst_output_due(
       v_org, date '2027-06-01', date '2027-07-31')) >= 0);
  perform pg_temp.check_eq('and it declares nothing, because there is nothing',
    (select count(*) from app.sst_output_due(
       v_org, date '2027-06-01', date '2027-07-31') d
      where d.basis = 'twelve months'), 0);

  raise notice 'ok   the service charge, the exempt supply, and the sen';
end $$;

rollback;
