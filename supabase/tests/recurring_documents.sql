-- =====================================================================
-- iAkauntan :: recurring invoices and bills
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_documents.sql
--
-- The four things that would be expensive to get wrong: a document
-- raised twice for one period, a schedule that runs forever after its
-- limit, a run that stops because one schedule failed, and the posting
-- permission check going missing when the body moved down into
-- `app.post_*_internal` so the scheduler could reach it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.rec_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.customer(
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

-- A two-line invoice, posted, which is what a schedule gets copied from.
create or replace function pg_temp.invoice(
  p_org uuid, p_contact uuid, p_no text, p_date date, p_due date)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status, notes)
  values (p_org, 'invoice', p_no, p_date, p_due, p_contact,
          'MYR', 1, 'draft', 'Monthly retainer')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Retainer', 1, 4000),
         (p_org, v_doc, 2, 'Hosting', 2, 250);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

create or replace function pg_temp.bill(
  p_org uuid, p_contact uuid, p_no text, p_date date, p_due date)
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
  values (p_org, v_doc, 1, 'Office rent', 1, 3000);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

-- Every invoice this schedule has raised, oldest first.
create or replace function pg_temp.raised(p_org uuid, p_from date)
returns setof public.sales_documents language sql as $$
  select * from public.sales_documents
   where org_id = p_org and doc_type = 'invoice' and doc_date >= p_from
   order by doc_date, doc_no;
$$;

-- ---------------------------------------------------------------------
-- A monthly retainer
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Retainer Sdn Bhd');
  v_cust uuid; v_seed uuid; v_sched uuid; v_new public.sales_documents;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Steady Bhd', 'ap@steady.example');
  -- Thirty days between the date and the due date, which is the gap the
  -- schedule should keep without being told.
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');

  v_sched := public.create_recurring_document(
    p_document_id => v_seed,
    p_name => 'Monthly retainer',
    p_frequency => 'monthly',
    p_start_date => date '2026-02-01',
    p_auto_post => true);

  perform pg_temp.check_eq('nothing is raised before the start date',
    public.run_recurring_documents_for(v_org, date '2026-01-31'), 0);

  perform pg_temp.check_eq('one on the start date',
    public.run_recurring_documents_for(v_org, date '2026-02-01'), 1);

  select * into v_new from pg_temp.raised(v_org, date '2026-02-01') limit 1;

  perform pg_temp.check_eq('carrying the whole document, not a rounded total',
    v_new.total_amount, 4500);
  perform pg_temp.check_eq('both lines',
    (select count(*) from public.sales_document_lines
      where document_id = v_new.id), 2);
  perform pg_temp.check_true('with a number of its own',
    v_new.doc_no is not null and v_new.doc_no <> 'INV-1');
  perform pg_temp.check_true('the notes came along',
    v_new.notes = 'Monthly retainer');

  -- Thirty days from 1 February 2026 is 3 March: the gap is carried,
  -- not the day of the month.
  perform pg_temp.check_true('due thirty days out, as the seed invoice was',
    v_new.due_date = date '2026-03-03');

  perform pg_temp.check_true('posted, because the schedule says so',
    v_new.status = 'posted' and v_new.gl_entry_id is not null);

  -- The expensive mistake: billing somebody twice for one month.
  perform pg_temp.check_eq('running it again the same day raises nothing',
    public.run_recurring_documents_for(v_org, date '2026-02-01'), 0);
  perform pg_temp.check_eq('and there is still one invoice',
    (select count(*) from pg_temp.raised(v_org, date '2026-02-01')), 1);

  perform pg_temp.check_true('the schedule has moved on a month',
    (select next_run_date = date '2026-03-01' and occurrences = 1
       from public.recurring_documents where id = v_sched));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Sending it, when the schedule says to
--
-- The queueing body moved out of `app.queue_overdue_reminders` so the
-- two runs cannot drift into sending differently shaped mail. This is
-- the recurring end of it; `outbound_email.sql` still holds the
-- reminder end.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Sender Sdn Bhd');
  v_cust uuid; v_seed uuid; v_doc uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Steady Bhd', 'ap@steady.example');
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');
  insert into public.email_settings (org_id, is_enabled, from_name)
  values (v_org, true, 'Sender Sdn Bhd');

  perform public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Monthly retainer',
    p_frequency => 'monthly', p_start_date => date '2026-02-01',
    p_auto_post => true, p_auto_email => true);
  perform public.run_recurring_documents_for(v_org, date '2026-02-01');

  select id into v_doc from pg_temp.raised(v_org, date '2026-02-01') limit 1;
  perform pg_temp.check_eq('one message, queued rather than sent',
    (select count(*) from public.email_outbox
      where document_id = v_doc and status = 'queued'), 1);
  perform pg_temp.check_true('addressed to the customer, with the amount in it',
    (select ob.to_email = 'ap@steady.example' and ob.body like '%4,500.00%'
       and ob.body not like '%{{%'
       from public.email_outbox ob where ob.document_id = v_doc));

  perform pg_temp.sign_out();
end $$;

-- A schedule told to email but not to post has nothing worth sending: a
-- draft has no number the customer can pay against.
do $$
declare
  v_org uuid := pg_temp.rec_org('Unsent Sdn Bhd');
  v_cust uuid; v_seed uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Steady Bhd', 'ap@steady.example');
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');
  insert into public.email_settings (org_id, is_enabled) values (v_org, true);

  perform public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Draft only',
    p_frequency => 'monthly', p_start_date => date '2026-02-01',
    p_auto_email => true);
  perform public.run_recurring_documents_for(v_org, date '2026-02-01');

  perform pg_temp.check_eq('a draft is not emailed to anybody',
    (select count(*) from public.email_outbox where org_id = v_org), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A run that was missed
--
-- A scheduler down for a quarter owes a quarter of invoices, each dated
-- when it was due rather than all on the day somebody noticed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Catchup Sdn Bhd');
  v_cust uuid; v_seed uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Patient Bhd');
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');

  perform public.create_recurring_document(
    v_seed, 'Monthly retainer', 'monthly', date '2026-02-01');

  perform pg_temp.check_eq('three months missed is three invoices',
    public.run_recurring_documents_for(v_org, date '2026-04-15'), 3);

  perform pg_temp.check_true('dated when each was due, not all today',
    (select array_agg(doc_date order by doc_date)
       from pg_temp.raised(v_org, date '2026-02-01'))
    = array[date '2026-02-01', date '2026-03-01', date '2026-04-01']);

  -- Nothing said to post them, so they are drafts for somebody to look
  -- at. A schedule that posts by default is one that posts by accident.
  perform pg_temp.check_true('left as drafts',
    not exists (select 1 from pg_temp.raised(v_org, date '2026-02-01')
                 where status <> 'draft'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Where a schedule stops
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Finite Sdn Bhd');
  v_cust uuid; v_seed uuid; v_counted uuid; v_dated uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Three Bhd');
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');

  v_counted := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Three instalments',
    p_frequency => 'monthly', p_start_date => date '2026-02-01',
    p_max_occurrences => 3);

  perform pg_temp.check_eq('three, and then it stops',
    public.run_recurring_documents_for(v_org, date '2026-12-31'), 3);
  perform pg_temp.check_true('and switches itself off rather than sitting due',
    (select occurrences = 3 and not is_active
       from public.recurring_documents where id = v_counted));
  perform pg_temp.check_eq('a later run finds nothing to do',
    public.run_recurring_documents_for(v_org, date '2027-12-31'), 0);

  v_dated := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Until June',
    p_frequency => 'monthly', p_start_date => date '2026-02-01',
    p_end_date => date '2026-06-30');
  perform pg_temp.check_eq('an end date stops it too',
    public.run_recurring_documents_for(v_org, date '2026-12-31'), 5);

  -- An end date before the start is somebody mistyping a year.
  begin
    perform public.create_recurring_document(
      p_document_id => v_seed, p_name => 'Backwards',
      p_frequency => 'monthly', p_start_date => date '2026-02-01',
      p_end_date => date '2025-06-30');
    raise exception 'FAIL: accepted an end date before the start date';
  exception when sqlstate '22023' then
    raise notice 'ok   an end date before the start is refused';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- One that cannot run does not take the others down
--
-- The failure used here is a real one: a period nobody has opened. The
-- point is that the schedule behind it still bills, and that the reason
-- is written down rather than swallowed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Broken Sdn Bhd');
  v_cust uuid; v_seed uuid; v_bad uuid; v_good uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Steady Bhd');
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');

  -- Both fall due on the same day. Only 2026 has a fiscal year, so the
  -- one told to post into 2027 cannot, and the one left as a draft can.
  v_bad := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Posts into a year nobody opened',
    p_frequency => 'yearly', p_start_date => date '2027-02-01',
    p_auto_post => true);
  v_good := public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Leaves a draft',
    p_frequency => 'yearly', p_start_date => date '2027-02-01');

  perform pg_temp.check_eq('the one that can run, runs',
    public.run_recurring_documents_for(v_org, date '2027-02-01'), 1);

  perform pg_temp.check_true('and the one that cannot says why',
    (select last_error is not null and last_error_at is not null
       from public.recurring_documents where id = v_bad));
  perform pg_temp.check_true('with its date left alone, so it retries',
    (select next_run_date = date '2027-02-01' and occurrences = 0
       from public.recurring_documents where id = v_bad));
  perform pg_temp.check_true('while the other one moved on',
    (select occurrences = 1 and last_error is null
       from public.recurring_documents where id = v_good));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Bills repeat the same way
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Rent Sdn Bhd');
  v_supp uuid; v_seed uuid; v_bill public.purchase_documents;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Landlord Bhd', 'supplier')
  returning id into v_supp;

  v_seed := pg_temp.bill(v_org, v_supp, 'BILL-1',
                         date '2026-01-01', date '2026-01-15');

  perform public.create_recurring_document(
    p_document_id => v_seed, p_name => 'Office rent',
    p_frequency => 'monthly', p_start_date => date '2026-02-01',
    p_auto_post => true);

  perform pg_temp.check_eq('the rent bills itself',
    public.run_recurring_documents_for(v_org, date '2026-02-01'), 1);

  select * into v_bill from public.purchase_documents
   where org_id = v_org and doc_date = date '2026-02-01';
  perform pg_temp.check_eq('for the same money', v_bill.total_amount, 3000);
  perform pg_temp.check_true('posted to the ledger',
    v_bill.gl_entry_id is not null);
  -- Fourteen days on the seed bill, carried without being asked for.
  perform pg_temp.check_true('keeping the fourteen days the bill had',
    v_bill.due_date = date '2026-02-15');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Changing what gets billed
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Repriced Sdn Bhd');
  v_cust uuid; v_seed uuid; v_sched uuid; v_newer uuid; v_other uuid;
  v_elsewhere uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Growing Bhd');
  v_seed := pg_temp.invoice(v_org, v_cust, 'INV-1',
                            date '2026-01-01', date '2026-01-31');
  v_sched := public.create_recurring_document(
    v_seed, 'Monthly retainer', 'monthly', date '2026-02-01');

  -- The price went up. Point the schedule at an invoice that says so.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status)
  values (v_org, 'invoice', 'INV-NEW', date '2026-01-20', date '2026-02-19',
          v_cust, 'MYR', 1, 'draft')
  returning id into v_newer;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_newer, 1, 'Retainer', 1, 5000);

  perform public.update_recurring_template(v_sched, v_newer);
  perform pg_temp.check_eq('the new price is what gets billed',
    public.run_recurring_documents_for(v_org, date '2026-02-01'), 1);
  perform pg_temp.check_eq('at the amount on the newer document',
    (select total_amount from pg_temp.raised(v_org, date '2026-02-01') limit 1),
    5000);

  -- Editing the document the schedule was made from must not reach the
  -- schedule: that is the whole reason the template is a copy.
  update public.sales_document_lines set unit_price = 99
   where document_id = v_newer;
  perform pg_temp.check_eq('and editing that document afterwards does not',
    public.run_recurring_documents_for(v_org, date '2026-03-01'), 1);
  perform pg_temp.check_eq('the March invoice still bills the old figure',
    (select total_amount from public.sales_documents
      where org_id = v_org and doc_date = date '2026-03-01'), 5000);

  -- A document from another company is another company's prices.
  v_elsewhere := pg_temp.rec_org('Elsewhere Sdn Bhd');
  v_other := pg_temp.invoice(
    v_elsewhere,
    pg_temp.customer(v_elsewhere, 'C-001', 'Other Bhd'),
    'INV-X', date '2026-01-01', date '2026-01-31');
  begin
    perform public.update_recurring_template(v_sched, v_other);
    raise exception 'FAIL: copied a template across organizations';
  exception when sqlstate '42501' or sqlstate '22023' then
    raise notice 'ok   a document from another company is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- What the schedule may be made from
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Refuse Sdn Bhd');
  v_cust uuid; v_quote uuid;
begin
  v_cust := pg_temp.customer(v_org, 'C-001', 'Prospect Bhd');
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'quotation', 'QT-1', date '2026-01-01', v_cust, 'MYR', 1, 'draft')
  returning id into v_quote;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_quote, 1, 'Maybe', 1, 100);

  -- A quotation that arrived every month on its own would be a document
  -- nobody asked for.
  begin
    perform public.create_recurring_document(
      v_quote, 'Monthly quote', 'monthly', date '2026-02-01');
    raise exception 'FAIL: made a schedule out of a quotation';
  exception when sqlstate '22023' then
    raise notice 'ok   only an invoice or a bill can be made recurring';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The posting path the scheduler uses
--
-- The bodies of `post_sales_document` and `post_purchase_document` moved
-- down into `app.*_internal` so a run with no signed-in user could
-- reach them. The check they used to carry has to still be on the way
-- in, and the way round it has to be closed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rec_org('Guard Sdn Bhd');
  v_cust uuid; v_doc uuid; v_owner uuid;
begin
  v_owner := pg_temp.test_user();
  v_cust := pg_temp.customer(v_org, 'C-001', 'Steady Bhd');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', date '2026-01-01', date '2026-01-31',
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_doc, 1, 'Work', 1, 100);

  -- Nobody signed in is nobody who may post.
  perform pg_temp.sign_out();
  begin
    perform public.post_sales_document(v_doc);
    raise exception 'FAIL: posted with nobody signed in';
  exception when sqlstate '42501' then
    raise notice 'ok   the permission check survived the move';
  end;

  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and the owner still can',
    public.post_sales_document(v_doc) is not null);

  perform pg_temp.sign_out();
end $$;

do $$
begin
  perform pg_temp.check_true('the internal posting path is closed to the API',
    not has_function_privilege('anon',
      'app.post_sales_document_internal(uuid)', 'execute')
    and not has_function_privilege('authenticated',
      'app.post_sales_document_internal(uuid)', 'execute')
    and not has_function_privilege('anon',
      'app.post_purchase_document_internal(uuid)', 'execute')
    and not has_function_privilege('authenticated',
      'app.post_purchase_document_internal(uuid)', 'execute'));

  perform pg_temp.check_true('and so is the runner and what it calls',
    not has_function_privilege('anon',
      'app.run_recurring_documents(date)', 'execute')
    and not has_function_privilege('authenticated',
      'app.advance_recurring_document(uuid, date)', 'execute')
    and not has_function_privilege('anon',
      'app.queue_document_email(uuid, text, text)', 'execute'));

  perform pg_temp.check_true('a member may drive the run for their own company',
    has_function_privilege('authenticated',
      'public.run_recurring_documents_for(uuid, date)', 'execute'));
  perform pg_temp.check_true('a stranger may not',
    not has_function_privilege('anon',
      'public.run_recurring_documents_for(uuid, date)', 'execute'));

  -- Schedules carry a customer, prices and terms.
  perform pg_temp.check_true('the schedules are closed to anon',
    not has_table_privilege('anon', 'public.recurring_documents', 'select'));
  perform pg_temp.check_true('and readable by members',
    has_table_privilege('authenticated', 'public.recurring_documents', 'select'));
end $$;

-- ---------------------------------------------------------------------
-- A quarter is not a Postgres interval (0447)
--
-- `app.advance_schedule` built its interval by pasting a number to a
-- word, and one of the words was wrong: Postgres has no `quarters`
-- unit, so `'1 quarters'::interval` raises 22007. The recurring journal
-- editor offers **Quarter** in its dropdown, so this was reachable and
-- had never worked. Measured through the real scheduler before the fix:
--
--     quarterly journal ran, 0 raised
--     last_error: invalid input syntax for type interval: "1 quarters"
--     next_run_date is still: 2026-01-31
--
-- The runner catches the failure and leaves `next_run_date` alone so it
-- retries, which is right for a transient fault and wrong for one that
-- cannot stop happening: it failed every night and said so only in a
-- column.
--
-- The second fault needed two steps to see, which is why nothing had.
-- Adding a month to 31 January gives 28 February, correctly; adding a
-- month to *that* gives 28 March. A tenancy invoiced on the last day of
-- every month became the 28th of every month for good, the first time
-- it crossed February.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a quarter is three months',
    app.advance_schedule(date '2026-01-31', 'quarterly', 1,
                         date '2026-01-31')::text, '2026-04-30');

  perform pg_temp.check_eq('and two quarters are six',
    app.advance_schedule(date '2026-01-15', 'quarterly', 2,
                         date '2026-01-15')::text, '2026-07-15');

  -- The drift, in the two steps it takes to appear.
  perform pg_temp.check_eq('the end of January is the end of February',
    app.advance_schedule(date '2026-01-31', 'monthly', 1,
                         date '2026-01-31')::text, '2026-02-28');

  perform pg_temp.check_eq('and comes back to the thirty-first in March',
    app.advance_schedule(date '2026-02-28', 'monthly', 1,
                         date '2026-01-31')::text, '2026-03-31');

  -- February is as long as February is: an anchor of the 31st must be
  -- clamped rather than handed to a date that does not exist.
  perform pg_temp.check_eq('February is as long as February is',
    app.advance_schedule(date '2026-01-31', 'monthly', 1,
                         date '2026-01-31')::text, '2026-02-28');

  perform pg_temp.check_eq('and twenty-nine of it in a leap year',
    app.advance_schedule(date '2024-01-31', 'monthly', 1,
                         date '2024-01-31')::text, '2024-02-29');

  -- A day in the middle of the month is not touched by any of this.
  perform pg_temp.check_eq('the fifteenth stays the fifteenth',
    app.advance_schedule(date '2026-01-15', 'monthly', 1,
                         date '2026-01-15')::text, '2026-02-15');

  -- Nor is anything counted in days or weeks: a fortnightly schedule is
  -- every fourteen days, and snapping it to a day of the month would
  -- turn it into something else entirely.
  perform pg_temp.check_eq('a fortnightly schedule is left alone',
    app.advance_schedule(date '2026-01-31', 'weekly', 2,
                         date '2026-01-31')::text, '2026-02-14');

  perform pg_temp.check_eq('and so is a daily one',
    app.advance_schedule(date '2026-01-31', 'daily', 3,
                         date '2026-01-31')::text, '2026-02-03');

  perform pg_temp.check_eq('a year is a year',
    app.advance_schedule(date '2026-02-28', 'yearly', 1,
                         date '2026-02-28')::text, '2027-02-28');
end $$;

-- ---------------------------------------------------------------------
-- And through the scheduler, which is where it mattered
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Suku Tahun Sdn Bhd');
  v_j   uuid;
  v_n   integer;
begin
  insert into public.recurring_journals
    (org_id, name, frequency, interval_count, start_date, next_run_date,
     is_active, auto_post, template)
  values (v_org, 'Quarterly accrual', 'quarterly', 1, date '2026-01-31',
          date '2026-01-31', true, false, '{"lines": []}'::jsonb)
  returning id into v_j;

  v_n := app.run_recurring_journals(date '2026-02-01');
  perform pg_temp.check_eq('the quarterly journal runs at all', v_n, 1);

  perform pg_temp.check_true('and records no error',
    (select last_error is null from public.recurring_journals
      where id = v_j));

  perform pg_temp.check_eq('and is next due three months on',
    (select next_run_date::text from public.recurring_journals
      where id = v_j), '2026-04-30');

  -- The monthly case, twice, because one step cannot show the drift.
  update public.recurring_journals
     set frequency = 'monthly', next_run_date = date '2026-01-31'
   where id = v_j;

  perform app.run_recurring_journals(date '2026-02-01');
  perform pg_temp.check_eq('a monthly one reaches the end of February',
    (select next_run_date::text from public.recurring_journals
      where id = v_j), '2026-02-28');

  perform app.run_recurring_journals(date '2026-03-01');
  perform pg_temp.check_eq('and the end of March, rather than the 28th',
    (select next_run_date::text from public.recurring_journals
      where id = v_j), '2026-03-31');
end $$;

rollback;
