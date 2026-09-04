-- =====================================================================
-- iAkauntan :: the shapes a standing order comes in
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_shapes.sql
--
-- `recurring_documents.sql` pins the calendar and the stopping rules,
-- and `recurring_template_carries_the_document.sql` pins that every
-- column of both document tables is decided about. Both are good files
-- and a mutation sweep of the ten functions under them still killed
-- only 52 of 105.
--
-- What lived was not the arithmetic. It was everything AROUND the
-- monthly ringgit retainer both files are built on:
--
--   * no schedule in the suite bills in a foreign currency, so the
--     whole rate path -- four branches of it -- was unasserted
--   * no schedule is ever made by somebody who may not post, or edited
--     by them, so five permission checks were open
--   * `create_recurring_document` has six guards and one of them was
--     reached
--   * `app.snapshot_document` raises twice and neither was reached
--   * and the recurring JOURNAL runner, which is a different function
--     from the document one, had its whole `where` clause open
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.rs_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform public.create_fiscal_year(v_org, date '2027-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.rs_customer(
  p_org uuid, p_code text, p_name text, p_email text default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, p_code, p_name, 'customer', p_email)
  returning id into v_id;
  return v_id;
end;
$$;

-- A one-line posted invoice. `p_currency`/`p_rate` are here because the
-- whole point of half this file is that a retainer need not be in
-- ringgit.
create or replace function pg_temp.rs_invoice(
  p_org uuid, p_contact uuid, p_no text, p_date date, p_due date,
  p_amount numeric default 1000,
  p_currency char(3) default 'MYR', p_rate numeric default 1)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status)
  values (p_org, 'invoice', p_no, p_date, p_due, p_contact,
          p_currency, p_rate, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Retainer', 1, p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

create or replace function pg_temp.rs_bill(
  p_org uuid, p_contact uuid, p_no text, p_date date, p_due date,
  p_amount numeric default 1000)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status)
  values (p_org, 'bill', p_no, p_date, p_due, p_contact, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Office rent', 1, p_amount);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

-- The newest document this schedule raised, whichever side it is on.
create or replace function pg_temp.rs_latest_sales(p_org uuid, p_not uuid)
returns public.sales_documents language sql as $$
  select * from public.sales_documents
   where org_id = p_org and id <> p_not
   order by created_at desc, doc_no desc limit 1;
$$;

-- ---------------------------------------------------------------------
-- 1. Where a schedule stops, and what it writes down on the way
-- ---------------------------------------------------------------------
-- `recurring_documents.sql` proves an end date stops a schedule. What
-- it does not fix is WHICH SIDE OF THE END DATE the last invoice falls
-- on, because its end date is not one of the schedule's own run dates.
-- A twelve-month contract that runs on the first and ends on the first
-- is exactly the case where `>` and `>=` disagree, and it is the
-- ordinary way a contract is written.
do $$
declare
  v_org uuid := pg_temp.rs_org('Kontrak Sdn Bhd');
  v_cust uuid; v_seed uuid; v_sched uuid; v_n integer;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-K', 'Setahun Bhd');
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-K',
                               date '2026-01-01', date '2026-01-31');

  -- Three months, ending ON the third run date.
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Three months to March',
    p_frequency => 'monthly', p_start_date => date '2026-01-01',
    p_end_date => date '2026-03-01');

  v_n := public.run_recurring_documents_for(v_org, date '2026-12-31');
  -- The contract runs to the first of March, so March is billed. Ending
  -- it a month early is a month of work given away.
  perform pg_temp.check_eq(
    'a contract ending on a run date still bills that run', v_n, 3);
  perform pg_temp.check_true('and stands due the month after its end',
    (select next_run_date = date '2026-04-01'
       from public.recurring_documents where id = v_sched));
  perform pg_temp.check_eq('and asking again gets nothing',
    public.run_recurring_documents_for(v_org, date '2026-12-31'), 0);
end $$;

-- A scheduler down for three months owes three invoices, and
-- `last_run_date` is the column somebody reads to ask "what has this
-- billed to?". It has to name the PERIOD billed, not the day the
-- catch-up happened -- otherwise every schedule in a recovered run
-- claims to be up to date to today whatever it actually raised.
do $$
declare
  v_org uuid := pg_temp.rs_org('Terlepas Sdn Bhd');
  v_cust uuid; v_seed uuid; v_sched uuid;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-T', 'Tertinggal Bhd');
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-T',
                               date '2026-01-01', date '2026-01-31');
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Monthly, caught up late',
    p_frequency => 'monthly', p_start_date => date '2026-01-01');

  -- Caught up on the 20th of March: January, February and March are
  -- owed, and the last one billed is March the FIRST.
  perform pg_temp.check_eq('three months are owed',
    public.run_recurring_documents_for(v_org, date '2026-03-20'), 3);
  perform pg_temp.check_eq(
    'and the last run is the period billed, not the day of the catch-up',
    (select last_run_date::text from public.recurring_documents
      where id = v_sched), date '2026-03-01'::text);
end $$;

-- The 31st, on the DOCUMENT side. `pricing_and_dimensions.sql` holds
-- this for recurring JOURNALS, which is a different function with its
-- own call to `app.advance_schedule`. `0503` is in the tree precisely
-- because those two calls drifted apart once already -- the nightly job
-- passed the anchor and the button a person presses did not.
do $$
declare
  v_org uuid := pg_temp.rs_org('Hujung Bulan Sdn Bhd');
  v_cust uuid; v_seed uuid; v_sched uuid;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-H', 'Sewa Bhd');
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-H',
                               date '2026-01-31', date '2026-02-28');
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Rent, last day of the month',
    p_frequency => 'monthly', p_start_date => date '2026-01-31');

  perform pg_temp.check_eq('January bills',
    public.run_recurring_documents_for(v_org, date '2026-01-31'), 1);
  perform pg_temp.check_eq('and February has no 31st to offer',
    (select next_run_date::text from public.recurring_documents
      where id = v_sched), date '2026-02-28'::text);
  -- The one that matters. Advanced from the 28th with no anchor this is
  -- the 28th of March, and the 28th of every month for the life of the
  -- tenancy.
  perform pg_temp.check_eq('February bills',
    public.run_recurring_documents_for(v_org, date '2026-02-28'), 1);
  perform pg_temp.check_eq('and March gives the day back',
    (select next_run_date::text from public.recurring_documents
      where id = v_sched), date '2026-03-31'::text);
end $$;

-- A schedule that failed last night and works this morning has to stop
-- saying it failed, and a failure has to be recorded against the
-- schedule that failed rather than against every schedule in the
-- company. Both are one `update` in the same handler.
do $$
declare
  v_org uuid := pg_temp.rs_org('Ralat Sdn Bhd');
  v_cust uuid; v_seed uuid; v_bad uuid; v_good uuid; v_idle uuid; v_per uuid;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-R', 'Dua Jadual Bhd');
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-R',
                               date '2026-01-01', date '2026-01-31');

  v_bad := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'The one that cannot post',
    p_frequency => 'monthly', p_start_date => date '2026-06-01',
    p_auto_post => true);
  v_good := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'The one that can',
    p_frequency => 'monthly', p_start_date => date '2026-06-01');
  -- A third that is not due until next year, so this run never touches
  -- it at all. It is the only schedule whose `last_error` cannot be
  -- explained away: the two above are both visited, and whichever the
  -- loop reaches second would clear or set its own on the way past.
  -- The loop's order is unspecified, so an assertion that depends on it
  -- is a coin toss.
  v_idle := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'The one that is not due',
    p_frequency => 'monthly', p_start_date => date '2027-06-01');

  -- June is shut, so the posting schedule cannot run and the drafting
  -- one can.
  select id into v_per from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-06-01';
  perform public.set_fiscal_period_status(v_per, 'closed');

  perform public.run_recurring_documents_for(v_org, date '2026-06-30');
  perform pg_temp.check_true('the schedule that failed says so',
    (select last_error is not null from public.recurring_documents
      where id = v_bad));
  -- The failure belongs to one schedule. Writing it against the whole
  -- company would put a red mark on every standing order in the
  -- business, including ones that are not due for a year.
  perform pg_temp.check_true(
    'and the schedule beside it is not blamed for it',
    (select last_error is null from public.recurring_documents
      where id = v_good));
  perform pg_temp.check_true(
    'nor is one the run never reached',
    (select last_error is null and last_error_at is null
       from public.recurring_documents where id = v_idle));

  -- Opened again, it runs, and the note it left comes off.
  perform public.set_fiscal_period_status(v_per, 'open');
  perform public.run_recurring_documents_for(v_org, date '2026-06-30');
  perform pg_temp.check_true('and a schedule that recovers stops saying it failed',
    (select last_error is null and last_error_at is null
       from public.recurring_documents where id = v_bad));
end $$;

-- ---------------------------------------------------------------------
-- 2. A retainer billed in dollars
-- ---------------------------------------------------------------------
-- Every schedule in the suite bills in ringgit, so all four branches of
-- the rate path were one number:
--
--     v_currency := coalesce(v_header ->> 'currency', 'MYR');
--     v_rate := case when v_currency = coalesce(v_base, 'MYR') then 1
--                    else app.exchange_rate_for(r.org_id, v_currency, p_on) end;
--
-- With a ringgit template every one of those reads as 1 whether it is
-- computed or hard-coded. A consultancy on a USD5,000 monthly retainer
-- is the ordinary case where they come apart, and the rule the whole
-- thing exists for is that **the invoice is raised at the rate on the
-- day it is raised**, not the rate on the day somebody set the schedule
-- up. A dollar retainer signed in January and still billing in
-- September at January's rate is a running error nobody has to make.
do $$
declare
  v_org  uuid := pg_temp.rs_org('Konsultan Antarabangsa Sdn Bhd');
  v_cust uuid; v_seed uuid; v_sched uuid;
  v_jan  public.sales_documents;
  v_mar  public.sales_documents;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-USD', 'Overseas Client Inc');

  -- The rate moves between the two months this schedule bills.
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.00, date '2026-01-01', 'manual'),
         (v_org, 'USD', 'MYR', 4.60, date '2026-03-01', 'manual');

  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-USD',
                               date '2026-01-01', date '2026-01-31',
                               5000, 'USD', 4.00);
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'USD retainer',
    p_frequency   => 'monthly', p_start_date => date '2026-01-01');

  -- January, at January's rate.
  perform pg_temp.check_eq('the dollar retainer bills in January',
    public.run_recurring_documents_for(v_org, date '2026-01-31'), 1);
  v_jan := pg_temp.rs_latest_sales(v_org, v_seed);
  perform pg_temp.check_eq('in dollars, not in ringgit',
    v_jan.currency::text, 'USD');
  perform pg_temp.check_eq('for five thousand of them',
    v_jan.total_amount, 5000);
  perform pg_temp.check_eq('at four ringgit to the dollar',
    v_jan.exchange_rate, 4.00);
  perform pg_temp.check_eq('which is RM20,000 in the books',
    v_jan.base_total_amount, 20000);

  -- March, at March's. Same schedule, same template, different rate --
  -- and RM3,000 more of revenue, which is the whole point.
  perform pg_temp.check_eq('and again in February and March',
    public.run_recurring_documents_for(v_org, date '2026-03-31'), 2);
  v_mar := pg_temp.rs_latest_sales(v_org, v_seed);
  perform pg_temp.check_eq('March takes the rate on the day it is raised',
    v_mar.exchange_rate, 4.60);
  perform pg_temp.check_eq('and is worth RM23,000, not January''s RM20,000',
    v_mar.base_total_amount, 23000);
  perform pg_temp.check_eq('while the dollars asked for did not move',
    v_mar.total_amount, 5000);

  raise notice 'a dollar retainer: two months, two rates, one template';
end $$;

-- The other side of the same `case`: a ringgit schedule in a ringgit
-- company must be left at a rate of one WITHOUT consulting the rate
-- table, because there is no MYR->MYR row in it and asking would fail.
-- That is what the base-currency arm is for, and a company whose base
-- currency is not ringgit is what tells it from a hard-coded 'MYR'.
do $$
declare
  v_org  uuid := pg_temp.rs_org('Singapura Holdings Pte Ltd');
  v_cust uuid; v_seed uuid; v_sched uuid; v_doc public.sales_documents;
begin
  update public.organizations set base_currency = 'SGD' where id = v_org;
  v_cust := pg_temp.rs_customer(v_org, 'C-SGD', 'Local Client Pte Ltd');

  -- Note what is NOT here: no SGD -> SGD rate, because none exists.
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-SGD',
                               date '2026-01-01', date '2026-01-31',
                               2000, 'SGD', 1);
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'SGD retainer',
    p_frequency   => 'monthly', p_start_date => date '2026-02-01');

  -- A hard-coded 'MYR' in the base-currency test sends this down the
  -- lookup arm for a rate that is not there.
  perform pg_temp.check_eq(
    'a company that does not keep its books in ringgit still bills',
    public.run_recurring_documents_for(v_org, date '2026-02-28'), 1);
  v_doc := pg_temp.rs_latest_sales(v_org, v_seed);
  perform pg_temp.check_eq('its own currency is its base currency',
    v_doc.currency::text, 'SGD');
  perform pg_temp.check_eq('so the rate is one, without a lookup',
    v_doc.exchange_rate, 1);
end $$;

-- ---------------------------------------------------------------------
-- 3. A retainer is emailed every month, not once
-- ---------------------------------------------------------------------
-- `email_outbox` is UNIQUE on `(org_id, dedupe_key)`, and
-- `queue_document_email` treats a collision as "already queued, nothing
-- wrong" and returns null. So the key the raise passes decides whether
-- a standing order mails its customer every month or exactly once in
-- its life:
--
--     perform app.queue_document_email(
--       v_doc, 'document_new', 'recurring:' || v_doc::text);
--
-- Keyed on the DOCUMENT it just raised, every month is a new key.
-- Keyed on the SCHEDULE, February collides with January and is
-- swallowed silently -- no error, no outbox row, and a customer who
-- stops being billed by email while the invoices keep being raised.
-- The existing assertion runs one month, where the two are the same.
do $$
declare
  v_org uuid := pg_temp.rs_org('Hantar Bulanan Sdn Bhd');
  v_cust uuid; v_seed uuid;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-E', 'Emailed Bhd', 'ap@emailed.example');
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-E',
                               date '2026-01-01', date '2026-01-31');
  insert into public.email_settings (org_id, is_enabled, from_name)
  values (v_org, true, 'Hantar Bulanan');

  perform public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Monthly, emailed',
    p_frequency => 'monthly', p_start_date => date '2026-02-01',
    p_auto_post => true, p_auto_email => true);

  perform pg_temp.check_eq('February and March are both raised',
    public.run_recurring_documents_for(v_org, date '2026-03-01'), 2);
  -- Two invoices, two messages. One message means the second month was
  -- deduplicated against the first.
  perform pg_temp.check_eq('and both are emailed, not just the first',
    (select count(*)::integer from public.email_outbox where org_id = v_org), 2);
  perform pg_temp.check_eq('each against its own invoice',
    (select count(distinct document_id)::integer
       from public.email_outbox where org_id = v_org), 2);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- 4. What the header carries besides the money
-- ---------------------------------------------------------------------
-- `recurring_template_carries_the_document.sql` proves every column is
-- decided about and pins the branch, the matter and the service charge.
-- Four more are snapshotted and replayed and had nothing on them: who
-- the sale is credited to, the discount the customer negotiated, and on
-- the buying side self-billing and the custom fields.
do $$
declare
  v_org  uuid := pg_temp.rs_org('Lajur Lain Sdn Bhd');
  v_cust uuid; v_sup uuid; v_seed uuid; v_bill uuid; v_person uuid;
  v_doc public.sales_documents;
  v_raised public.purchase_documents;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-L', 'Diskaun Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-L', 'Pembekal Bhd', 'supplier') returning id into v_sup;

  -- Somebody the commission belongs to.
  insert into public.salespeople (org_id, code, name, commission_rate)
  values (v_org, 'SP-1', 'Salmah binti Osman', 2.5)
  returning id into v_person;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, salesperson_id, discount_percent)
  values (v_org, 'invoice', 'INV-L', date '2026-01-01', date '2026-01-31',
          v_cust, 'MYR', 1, 'draft', v_person, 10)
  returning id into v_seed;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_seed, 1, 'Retainer', 1, 1000);
  perform public.post_sales_document(v_seed);

  perform public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Retainer, discounted',
    p_frequency => 'monthly', p_start_date => date '2026-02-01');
  perform public.run_recurring_documents_for(v_org, date '2026-02-01');
  v_doc := pg_temp.rs_latest_sales(v_org, v_seed);

  -- A schedule that forgets the salesperson quietly stops paying
  -- somebody their commission on an account they still service.
  perform pg_temp.check_true('the sale is still credited to whoever won it',
    v_doc.salesperson_id = v_person);
  -- And one that forgets the discount bills the customer the list price
  -- they did not agree to.
  perform pg_temp.check_eq('the discount the customer negotiated survives',
    v_doc.discount_percent, 10);
  perform pg_temp.check_eq('so the invoice is RM900, not RM1,000',
    v_doc.total_amount, 900);

  -- --- the buying side ------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, requires_self_billed, custom_fields)
  values (v_org, 'bill', 'BILL-L', date '2026-01-01', date '2026-01-31',
          v_sup, 'MYR', 1, 'draft', true,
          jsonb_build_object('cost_centre', 'KL-HQ'))
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 1, 'Foreign licence fee', 1, 2000);
  perform public.post_purchase_document(v_bill);

  perform public.create_recurring_document(
    p_document_id => v_bill, p_name => 'Licence, self-billed',
    p_frequency => 'monthly', p_start_date => date '2026-02-01');
  perform public.run_recurring_documents_for(v_org, date '2026-02-01');

  select * into v_raised from public.purchase_documents
   where org_id = v_org and id <> v_bill
   order by created_at desc limit 1;

  -- A self-billed e-Invoice is one WE issue on the supplier's behalf,
  -- which is what a payment to a foreign supplier needs under LHDN's
  -- rules. A schedule that drops the flag raises a bill nobody submits.
  perform pg_temp.check_true('a self-billed standing order stays self-billed',
    v_raised.requires_self_billed);
  perform pg_temp.check_eq('and the cost centre comes with it',
    v_raised.custom_fields ->> 'cost_centre', 'KL-HQ');
end $$;

-- ---------------------------------------------------------------------
-- 5. What may be turned into a standing order, and by whom
-- ---------------------------------------------------------------------
-- `create_recurring_document` has six guards. One of them -- "only an
-- invoice or a bill" -- was reached, by a quotation. The other five had
-- nothing on them, including both permission checks.
do $$
declare
  v_org   uuid := pg_temp.rs_org('Penjaga Sdn Bhd');
  v_cust  uuid; v_seed uuid; v_quote uuid; v_po uuid; v_deleted uuid;
  v_bill  uuid; v_viewer uuid; v_sched uuid;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-P', 'Pelanggan Bhd');
  v_seed := pg_temp.rs_invoice(v_org, v_cust, 'INV-P',
                               date '2026-01-01', date '2026-01-31');
  v_bill := pg_temp.rs_bill(v_org, v_cust, 'BILL-P',
                            date '2026-01-01', date '2026-01-15');

  -- A quotation is not a thing that repeats, and neither is a purchase
  -- order. Both live in the same tables as the documents that do, and
  -- the doc_type filter is the only thing between them.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'quotation', 'QUO-P', date '2026-01-01', v_cust,
          'MYR', 1, 'draft') returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_quote, 1, 'Proposal', 1, 500);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_order', 'PO-P', date '2026-01-01', v_cust,
          'MYR', 1, 'draft') returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_po, 1, 'Order', 1, 500);

  perform pg_temp.check_refused('a quotation cannot be made to repeat',
    format($q$ select public.create_recurring_document(%L, 'Q', 'monthly',
                        date '2026-02-01') $q$, v_quote),
    '%Only an invoice or a bill%', '22023');
  perform pg_temp.check_refused('and neither can a purchase order',
    format($q$ select public.create_recurring_document(%L, 'PO', 'monthly',
                        date '2026-02-01') $q$, v_po),
    '%Only an invoice or a bill%', '22023');

  -- A deleted invoice is not a template. Somebody who deletes an
  -- invoice and then makes it recurring would get a schedule billing
  -- from a document nobody can look at.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, deleted_at)
  values (v_org, 'invoice', 'INV-GONE', date '2026-01-01', v_cust,
          'MYR', 1, 'draft', now()) returning id into v_deleted;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_deleted, 1, 'Gone', 1, 100);
  perform pg_temp.check_refused('a deleted invoice cannot be made to repeat',
    format($q$ select public.create_recurring_document(%L, 'Gone', 'monthly',
                        date '2026-02-01') $q$, v_deleted),
    '%Only an invoice or a bill%', '22023');

  -- A schedule with no name is a row in a list nobody can identify,
  -- and a name of spaces is the same thing typed differently.
  perform pg_temp.check_refused('a schedule needs a name',
    format($q$ select public.create_recurring_document(%L, '', 'monthly',
                        date '2026-02-01') $q$, v_seed),
    '%needs a name%', '22023');
  perform pg_temp.check_refused('and spaces are not a name',
    format($q$ select public.create_recurring_document(%L, '   ', 'monthly',
                        date '2026-02-01') $q$, v_seed),
    '%needs a name%', '22023');

  -- An end date before the start is a schedule that can never run, and
  -- saying so now beats a template that sits inactive for ever.
  perform pg_temp.check_refused('and it cannot end before it starts',
    format($q$ select public.create_recurring_document(%L, 'Backwards',
                        'monthly', date '2026-06-01', 1, date '2026-05-01') $q$,
           v_seed),
    '%end date is before the start date%', '22023');

  -- Ending on the day it starts is a one-off, which is legitimate: a
  -- single instalment agreed for one date only.
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'One instalment only',
    p_frequency => 'monthly', p_start_date => date '2026-06-01',
    p_end_date => date '2026-06-01');
  perform pg_temp.check_eq('but a schedule may start and end on one day',
    public.run_recurring_documents_for(v_org, date '2026-12-31'), 1);

  -- The name is stored trimmed, so the list sorts on the word rather
  -- than on the space in front of it.
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => '  Padded name  ',
    p_frequency => 'monthly', p_start_date => date '2027-01-01');
  perform pg_temp.check_eq('a name keeps its words and loses its padding',
    (select name from public.recurring_documents where id = v_sched),
    'Padded name');

  -- A schedule is not posted by default. Turning auto_post on is a
  -- decision, and defaulting it the other way would have every schedule
  -- in the platform posting to the ledger unattended.
  --
  -- Passed EXPLICITLY as null, which is the only way to reach the
  -- coalesce: the parameter's own SQL default is already false, so
  -- omitting it tests the signature rather than the body. A client that
  -- sends `"p_auto_post": null` -- which is what an unset checkbox
  -- serialises to -- is the caller that gets here.
  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Nulls for the flags',
    p_frequency => 'monthly', p_start_date => date '2027-01-01',
    p_auto_post => null, p_auto_email => null);
  perform pg_temp.check_true('a new schedule does not post unless asked',
    (select not auto_post and not auto_email
       from public.recurring_documents where id = v_sched));

  -- The first run is the start date itself, not the day after.
  perform pg_temp.check_eq('and it is first due on the day it starts',
    (select next_run_date::text from public.recurring_documents
      where id = v_sched), date '2027-01-01'::text);

  -- --- and by whom ----------------------------------------------------
  -- A viewer may read the schedules and must not make one, edit one, or
  -- drive a run: each of those raises documents in the ledger.
  v_viewer := pg_temp.another_user('viewer.penjaga@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_viewer, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  perform pg_temp.sign_in_as(v_viewer);

  perform pg_temp.check_refused('a viewer may not create a schedule',
    format($q$ select public.create_recurring_document(%L, 'Sneaky', 'monthly',
                        date '2026-02-01') $q$, v_seed),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused('nor re-point one at another document',
    format($q$ select public.update_recurring_template(%L, %L) $q$,
           v_sched, v_seed),
    '%Insufficient privileges%', '42501');
  perform pg_temp.check_refused('nor drive the document run',
    format($q$ select public.run_recurring_documents_for(%L, date '2026-12-31') $q$,
           v_org),
    '%Insufficient privileges to post%', '42501');
  perform pg_temp.check_refused('nor the journal run',
    format($q$ select public.run_recurring_journals_for(%L, date '2026-12-31') $q$,
           v_org),
    '%Insufficient privileges to post%', '42501');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- 6. Re-pointing a schedule at a newer document
-- ---------------------------------------------------------------------
-- `recurring_documents.sql` proves a re-point bills the new price and
-- that editing the document afterwards does not. What it does not reach
-- is any of the four refusals, the contact refresh, or the `where`
-- clause on the update itself.
do $$
declare
  v_org   uuid := pg_temp.rs_org('Tukar Templat Sdn Bhd');
  v_other uuid := pg_temp.rs_org('Syarikat Lain Sdn Bhd');
  v_a uuid; v_b uuid; v_far uuid;
  v_seed uuid; v_newer uuid; v_foreign uuid; v_bill uuid;
  v_sched uuid; v_untouched uuid; v_doc public.sales_documents;
begin
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.rs_customer(v_org, 'C-A', 'Pelanggan A');
  v_b := pg_temp.rs_customer(v_org, 'C-B', 'Pelanggan B');
  v_far := pg_temp.rs_customer(v_other, 'C-F', 'Pelanggan Jauh');

  v_seed  := pg_temp.rs_invoice(v_org, v_a, 'INV-A',
                                date '2026-01-01', date '2026-01-31', 1000);
  -- The newer document is for a DIFFERENT customer. A practice that
  -- moves a retainer from one company in a group to another does
  -- exactly this, and a re-point that keeps the old contact goes on
  -- billing whoever it billed before.
  v_newer := pg_temp.rs_invoice(v_org, v_b, 'INV-B',
                                date '2026-02-01', date '2026-02-28', 1500);
  v_foreign := pg_temp.rs_invoice(v_other, v_far, 'INV-F',
                                  date '2026-01-01', date '2026-01-31', 9999);
  v_bill := pg_temp.rs_bill(v_org, v_a, 'BILL-A',
                            date '2026-01-01', date '2026-01-15');

  v_sched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Retainer',
    p_frequency => 'monthly', p_start_date => date '2026-03-01');
  -- A second schedule that must not move when the first one does.
  v_untouched := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'A different retainer',
    p_frequency => 'monthly', p_start_date => date '2026-03-01');

  perform pg_temp.check_refused('a schedule that is not there is not edited',
    format($q$ select public.update_recurring_template(%L, %L) $q$,
           gen_random_uuid(), v_newer),
    '%Schedule not found%', 'P0002');
  perform pg_temp.check_refused('nor is one pointed at a document that is not there',
    format($q$ select public.update_recurring_template(%L, %L) $q$,
           v_sched, gen_random_uuid()),
    '%to copy from%', '22023');
  -- A sales schedule looks in `sales_documents`, so a bill's id finds
  -- nothing rather than silently copying a purchase template into a
  -- sales schedule.
  perform pg_temp.check_refused('a sales schedule will not take a bill',
    format($q$ select public.update_recurring_template(%L, %L) $q$,
           v_sched, v_bill),
    '%to copy from%', '22023');
  -- The one that would be a leak rather than a mistake: another
  -- company's prices copied into this company's billing.
  perform pg_temp.check_refused(
    'and a document belonging to another company is refused',
    format($q$ select public.update_recurring_template(%L, %L) $q$,
           v_sched, v_foreign),
    '%belongs to another organization%', '42501');

  -- The good path: the template AND the customer both move.
  perform public.update_recurring_template(v_sched, v_newer);
  perform pg_temp.check_true('a re-point moves the schedule to the new customer',
    (select contact_id = v_b from public.recurring_documents where id = v_sched));
  -- And the schedule beside it is left exactly where it was. An update
  -- scoped to the company rather than the row would have rewritten
  -- every standing order in the business at once.
  perform pg_temp.check_true('and leaves every other schedule alone',
    (select contact_id = v_a from public.recurring_documents
      where id = v_untouched));

  perform public.run_recurring_documents_for(v_org, date '2026-03-01');
  select * into v_doc from public.sales_documents
   where org_id = v_org and doc_date = date '2026-03-01'
     and contact_id = v_b limit 1;
  perform pg_temp.check_eq('and the invoice it raises is for the new customer',
    v_doc.total_amount, 1500);
end $$;

-- ---------------------------------------------------------------------
-- 7. The gap the customer was given last time
-- ---------------------------------------------------------------------
-- `payment_terms_days` is taken from the seed document rather than
-- typed:
--
--     greatest(coalesce(v_due - v_doc_date, 30), 0)
--
-- Two of those three pieces are load-bearing and the third is not, and
-- the third is worth writing down because it looks like the most
-- important one.
do $$
declare
  v_org uuid := pg_temp.rs_org('Tempoh Sdn Bhd');
  v_cust uuid; v_none uuid; v_sched uuid; v_probe uuid;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-TM', 'Lambat Bhd');

  -- THE FLOOR AT NOUGHT CANNOT BE REACHED, and that is a fact about
  -- somewhere else. `payment_terms_days` is CHECKed at nought or more,
  -- so a negative gap would refuse the whole schedule -- but a negative
  -- gap needs a document due before it was raised, and `0385` put a
  -- trigger on both document tables refusing exactly that. The floor is
  -- defensive against a state the database will not hold. So the
  -- assertion is of the rule it leans on, not of the dead branch.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-PROBE', date '2026-03-01', date '2026-03-31',
          v_cust, 'MYR', 1, 'draft') returning id into v_probe;
  perform pg_temp.check_refused(
    'a document cannot fall due before it was raised',
    format($q$ update public.sales_documents set due_date = date '2026-02-26'
                where id = %L $q$, v_probe),
    '%cannot fall due before it was raised%');

  -- No due date at all is a different matter and is perfectly ordinary:
  -- the column is nullable and a draft typed in a hurry has none. Thirty
  -- days is the fallback, and without it the schedule would raise every
  -- invoice due on the day it was raised -- overdue the moment it is
  -- sent.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-NODUE', date '2026-03-01', null, v_cust,
          'MYR', 1, 'draft') returning id into v_none;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_none, 1, 'Retainer', 1, 1000);
  perform public.post_sales_document(v_none);

  v_sched := public.create_recurring_document(
    p_document_id => v_none, p_name => 'From no due date at all',
    p_frequency => 'monthly', p_start_date => date '2026-04-01');
  perform pg_temp.check_eq('no due date at all falls back to thirty days',
    (select payment_terms_days from public.recurring_documents
      where id = v_sched), 30);

  perform public.run_recurring_documents_for(v_org, date '2026-04-01');
  perform pg_temp.check_true('so the invoice it raises is due in May',
    exists (select 1 from public.sales_documents
             where org_id = v_org and doc_date = date '2026-04-01'
               and due_date = date '2026-05-01'));

  -- An interval of nothing at all is a schedule that never moves and is
  -- therefore due for ever. The floor at one is what stops it, and the
  -- CHECK on the column would refuse the row without it.
  v_sched := public.create_recurring_document(
    p_document_id => v_none, p_name => 'No interval given',
    p_frequency => 'monthly', p_start_date => date '2026-04-01',
    p_interval_count => null);
  perform pg_temp.check_eq('an interval of nothing is an interval of one',
    (select interval_count from public.recurring_documents
      where id = v_sched), 1);
end $$;

-- ---------------------------------------------------------------------
-- 8. The standing journal, which is a different function
-- ---------------------------------------------------------------------
-- Recurring journals and recurring documents are two runners with two
-- `where` clauses, and the journal one had almost nothing on it. Its
-- four conditions -- active, has a next run, is due, is not past its
-- end -- were one condition's worth of coverage between them.
--
-- And the entry date is the one that would be silent. The journal is
-- posted on `r.next_run_date`, the day it was DUE, not `p_on`, the day
-- the job happened to run. A month-end accrual run on the 3rd is an
-- accrual for the month that ended, and posting it on the 3rd puts it
-- in the wrong period and the wrong profit and loss account balance.
do $$
declare
  v_org uuid := pg_temp.rs_org('Jurnal Tetap Sdn Bhd');
  v_exp uuid; v_ap uuid; v_rj uuid; v_off uuid; v_ended uuid; v_nodate uuid;
  v_tpl jsonb;
begin
  select id into v_exp from public.accounts
   where org_id = v_org and code = '6100' order by code limit 1;
  select id into v_ap from public.accounts
   where org_id = v_org and code = '2110' order by code limit 1;
  v_tpl := jsonb_build_object('lines', jsonb_build_array(
    jsonb_build_object('account_id', v_exp, 'debit', 1200, 'credit', 0),
    jsonb_build_object('account_id', v_ap,  'debit', 0, 'credit', 1200)));

  -- Due on the last day of January; the job does not get to it until
  -- the third of February.
  insert into public.recurring_journals
    (org_id, name, description, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Month-end accrual', 'Accrued utilities', 'monthly', 1,
          date '2026-01-31', date '2026-01-31', true, true, v_tpl)
  returning id into v_rj;

  -- Switched off. Nothing else about it says not to run.
  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Switched off', 'monthly', 1, date '2026-01-01',
          date '2026-01-01', true, false, v_tpl)
  returning id into v_off;

  -- Past its end date, but still standing due: an accrual that ran to
  -- the end of a lease.
  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date, end_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Lease that ended', 'monthly', 1, date '2025-01-01',
          date '2025-12-31', date '2026-01-01', true, true, v_tpl)
  returning id into v_ended;

  perform pg_temp.check_eq('only the one that is due, active and unexpired runs',
    public.run_recurring_journals_for(v_org, date '2026-02-03'), 1);

  -- THE DATE. Posted for the day it was due, not the day the job ran.
  perform pg_temp.check_true(
    'the accrual is dated the month it accrues, not the day the job ran',
    exists (select 1 from public.gl_entries
             where org_id = v_org and source_id = v_rj
               and entry_date = date '2026-01-31'));
  perform pg_temp.check_eq('and nothing is dated the day of the run',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and entry_date = date '2026-02-03'), 0);

  -- The description is what somebody reads in the ledger. Falling back
  -- to the schedule's name when there is none beats a blank line.
  perform pg_temp.check_eq('it carries its own description',
    (select description from public.gl_entries
      where org_id = v_org and source_id = v_rj limit 1),
    'Accrued utilities');

  perform pg_temp.check_true('the switched-off one did not run',
    (select last_run_date is null from public.recurring_journals where id = v_off));
  perform pg_temp.check_true('and neither did the one past its end date',
    (select last_run_date is null from public.recurring_journals where id = v_ended));

  -- A journal with no description falls back to its name.
  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Depreciation top-up', 'monthly', 1, date '2026-03-01',
          date '2026-03-01', true, true, v_tpl)
  returning id into v_nodate;
  perform public.run_recurring_journals_for(v_org, date '2026-03-01');
  perform pg_temp.check_eq('and one with no description is named after its schedule',
    (select description from public.gl_entries
      where org_id = v_org and source_id = v_nodate limit 1),
    'Depreciation top-up');
end $$;

-- One company's run must not reach into another's ledger. The nightly
-- job sweeps every organization on purpose; the button a person presses
-- takes an organization id and has to honour it.
do $$
declare
  v_a uuid := pg_temp.rs_org('Jurnal A Sdn Bhd');
  v_b uuid := pg_temp.rs_org('Jurnal B Sdn Bhd');
  v_exp uuid; v_ap uuid; v_rj uuid;
begin
  perform pg_temp.allow_many_companies();
  select id into v_exp from public.accounts
   where org_id = v_b and code = '6100' order by code limit 1;
  select id into v_ap from public.accounts
   where org_id = v_b and code = '2110' order by code limit 1;

  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_b, 'B''s rent', 'monthly', 1, date '2026-01-01',
          date '2026-01-01', true, true,
          jsonb_build_object('lines', jsonb_build_array(
            jsonb_build_object('account_id', v_exp, 'debit', 900, 'credit', 0),
            jsonb_build_object('account_id', v_ap,  'debit', 0, 'credit', 900))))
  returning id into v_rj;

  perform pg_temp.check_eq(
    'running company A''s journals does not run company B''s',
    public.run_recurring_journals_for(v_a, date '2026-01-31'), 0);
  perform pg_temp.check_true('and B''s journal is still waiting',
    (select last_run_date is null from public.recurring_journals where id = v_rj));
  perform pg_temp.check_eq('until B is asked',
    public.run_recurring_journals_for(v_b, date '2026-01-31'), 1);
end $$;

-- ---------------------------------------------------------------------
-- 8b. The standing journal on the run nobody is watching
-- ---------------------------------------------------------------------
-- `app.run_recurring_journals` and `public.run_recurring_journals_for`
-- are the same body written twice -- the same four conditions, the same
-- posting call, the same advance -- and the block above exercises only
-- the second. That is the wrong way round, for the same reason
-- `recurring_documents.sql` gives about the document pair: the per-org
-- one is pressed by somebody looking at the result, and the global one
-- runs unattended at night across every tenant on the platform.
--
-- Measured: with only the per-org assertions above, every one of the
-- global runner's four conditions could be deleted and nothing in the
-- suite noticed, including the entry date.
--
-- The count it returns is the whole platform's, and the blocks above
-- leave journals standing due in other companies, so everything here is
-- counted against this company's own ledger.
do $$
declare
  v_org uuid := pg_temp.rs_org('Jurnal Malam Sdn Bhd');
  v_exp uuid; v_ap uuid; v_tpl jsonb;
  v_due uuid; v_off uuid; v_ended uuid; v_later uuid; v_named uuid;
begin
  select id into v_exp from public.accounts
   where org_id = v_org and code = '6100' order by code limit 1;
  select id into v_ap from public.accounts
   where org_id = v_org and code = '2110' order by code limit 1;
  v_tpl := jsonb_build_object('lines', jsonb_build_array(
    jsonb_build_object('account_id', v_exp, 'debit', 700, 'credit', 0),
    jsonb_build_object('account_id', v_ap,  'debit', 0, 'credit', 700)));

  -- Due on the last day of January, and the job does not reach it until
  -- the third of February.
  insert into public.recurring_journals
    (org_id, name, description, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Nightly accrual', 'Accrued electricity', 'monthly', 1,
          date '2026-01-31', date '2026-01-31', true, true, v_tpl)
  returning id into v_due;

  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Nightly, switched off', 'monthly', 1, date '2026-01-01',
          date '2026-01-01', true, false, v_tpl)
  returning id into v_off;

  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date, end_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Nightly, lease ended', 'monthly', 1, date '2025-01-01',
          date '2025-12-31', date '2026-01-01', true, true, v_tpl)
  returning id into v_ended;

  -- Due in March. The sweep is run to February, so it must be left.
  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Nightly, not yet due', 'monthly', 1, date '2026-03-01',
          date '2026-03-01', true, true, v_tpl)
  returning id into v_later;

  -- No description, so the ledger line falls back to the name.
  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date,
     next_run_date, auto_post, is_active, template)
  values (v_org, 'Nightly amortisation', 'monthly', 1, date '2026-01-31',
          date '2026-01-31', true, true, v_tpl)
  returning id into v_named;

  perform app.run_recurring_journals(date '2026-02-03');

  -- Two of the five, and only two.
  perform pg_temp.check_eq(
    'the nightly sweep posts the due, active, unexpired journals and no others',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and source = 'recurring'), 2);
  perform pg_temp.check_true('the one that was switched off did not run',
    (select last_run_date is null from public.recurring_journals where id = v_off));
  perform pg_temp.check_true('nor did the one past its end date',
    (select last_run_date is null from public.recurring_journals where id = v_ended));
  perform pg_temp.check_true('nor the one that is not due until March',
    (select last_run_date is null from public.recurring_journals where id = v_later));

  -- The date. A January accrual swept up on the third of February is
  -- still a January accrual; dated the day of the sweep it lands in the
  -- wrong period and the wrong month's profit and loss.
  perform pg_temp.check_true(
    'and dates them the day they fell due, not the night of the sweep',
    (select bool_and(entry_date = date '2026-01-31')
       from public.gl_entries
      where org_id = v_org and source = 'recurring'));

  perform pg_temp.check_eq('each carrying its own description',
    (select description from public.gl_entries
      where org_id = v_org and source_id = v_due), 'Accrued electricity');
  perform pg_temp.check_eq('and one with none named after its schedule',
    (select description from public.gl_entries
      where org_id = v_org and source_id = v_named), 'Nightly amortisation');

  -- And both moved on by a month, keeping the last day of the month.
  perform pg_temp.check_eq('the schedule that ran moved on',
    (select next_run_date::text from public.recurring_journals
      where id = v_due), date '2026-02-28'::text);
end $$;

-- ---------------------------------------------------------------------
-- 9. What a snapshot refuses, and the order it keeps
-- ---------------------------------------------------------------------
-- `app.snapshot_document` raises twice and neither was reached, because
-- every caller in the suite hands it a real document with lines on it.
-- Both are worth having: without them a schedule is created with a
-- template of `{"header": null, "lines": null}` and fails every night
-- for ever, saying so only in a column.
do $$
declare
  v_org uuid := pg_temp.rs_org('Petikan Sdn Bhd');
  v_cust uuid; v_empty uuid; v_doc uuid; v_bill uuid;
  v_lines jsonb;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-S', 'Petik Bhd');

  perform pg_temp.check_refused('a document that is not there cannot be frozen',
    format($q$ select app.snapshot_document(%L, 'sales') $q$, gen_random_uuid()),
    '%not found%', 'P0002');

  -- A header with no lines. The document exists; there is simply
  -- nothing on it to bill.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-EMPTY', date '2026-01-01', date '2026-01-31',
          v_cust, 'MYR', 1, 'draft') returning id into v_empty;
  perform pg_temp.check_refused('and a document with no lines is not a template',
    format($q$ select app.snapshot_document(%L, 'sales') $q$, v_empty),
    '%needs a document with lines%', '22023');
  perform pg_temp.check_refused('which is what stops the schedule being made',
    format($q$ select public.create_recurring_document(%L, 'Empty', 'monthly',
                        date '2026-02-01') $q$, v_empty),
    '%needs a document with lines%', '22023');

  -- --- the order the lines come back in -------------------------------
  -- A quotation reads top to bottom and the invoice raised from it has
  -- to read the same way. `jsonb_agg` has no order of its own, so
  -- without the `order by` the lines come back in whatever order the
  -- heap hands them over -- which is stable enough to look right in a
  -- test and is not a guarantee.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-ORD', date '2026-01-01', date '2026-01-31',
          v_cust, 'MYR', 1, 'draft') returning id into v_doc;
  -- Inserted out of order on purpose.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_doc, 3, 'Third', 1, 30),
         (v_org, v_doc, 1, 'First', 1, 10),
         (v_org, v_doc, 2, 'Second', 1, 20);

  v_lines := app.snapshot_document(v_doc, 'sales') -> 'lines';
  perform pg_temp.check_eq('the snapshot keeps the document''s own line order',
    concat_ws(',', v_lines -> 0 ->> 'description',
                   v_lines -> 1 ->> 'description',
                   v_lines -> 2 ->> 'description'),
    'First,Second,Third');
  -- And the raise numbers them 1..n itself, so the order in the
  -- template is the order on next month's invoice.
  perform public.create_recurring_document(
    p_document_id => v_doc, p_name => 'Three lines',
    p_frequency => 'monthly', p_start_date => date '2026-02-01');
  perform public.run_recurring_documents_for(v_org, date '2026-02-01');
  perform pg_temp.check_eq('and the invoice it raises reads the same way',
    (select string_agg(l.description, ',' order by l.line_no)
       from public.sales_document_lines l
       join public.sales_documents d on d.id = l.document_id
      where d.org_id = v_org and d.doc_date = date '2026-02-01'),
    'First,Second,Third');

  -- The same on the buying side, which is a separate query.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-ORD', date '2026-01-01', date '2026-01-31',
          v_cust, 'MYR', 1, 'draft') returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 2, 'Second', 1, 20),
         (v_org, v_bill, 1, 'First', 1, 10);
  v_lines := app.snapshot_document(v_bill, 'purchase') -> 'lines';
  perform pg_temp.check_eq('and so does a bill''s',
    concat_ws(',', v_lines -> 0 ->> 'description',
                   v_lines -> 1 ->> 'description'),
    'First,Second');

  -- The line's own id is dropped, so every raise gets fresh rows. Kept,
  -- the second month collides with the first on the primary key and the
  -- schedule fails for ever after its first run. Asserted on BOTH
  -- snapshots, because the two arms are separate queries and `v_lines`
  -- above holds only the purchase one.
  perform pg_temp.check_true('a bill''s lines carry no old identity',
    not (v_lines -> 0 ? 'id') and not (v_lines -> 0 ? 'document_id'));
  v_lines := app.snapshot_document(v_doc, 'sales') -> 'lines';
  perform pg_temp.check_true('and neither do an invoice''s',
    not (v_lines -> 0 ? 'id') and not (v_lines -> 0 ? 'document_id')
      and not (v_lines -> 0 ? 'org_id'));
end $$;

-- =====================================================================
-- 10. The survivors that are equivalent, and the rules they lean on
-- =====================================================================
-- Five mutants live on and are equivalent rather than untested. Four of
-- them are equivalent because of a rule enforced SOMEWHERE ELSE, and
-- the standard answer -- now the ninth time this campaign has reached
-- for it -- is to assert the rule instead of the dead branch.
do $$
declare
  v_org  uuid := pg_temp.rs_org('Setara Sdn Bhd');
  v_cust uuid; v_seed uuid; v_bill uuid; v_notnull text;
begin
  v_cust := pg_temp.rs_customer(v_org, 'C-EQ', 'Setara Bhd', 'ap@setara.example');

  -- (a) `coalesce(o.status, 'active')` in the nightly sweep guards
  -- against a null the column cannot hold: `organizations.status` is
  -- NOT NULL and defaults to 'active'. Drop the coalesce and every
  -- company still bills, because none of them has a null status and
  -- none can be given one.
  select is_nullable into v_notnull from information_schema.columns
   where table_schema = 'public' and table_name = 'organizations'
     and column_name = 'status';
  perform pg_temp.check_eq(
    'a company always has a status, so the sweep''s coalesce is a belt',
    v_notnull, 'NO');
  perform pg_temp.check_refused('and it cannot be taken away',
    format($q$ update public.organizations set status = null where id = %L $q$,
           v_org),
    '%status%');

  -- (b) `r.kind = 'sales'` in the auto-email test looks load-bearing
  -- and is not, because `app.queue_document_email` is sales-only: it
  -- reads `sales_documents` by the id it is given and returns null when
  -- there is nothing there. A bill's id is never in that table, so a
  -- schedule for a BILL cannot mail a supplier even with the kind check
  -- removed. That is the rule, and it is the one worth pinning: the
  -- queue refuses a document that is not a sales document, quietly,
  -- rather than queueing a message about a bill.
  insert into public.email_settings (org_id, is_enabled, from_name)
  values (v_org, true, 'Setara');
  v_bill := pg_temp.rs_bill(v_org, v_cust, 'BILL-EQ',
                            date '2026-01-01', date '2026-01-15');
  perform pg_temp.check_true('a bill cannot be queued as a sales email',
    app.queue_document_email(v_bill, 'document_new', 'probe:' || v_bill::text)
      is null);
  perform pg_temp.check_eq('and nothing lands in the outbox for it',
    (select count(*)::integer from public.email_outbox
      where org_id = v_org and document_id = v_bill), 0);

  -- (b2) The same shape twice more, on the currency path. Both
  -- `coalesce(v_header ->> 'currency', 'MYR')` and
  -- `coalesce(v_base, 'MYR')` guard against a null that cannot arrive:
  -- `sales_documents.currency`, `purchase_documents.currency` and
  -- `organizations.base_currency` are all NOT NULL, and the snapshot
  -- names `currency` unconditionally, so the key is always there.
  perform pg_temp.check_eq('every document has a currency',
    (select count(*)::integer from information_schema.columns
      where table_schema = 'public' and column_name = 'currency'
        and table_name in ('sales_documents', 'purchase_documents')
        and is_nullable = 'NO'), 2);
  perform pg_temp.check_eq('and every company has a base currency',
    (select is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'organizations'
        and column_name = 'base_currency'), 'NO');
  perform pg_temp.check_true('and a snapshot always carries one',
    app.snapshot_document(v_bill, 'purchase') -> 'header' ? 'currency');

  -- (b3) `app.raise_recurring_document` is reached only through the
  -- runner, which has just read the row -- so its own "schedule not
  -- found" cannot fire in the ordinary path. It is an `app.` writer
  -- with its own signature, and a caller that hands it an id that has
  -- since been deleted is what it is for.
  perform pg_temp.check_refused('a raise of a schedule that is gone is refused',
    format($q$ select app.raise_recurring_document(%L, date '2026-02-01') $q$,
           gen_random_uuid()),
    '%Schedule not found%', 'P0002');

  -- (c) The `else` arm of `app.advance_schedule` -- an unrecognised
  -- frequency treated as monthly -- cannot be reached from either
  -- table: both CHECK `frequency` against the same five words. The
  -- helper is general and has its own callers, so the arm stays; the
  -- rule it is unreachable BY is the CHECK, and that is what is pinned.
  perform pg_temp.check_refused(
    'no schedule can carry a frequency the calendar does not know',
    format($q$ insert into public.recurring_journals
                 (org_id, name, frequency, start_date, next_run_date, template)
               values (%L, 'Fortnightlyish', 'fortnightly', date '2026-01-01',
                       date '2026-01-01', '{"lines":[]}'::jsonb) $q$, v_org),
    '%frequency_check%', '23514');
  -- Reached directly it still answers, rather than returning null and
  -- leaving a schedule due for ever.
  perform pg_temp.check_eq('but the helper still answers if asked directly',
    app.advance_schedule(date '2026-01-15', 'fortnightly', 1,
                         date '2026-01-15')::text,
    date '2026-02-15'::text);

  -- (d) `if p_from is null then return null` cannot be reached through
  -- either runner, because `next_run_date` is NOT NULL on both tables.
  -- Same shape, same answer.
  perform pg_temp.check_refused('and a schedule always has a next run date',
    format($q$ insert into public.recurring_journals
                 (org_id, name, frequency, start_date, next_run_date, template)
               values (%L, 'No next run', 'monthly', date '2026-01-01',
                       null, '{"lines":[]}'::jsonb) $q$, v_org),
    '%next_run_date%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the schedules are closed to anon',
    not has_table_privilege('anon', 'public.recurring_documents', 'select'));
  perform pg_temp.check_true('and the standing journals are too',
    not has_table_privilege('anon', 'public.recurring_journals', 'select'));
  perform pg_temp.check_true('and so is making one',
    not has_function_privilege('anon',
      'public.create_recurring_document(uuid, text, text, date, integer, date, integer, boolean, boolean)',
      'execute'));
  perform pg_temp.check_true('and re-pointing one',
    not has_function_privilege('anon',
      'public.update_recurring_template(uuid, uuid)', 'execute'));
end $$;

rollback;
