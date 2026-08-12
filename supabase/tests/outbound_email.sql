-- =====================================================================
-- iAkauntan :: outbound email tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/outbound_email.sql
--
-- Nothing in this file sends anything. The database queues rows and the
-- `send-email` edge function drains them, which is the split being
-- asserted: no migration, table or test holds a provider key.
--
-- The two things worth getting wrong here are sending a reminder twice
-- and sending one to nobody, so both have their own assertions.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.mail_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.invoice_due(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_due date)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, date '2026-03-01', p_due, p_contact, 'MYR',
          1, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount, p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- Sending a document
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Mailer Sdn Bhd');
  v_contact uuid; v_doc uuid; v_msg uuid; v_body text; v_token text;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;

  v_doc := pg_temp.invoice_due(v_org, v_contact, 'INV-1', 1500, date '2026-03-31');

  -- Off until somebody turns it on. An accounting system that starts
  -- emailing customers the day it is installed is a support incident.
  begin
    perform public.email_document(v_doc);
    raise exception 'FAIL: queued a message with email switched off';
  exception when sqlstate '22023' then
    raise notice 'ok   nothing is sent until email is switched on';
  end;

  insert into public.email_settings (org_id, is_enabled, from_name, reminder_days)
  values (v_org, true, 'Mailer Sdn Bhd', '{0,7,30}');

  v_msg := public.email_document(v_doc);
  perform pg_temp.check_true('a message is queued, not sent',
    (select ob.status = 'queued' and ob.to_email = 'ap@buyer.example'
       from public.email_outbox ob where ob.id = v_msg));

  select ob.body into v_body from public.email_outbox ob where ob.id = v_msg;
  perform pg_temp.check_true('the template is rendered',
    v_body like '%Buyer Bhd%' and v_body like '%INV-1%'
      and v_body like '%1,500.00%');

  -- A token left unreplaced reaches a customer as "{{due_date}}".
  perform pg_temp.check_true('with nothing left unsubstituted',
    v_body not like '%{{%');

  -- The link in the message has to be a link that works, or the whole
  -- exercise is a mail nobody can act on.
  perform pg_temp.check_true('and a share link in it',
    v_body like '%/#/share/%');
  v_token := substring(v_body from '/#/share/([a-f0-9]+)');
  perform pg_temp.check_true('which actually opens the document',
    (public.open_shared_document(v_token)) ->> 'state' = 'open');

  -- A customised template beats the built-in wording.
  insert into public.email_templates (org_id, code, subject, body)
  values (v_org, 'document_new', 'Ours: {{doc_no}}',
          'Custom body for {{contact_name}}');
  v_msg := public.email_document(v_doc);
  perform pg_temp.check_true('an edited template wins over the default',
    (select ob.subject = 'Ours: INV-1'
        and ob.body = 'Custom body for Buyer Bhd'
       from public.email_outbox ob where ob.id = v_msg));
end $$;

-- ---------------------------------------------------------------------
-- Chasing, and not chasing twice
-- ---------------------------------------------------------------------
-- `app.queue_overdue_reminders` walks every organization in the
-- database, which is what the nightly job wants and what makes its
-- return value useless as an assertion here: the blocks above have left
-- their own overdue invoices behind, and this file runs in one
-- transaction. Counting messages against *this* document is the only
-- thing that is a fact about this test.
--
-- That difference is exactly what CI caught and a hosted run did not,
-- because there each block was its own transaction.
do $$
declare
  v_org uuid := pg_temp.mail_org('Chaser Sdn Bhd');
  v_contact uuid; v_doc uuid;
begin
  insert into public.email_settings (org_id, is_enabled, reminder_days)
  values (v_org, true, '{0,7,30}');
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Slow Payer Bhd', 'customer', 'ap@slow.example')
  returning id into v_contact;

  v_doc := pg_temp.invoice_due(v_org, v_contact, 'INV-1', 900, date '2026-03-31');

  perform app.queue_overdue_reminders(date '2026-03-30');
  perform pg_temp.check_eq('nothing the day before it is due',
    (select count(*) from public.email_outbox where document_id = v_doc), 0);

  perform app.queue_overdue_reminders(date '2026-03-31');
  perform pg_temp.check_eq('one on the due date',
    (select count(*) from public.email_outbox where document_id = v_doc), 1);

  -- The dedupe key is what makes the nightly job safe to re-run, and a
  -- reminder sent twice is worse than one sent late.
  perform app.queue_overdue_reminders(date '2026-03-31');
  perform pg_temp.check_eq('and running the job again leaves one, not two',
    (select count(*) from public.email_outbox where document_id = v_doc), 1);

  perform app.queue_overdue_reminders(date '2026-04-07');
  perform pg_temp.check_eq('another at seven days over',
    (select count(*) from public.email_outbox where document_id = v_doc), 2);

  perform app.queue_overdue_reminders(date '2026-04-08');
  perform pg_temp.check_eq('but nothing on a day nobody configured',
    (select count(*) from public.email_outbox where document_id = v_doc), 2);

  -- Paid is paid.
  update public.sales_documents
     set balance_amount = 0, status = 'completed' where id = v_doc;
  perform app.queue_overdue_reminders(date '2026-04-30');
  perform pg_temp.check_eq('a settled invoice is left alone',
    (select count(*) from public.email_outbox where document_id = v_doc), 2);
end $$;

-- A floor under what is worth chasing, and a customer with no address.
do $$
declare
  v_org uuid := pg_temp.mail_org('Threshold Sdn Bhd');
  v_small uuid; v_silent uuid;
begin
  insert into public.email_settings
    (org_id, is_enabled, reminder_days, reminder_min_amount)
  values (v_org, true, '{0}', 100);

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Small Bhd', 'customer', 'ap@small.example')
  returning id into v_small;
  perform pg_temp.invoice_due(v_org, v_small, 'INV-1', 40, date '2026-03-31');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-002', 'No Address Bhd', 'customer')
  returning id into v_silent;
  perform pg_temp.invoice_due(v_org, v_silent, 'INV-2', 5000, date '2026-03-31');

  perform app.queue_overdue_reminders(date '2026-03-31');

  -- One is below the floor and one has nowhere to send to. Neither is
  -- an error worth stopping the run for — the second is a phone call.
  -- Counted for this organization, not from the function's return: it
  -- reports what it did across the whole database.
  perform pg_temp.check_eq('neither is chased',
    (select count(*) from public.email_outbox where org_id = v_org), 0);
end $$;

do $$
declare
  v_org uuid := pg_temp.mail_org('No Address Sdn Bhd');
  v_contact uuid; v_doc uuid;
begin
  insert into public.email_settings (org_id, is_enabled) values (v_org, true);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Unreachable Bhd', 'customer')
  returning id into v_contact;
  v_doc := pg_temp.invoice_due(v_org, v_contact, 'INV-1', 500, date '2026-03-31');

  begin
    perform public.email_document(v_doc);
    raise exception 'FAIL: queued a message with nowhere to send it';
  exception when sqlstate '23514' then
    raise notice 'ok   sending by hand says there is no address';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Who can reach any of this
--
-- `app.issue_share_token` mints a working link for any document id with
-- no permission check — deliberately, because the nightly run has no
-- signed-in user to check. Exposed, it is a way to read any invoice in
-- the database given only its id, and PostgreSQL exposes every new
-- function to PUBLIC unless somebody says otherwise.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('nobody but the owner mints a share token',
    not has_function_privilege('anon',
      'app.issue_share_token(uuid, integer, text)', 'execute')
    and not has_function_privilege('authenticated',
      'app.issue_share_token(uuid, integer, text)', 'execute'));

  perform pg_temp.check_true('and nobody but the cron starts a mailing run',
    not has_function_privilege('anon',
      'app.queue_overdue_reminders(date)', 'execute')
    and not has_function_privilege('authenticated',
      'app.queue_overdue_reminders(date)', 'execute'));

  perform pg_temp.check_true('a member may send a document',
    has_function_privilege('authenticated',
      'public.email_document(uuid, text, text, integer)', 'execute'));
  perform pg_temp.check_true('a stranger may not',
    not has_function_privilege('anon',
      'public.email_document(uuid, text, text, integer)', 'execute'));

  -- Bodies name a customer and an amount owed.
  perform pg_temp.check_true('the outbox is closed to anon',
    not has_table_privilege('anon', 'public.email_outbox', 'select'));
  perform pg_temp.check_true('readable by members',
    has_table_privilege('authenticated', 'public.email_outbox', 'select'));
  perform pg_temp.check_true('but not writable around the function',
    not has_table_privilege('authenticated', 'public.email_outbox', 'insert'));
end $$;

rollback;
