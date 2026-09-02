-- =====================================================================
-- iAkauntan :: the customer portal
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/customer_portal.sql
--
-- 0067 gives a customer a link to one invoice. 0493 gives them a link
-- to their account: every invoice still owed, the total, and a way
-- through to any one of them.
--
-- Like `document_share.sql`, most of what matters here is absence.
-- `open_customer_portal` and `portal_document_token` are callable by
-- `anon`, so a scope that is one clause too wide is a leak to the open
-- internet rather than to another signed-in user -- and the second of
-- them mints a credential, which makes it the more dangerous of the
-- two.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.an_invoice(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_due date default null, p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, date '2026-01-15', p_due, p_contact, 'MYR',
          1, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total, cost_amount)
  values (p_org, v_doc, 1, 'Work done', 1, p_amount, p_amount, 0);
  if p_post then
    perform public.post_sales_document(v_doc);
  end if;
  return v_doc;
end $$;

create or replace function pg_temp.portal(p_token text, p_doc uuid)
returns text language plpgsql as $$
begin
  return public.portal_document_token(p_token, p_doc);
exception when others then return SQLERRM;
end $$;

do $$
declare
  v_org     uuid := pg_temp.test_org('Portal Sdn Bhd');
  v_them    uuid;
  v_us      uuid;
  v_other   uuid;
  v_i1      uuid;
  v_i2      uuid;
  v_draft   uuid;
  v_paid    uuid;
  v_theirs  uuid;
  v_token   text;
  v_out     jsonb;
  v_doctok  text;
  v_emailed text;
  v_n       integer;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'buyer@example.test')
  returning id into v_them;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-002', 'Somebody Else Sdn Bhd', 'customer',
          'other@example.test')
  returning id into v_other;

  -- One owed in full, one part paid, one settled, one never issued.
  v_i1    := pg_temp.an_invoice(v_org, v_them, 'INV-1', 1000,
                                date '2026-02-01');
  v_i2    := pg_temp.an_invoice(v_org, v_them, 'INV-2', 250,
                                date '2026-12-01');
  -- Part paid on purpose: with every balance equal to its total, a
  -- portal that summed `total_amount` instead of `balance_amount`
  -- would show the right number, and the assertion below would be
  -- measuring nothing. It was, until this line.
  update public.sales_documents
     set paid_amount = 100, balance_amount = 150, status = 'partial'
   where id = v_i2;
  v_draft := pg_temp.an_invoice(v_org, v_them, 'INV-3', 9999, null, false);
  -- Settled but left `posted` rather than `completed`, which is the
  -- state that tests the balance filter. Marked `completed` it is
  -- excluded by the status filter instead, and the mutant that widened
  -- the balance test survived untouched.
  v_paid  := pg_temp.an_invoice(v_org, v_them, 'INV-4', 500);
  update public.sales_documents
     set paid_amount = 500, balance_amount = 0
   where id = v_paid;
  v_theirs := pg_temp.an_invoice(v_org, v_other, 'INV-9', 7777);

  -- ------------------------------------------------------------------
  -- Issuing
  -- ------------------------------------------------------------------
  v_out := public.share_customer_portal(v_them, 60);
  v_token := regexp_replace(v_out ->> 'url', '^.*/', '');
  perform pg_temp.check_true('a token comes back', length(v_token) = 64);

  -- 0494. Every portal link 0493 sent went to `/#/share/`, which is the
  -- route that renders one *document* -- so the customer opened a page
  -- saying their link was invalid. This assertion did not exist and
  -- `^.*/` above is happy with either path, which is why nothing caught
  -- it until somebody went to build the page.
  perform pg_temp.check_true(
    'the link goes to the account page, not the document page',
    v_out ->> 'url' like '%/#/account/' || v_token
    and (v_out ->> 'url') not like '%/#/share/%');
  perform pg_temp.check_eq('sent to the address on the contact',
    v_out ->> 'sent_to', 'buyer@example.test');

  -- The token is a credential: it goes out once and what stays behind
  -- is its hash, so a copy of this table is not a set of live doors.
  perform pg_temp.check_true('and only its hash is kept',
    (select token_hash <> v_token
        and token_hash = app.corp_token_hash(v_token)
       from public.customer_portal_links
      where contact_id = v_them and revoked_at is null));

  select count(*)::integer into v_n from public.email_outbox
   where org_id = v_org and template_code = 'customer_portal';
  perform pg_temp.check_eq('and the customer is sent the link', v_n, 1);

  -- ------------------------------------------------------------------
  -- What it shows
  -- ------------------------------------------------------------------
  v_out := public.open_customer_portal(v_token);
  perform pg_temp.check_eq('the portal opens', v_out ->> 'state', 'open');
  perform pg_temp.check_eq('and names the customer',
    v_out -> 'contact' ->> 'name', 'Buyer Bhd');

  perform pg_temp.check_eq(
    'the portal shows this customer''s invoices and nobody else''s',
    jsonb_array_length(v_out -> 'invoices'), 2);
  perform pg_temp.check_true('and only what has actually been issued',
    not (v_out -> 'invoices')::text like '%INV-3%');
  perform pg_temp.check_true('and only what is still owed',
    not (v_out -> 'invoices')::text like '%INV-4%');
  perform pg_temp.check_true('and nothing belonging to another customer',
    not (v_out -> 'invoices')::text like '%INV-9%');

  -- 1000 still owed on the first and 150 on the part-paid second.
  -- Not 1250, which is what the two *totals* come to.
  perform pg_temp.check_eq('the total is what the lines add up to',
    (v_out ->> 'total_outstanding')::numeric, 1150);

  -- Due first, and said to be overdue rather than left to be worked out.
  perform pg_temp.check_eq('the one due soonest is first',
    v_out -> 'invoices' -> 0 ->> 'doc_no', 'INV-1');
  perform pg_temp.check_true('and it says it is overdue',
    (v_out -> 'invoices' -> 0 ->> 'overdue')::boolean);
  perform pg_temp.check_true('while the one not yet due does not',
    not (v_out -> 'invoices' -> 1 ->> 'overdue')::boolean);

  -- ------------------------------------------------------------------
  -- Clicking through
  -- ------------------------------------------------------------------
  -- The tenant emailed a link for INV-1 last week.
  v_emailed := public.share_document(v_i1, 30, 'buyer@example.test');
  perform pg_temp.check_eq('the emailed link works',
    public.open_shared_document(v_emailed) ->> 'state', 'open');

  v_doctok := pg_temp.portal(v_token, v_i1);
  perform pg_temp.check_true('the portal hands out a document token',
    length(v_doctok) = 64);
  perform pg_temp.check_eq('which opens that invoice',
    public.open_shared_document(v_doctok) -> 'document' ->> 'doc_no',
    'INV-1');

  -- The whole reason `portal_document_token` does not revoke.
  perform pg_temp.check_eq(
    'clicking through the portal does not kill the emailed link',
    public.open_shared_document(v_emailed) ->> 'state', 'open');

  -- And it is a key to this account only.
  perform pg_temp.check_eq(
    'a portal cannot open somebody else''s invoice',
    pg_temp.portal(v_token, v_theirs),
    'Not one of this account''s documents');
  perform pg_temp.check_eq('nor one that was never issued',
    pg_temp.portal(v_token, v_draft),
    'A draft document cannot be opened');

  -- ------------------------------------------------------------------
  -- Closing it
  -- ------------------------------------------------------------------
  perform public.revoke_customer_portal(v_them);
  perform pg_temp.check_eq('and a revoked one opens nothing either',
    public.open_customer_portal(v_token) ->> 'state', 'revoked');
  perform pg_temp.check_eq('and hands out no more document tokens',
    pg_temp.portal(v_token, v_i1), 'This link is no longer open');

  -- Expiry is the other way it closes.
  v_out := public.share_customer_portal(v_them, 60);
  v_token := regexp_replace(v_out ->> 'url', '^.*/', '');
  update public.customer_portal_links set expires_at = now() - interval '1 day'
   where contact_id = v_them and revoked_at is null;
  perform pg_temp.check_eq('an expired link opens nothing',
    public.open_customer_portal(v_token) ->> 'state', 'expired');

  -- A token nobody issued.
  perform pg_temp.check_eq('and one nobody issued is invalid',
    public.open_customer_portal('not-a-token') ->> 'state', 'invalid');
end $$;

-- Where the link points, on a platform that has been told its own
-- address. Its own block and its own contact: issuing a second portal
-- for the customer above would revoke their first and queue a second
-- mail, and two assertions there count both.
do $$
declare
  v_org   uuid := pg_temp.test_org('Portal Site Sdn Bhd');
  v_them  uuid;
  v_out   jsonb;
  v_token text;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer')
  returning id into v_them;

  -- Set, then asserted. Written first with an `or not exists` escape
  -- for the case where no site is configured, which made it vacuously
  -- true on a test database that configures none -- so a builder
  -- ignoring the setting entirely passed it.
  insert into public.platform_settings (key, value)
  values ('site_url', to_jsonb('https://books.example'::text))
  on conflict (key) do update set value = excluded.value;

  v_out := public.share_customer_portal(v_them, 60);
  v_token := regexp_replace(v_out ->> 'url', '^.*/', '');
  perform pg_temp.check_true(
    'and it is built on the site the platform is configured for',
    v_out ->> 'url' = 'https://books.example/#/account/' || v_token);
end $$;

-- ---------------------------------------------------------------------
-- Who may issue one
-- ---------------------------------------------------------------------
create or replace function pg_temp.issue(p_contact uuid)
returns text language plpgsql as $$
begin
  perform public.share_customer_portal(p_contact);
  return 'issued';
exception when others then return SQLERRM;
end $$;

do $$
declare
  v_org   uuid := pg_temp.test_org('Portal Guard Sdn Bhd');
  v_them  uuid;
  v_clerk uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer')
  returning id into v_them;

  -- An auditor may read the books and may not disclose an account.
  v_clerk := pg_temp.another_user('juruaudit-0493@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'auditor', 'active', now());
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_eq('somebody who may only read cannot issue one',
    pg_temp.issue(v_them), 'Not permitted to share this account');

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-0493@iakauntan.test'));
  perform pg_temp.check_eq('nor can somebody outside the company',
    pg_temp.issue(v_them), 'Not permitted to share this account');
end $$;

-- ---------------------------------------------------------------------
-- What anon holds
-- ---------------------------------------------------------------------
-- Supabase's default privileges hand `anon` every privilege on any new
-- table in `public`, so a token table is protected by RLS alone unless
-- somebody takes them back. `document_share.sql` caught exactly that on
-- its first run, and this table is the same shape.
do $$
begin
  perform pg_temp.check_true('anon cannot read the portal tokens',
    not has_table_privilege('anon', 'public.customer_portal_links', 'select'));
  perform pg_temp.check_true('nor write them',
    not has_table_privilege('anon', 'public.customer_portal_links', 'insert')
    and not has_table_privilege('anon', 'public.customer_portal_links',
                                'update'));
  perform pg_temp.check_true('a customer may open their own account',
    has_function_privilege('anon', 'public.open_customer_portal(text)',
                           'execute'));
  perform pg_temp.check_true('and may not issue themselves one',
    not has_function_privilege('anon',
      'public.share_customer_portal(uuid, integer, text)', 'execute'));
end $$;

rollback;
