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
-- Send now, and sending it somewhere else
--
-- `dispatch` records which button was pressed, not what became of the
-- message. Nothing here sends: an `immediate` row is queued exactly like
-- any other and the app drains that one row straight after. If that
-- drain fails the scheduler still picks it up, so the assertion that
-- matters is that `immediate` and `queued` both leave a *queued* row.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Urgent Sdn Bhd');
  v_contact uuid; v_doc uuid; v_msg uuid; v_body text; v_token text;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;
  insert into public.email_settings (org_id, is_enabled, reminder_days)
  values (v_org, true, '{}');

  v_doc := pg_temp.invoice_due(v_org, v_contact, 'INV-9', 900, date '2026-03-31');

  v_msg := public.email_document(v_doc);
  perform pg_temp.check_true('queueing is still the default',
    (select ob.dispatch = 'queued' and ob.status = 'queued'
       from public.email_outbox ob where ob.id = v_msg));

  v_msg := public.email_document(v_doc, null, 'document_new', 30, 'immediate');
  perform pg_temp.check_true('send now records the choice',
    (select ob.dispatch = 'immediate' from public.email_outbox ob
      where ob.id = v_msg));
  perform pg_temp.check_true('and still only queues a row',
    (select ob.status = 'queued' and ob.sent_at is null
       from public.email_outbox ob where ob.id = v_msg));

  begin
    perform public.email_document(v_doc, null, 'document_new', 30, 'now');
    raise exception 'FAIL: accepted a dispatch that is not a choice';
  exception when sqlstate '23514' then
    raise notice 'ok   an unknown dispatch is refused';
  end;

  -- Somewhere else. The address overrides the customer record, and the
  -- share token has to be issued against it — reusing one cut for the
  -- customer would mean the audit trail names the wrong person.
  v_msg := public.email_document(v_doc, '  accounts@theiragent.example  ');
  perform pg_temp.check_true('an address overrides the customer record',
    (select ob.to_email = 'accounts@theiragent.example'
       from public.email_outbox ob where ob.id = v_msg));

  select ob.body into v_body from public.email_outbox ob where ob.id = v_msg;
  v_token := substring(v_body from '/#/share/([a-f0-9]+)');
  perform pg_temp.check_true('with the share link issued to that address',
    (select l.sent_to_email = 'accounts@theiragent.example'
       from public.document_share_links l
      where l.token_hash = app.corp_token_hash(v_token)));

  -- A typo is a message that goes nowhere and comes back hours later as
  -- a provider error, if it comes back at all.
  begin
    perform public.email_document(v_doc, 'not an address');
    raise exception 'FAIL: queued a message to something with no @';
  exception when sqlstate '23514' then
    raise notice 'ok   an address with no @ is refused';
  end;
  begin
    perform public.email_document(v_doc, 'a@b');
    raise exception 'FAIL: queued a message to a domain with no dot';
  exception when sqlstate '23514' then
    raise notice 'ok   and one with no domain';
  end;

  -- The attachment path arrives from the client, so it is a claim about
  -- a file rather than a fact. It is pinned to this organization and
  -- this document; the storage policy governs who may *write* there,
  -- and would happily let a member reference their own upload against
  -- somebody else's invoice if this did not check.
  v_msg := public.email_document(v_doc, null, 'document_new', 30, 'queued',
    v_org || '/sales_documents/' || v_doc || '/inv-9.pdf');
  perform pg_temp.check_true('an attachment under this document is kept',
    (select ob.attachment_path is not null and ob.attachment_name = 'inv-9.pdf'
       from public.email_outbox ob where ob.id = v_msg));

  -- Queued first, then read. Calling `email_document` inside the WHERE
  -- clause evaluates it per candidate row rather than once, so the id
  -- being compared changes as the scan proceeds and nothing matches —
  -- which is exactly how CI failed this the first time.
  v_msg := public.email_document(v_doc);
  perform pg_temp.check_true('and link-only is the default',
    (select ob.attachment_path is null and ob.attachment_name is null
       from public.email_outbox ob where ob.id = v_msg));

  begin
    perform public.email_document(v_doc, null, 'document_new', 30, 'queued',
      v_org || '/sales_documents/' || gen_random_uuid() || '/other.pdf');
    raise exception 'FAIL: attached a file belonging to another document';
  exception when sqlstate '42501' then
    raise notice 'ok   an attachment from another document is refused';
  end;

  begin
    perform public.email_document(v_doc, null, 'document_new', 30, 'queued',
      gen_random_uuid() || '/sales_documents/' || v_doc || '/theirs.pdf');
    raise exception 'FAIL: attached a file from another organization';
  exception when sqlstate '42501' then
    raise notice 'ok   nor one from another organization';
  end;

  begin
    perform public.email_document(v_doc, null, 'document_new', 30, 'queued',
      v_org || '/sales_documents/' || v_doc || '/');
    raise exception 'FAIL: accepted a path with no file on the end';
  exception when sqlstate '42501' then
    raise notice 'ok   nor a directory with no file';
  end;
end $$;

-- ---------------------------------------------------------------------
-- What ever left the building
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mail_org('Trail Sdn Bhd');
  v_contact uuid; v_doc uuid; v_rows int; r record;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'ap@buyer.example')
  returning id into v_contact;
  insert into public.email_settings (org_id, is_enabled, reminder_days)
  values (v_org, true, '{}');

  v_doc := pg_temp.invoice_due(v_org, v_contact, 'INV-7', 400, date '2026-03-31');

  -- 0495 put the document's own changes, its payments and what LHDN
  -- said on this timeline, so a freshly raised invoice is no longer
  -- empty -- being raised is itself on it. What this block is about is
  -- the sending, so it counts the three kinds that leave the building.
  perform pg_temp.check_eq('nothing has been sent about it yet',
    (select count(*) from public.document_activity(v_doc)
      where kind in ('email', 'share link', 'pdf')), 0);

  perform public.email_document(v_doc, null, 'document_new', 30, 'immediate');
  perform app.issue_share_token(v_doc, 30, 'ap@buyer.example');
  perform public.log_document_download(v_doc);

  perform pg_temp.check_eq('all three ways of sending appear',
    (select count(distinct kind) from public.document_activity(v_doc)
      where kind in ('email', 'share link', 'pdf')), 3);

  -- Two links, not one: emailing issues a token of its own, and the
  -- explicit share above then issues a second. `issue_share_token`
  -- revokes whatever was live before inserting, so the trail should
  -- show one revoked and one live rather than two live — a link that
  -- was superseded is exactly what somebody is looking for when a
  -- customer says their link stopped working.
  perform pg_temp.check_eq('emailing also issues a link, and both show',
    (select count(*) from public.document_activity(v_doc)
      where kind = 'share link'), 2);
  perform pg_temp.check_eq('the superseded one reads as revoked',
    (select count(*) from public.document_activity(v_doc)
      where kind = 'share link' and status = 'revoked'), 1);
  perform pg_temp.check_eq('and only the newest is live',
    (select count(*) from public.document_activity(v_doc)
      where kind = 'share link' and status = 'live'), 1);

  -- `detail` carries both halves of the choice, and asserting the whole
  -- string is deliberate: 0109 appended the attachment half and this
  -- assertion still expected 'sent now', which is how CI caught that the
  -- two had been changed apart. A `like 'sent now%'` here would have
  -- passed and told nobody.
  select * into r from public.document_activity(v_doc) where kind = 'email';
  perform pg_temp.check_true('the email names the address and the choice',
    r.recipient = 'ap@buyer.example' and r.detail = 'sent now · link only');
  perform pg_temp.check_true('and reports what became of it',
    r.status = 'queued');

  -- The other half of that sentence. "I sent you the invoice" and "I
  -- sent you a link to the invoice" are different claims.
  perform public.email_document(v_doc, null, 'document_new', 30, 'queued',
    v_org || '/sales_documents/' || v_doc || '/inv-7.pdf');
  perform pg_temp.check_eq('an attached message says so',
    (select count(*) from public.document_activity(v_doc)
      where kind = 'email' and detail = 'queued · PDF attached'), 1);

  select * into r from public.document_activity(v_doc) where kind = 'pdf';
  perform pg_temp.check_true('the download is recorded', r.status = 'downloaded');

  -- Newest first: this list is read to answer "what happened last".
  perform pg_temp.check_true('newest first',
    (select bool_and(ordered) from (
       select at <= lag(at) over (order by rn) as ordered
         from (select at, row_number() over () as rn
                 from public.document_activity(v_doc)) x) y
      where ordered is not null));

  perform pg_temp.check_true('a member may read the trail',
    has_function_privilege('authenticated',
      'public.document_activity(uuid)', 'execute'));
  perform pg_temp.check_true('a stranger may not',
    not has_function_privilege('anon',
      'public.document_activity(uuid)', 'execute'));
  perform pg_temp.check_true('downloads are not writable around the function',
    not has_table_privilege('authenticated',
      'public.document_downloads', 'insert'));
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
      'public.email_document(uuid, text, text, integer, text, text, text)',
      'execute'));
  perform pg_temp.check_true('a stranger may not',
    not has_function_privilege('anon',
      'public.email_document(uuid, text, text, integer, text, text, text)',
      'execute'));

  -- 0108 replaced the four-argument form rather than overloading it.
  -- Both existing would be two functions of the same name, one silently
  -- ignoring `p_dispatch`, with PostgREST choosing between them by the
  -- keys in the request body.
  perform pg_temp.check_eq('and there is exactly one email_document',
    (select count(*) from pg_proc where proname = 'email_document'), 1);

  -- Bodies name a customer and an amount owed.
  perform pg_temp.check_true('the outbox is closed to anon',
    not has_table_privilege('anon', 'public.email_outbox', 'select'));
  perform pg_temp.check_true('readable by members',
    has_table_privilege('authenticated', 'public.email_outbox', 'select'));
  perform pg_temp.check_true('but not writable around the function',
    not has_table_privilege('authenticated', 'public.email_outbox', 'insert'));
end $$;

-- ---------------------------------------------------------------------
-- The token in the link, and the address it goes in
--
-- `app.corp_new_token()` is the credential that lets somebody who is
-- not staff open a document: a signing link (0070), a shared invoice
-- (0094), the link in an email (0095), a team invitation (0284). Four
-- callers, and between them the existing files already assert that it
-- is 64 characters and that what arrives in an email body is hex.
--
-- What none of them assert is that two of them differ. A token that was
-- always the same would be 64 hex characters, would arrive in the
-- email, would open the document it was made for — and would open every
-- other document on the platform as well. Every assertion in this
-- repository would still pass. That is the whole gap, and it is the
-- kind that does not announce itself.
--
-- `app.share_url` has a quieter one. It reads `site_url` out of jsonb
-- with `#>> '{}'`, which unwraps the string; `::text` would keep the
-- quotes and put `"https://x"/#/share/tok` in every email the platform
-- sends. The existing assertion looks for `/#/share/` in the body,
-- which that broken address still contains.
--
-- Recorded from mutating it: a token that is always the same never
-- reaches the assertion below. It takes the whole file down forty lines
-- earlier, on `document_share_links_token_hash_key`, because the second
-- share link issued in the same run collides with the first. So the
-- property is already defended, by a unique index rather than by
-- anything in the generator. The assertion is kept: an index refusing a
-- duplicate says a row could not be written, not that the platform is
-- handing the same key to everybody, and the day somebody adds a caller
-- that does not go through that table this is the line that fires.
-- ---------------------------------------------------------------------
do $$
declare
  v_a text := app.corp_new_token();
  v_b text := app.corp_new_token();
  v_distinct integer;
  v_url text;
begin
  perform pg_temp.check_eq('a token is 64 characters', length(v_a), 64);
  perform pg_temp.check_true('and hex, so it survives a URL unescaped',
    v_a ~ '^[0-9a-f]{64}$');
  perform pg_temp.check_true('two tokens are not the same token',
    v_a <> v_b);

  -- Two is a weak claim against a counter or a per-transaction cache.
  -- Two hundred is not.
  select count(distinct t) into v_distinct
    from (select app.corp_new_token() as t
            from generate_series(1, 200)) s;
  perform pg_temp.check_eq('and two hundred of them are two hundred tokens',
    v_distinct, 200);

  -- ------------------------------------------------------------------
  -- The address the token is put in
  -- ------------------------------------------------------------------
  delete from public.platform_settings where key = 'site_url';
  v_url := app.share_url('abc123');
  perform pg_temp.check_eq(
    'with no site configured the link still goes somewhere real',
    v_url, 'https://iakauntan.com/#/share/abc123');

  insert into public.platform_settings (key, value)
  values ('site_url', to_jsonb('https://books.contoh.my'::text))
  on conflict (key) do update set value = excluded.value;

  v_url := app.share_url('abc123');
  perform pg_temp.check_eq('and the configured one is used when there is one',
    v_url, 'https://books.contoh.my/#/share/abc123');
  -- The assertion this block exists for. `value::text` on a jsonb
  -- string keeps the quotes, and a quote in the middle of an address is
  -- a link nobody can click in an email that has already been sent.
  perform pg_temp.check_true('and it carries no quotes out of the jsonb',
    position('"' in v_url) = 0);
  perform pg_temp.check_true('nor any whitespace to break the href',
    v_url !~ '\s');

  delete from public.platform_settings where key = 'site_url';
end $$;


rollback;
