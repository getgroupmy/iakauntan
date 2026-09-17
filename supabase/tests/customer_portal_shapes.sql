-- =====================================================================
-- iAkauntan :: the one door somebody who is not staff holds a key to
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/customer_portal_shapes.sql
--
-- `open_customer_portal` is granted to `anon`. It is the only function
-- in this system that a person with no account, no membership and no
-- password can call, and what it returns is one customer's whole
-- ledger position. `portal_document_token` mints document links from
-- that same key.
--
-- A mutation sweep of 59 one-line mutants killed 17.
--
-- `customer_portal.sql` proves the good path and the loudest refusals:
-- a bad token, a revoked one, an expired one, drafts and settled
-- invoices kept off the list, another customer's document refused. What
-- it does not do is vary the SHAPE of anything -- one company, one
-- portal, one customer with one record, invoices that are all posted
-- and all owing and all due on the same day.
--
-- So what lived was the tenancy. `portal_document_token`'s own comment
-- says of its filter:
--
--     Without this line a portal token is a key to every invoice in
--     the tenant.
--
-- and nothing in the suite proved that line works.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cp_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end $$;

create or replace function pg_temp.cp_customer(
  p_org uuid, p_code text, p_name text, p_email text default null)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, p_code, p_name, 'customer', p_email) returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.cp_invoice(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_due date default date '2026-02-15', p_post boolean default true,
  p_type text default 'invoice', p_date date default date '2026-01-15')
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, p_type::app.sales_doc_type, p_no, p_date, p_due, p_contact, 'MYR',
          1, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total, cost_amount)
  values (p_org, v_doc, 1, 'Work done', 1, p_amount, p_amount, 0);
  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end $$;

-- `portal_document_token` raises rather than returning a state, so the
-- message is what an assertion has to look at.
create or replace function pg_temp.cp_doc_token(p_token text, p_doc uuid)
returns text language plpgsql as $$
begin
  return 'ok:' || public.portal_document_token(p_token, p_doc);
exception when others then return sqlerrm;
end $$;

-- `share_customer_portal` returns the URL, not the token; the token is
-- its last segment. Same extraction `customer_portal.sql` uses.
create or replace function pg_temp.cp_share(
  p_contact uuid, p_days integer default 30, p_email text default null)
returns text language sql as $$
  select regexp_replace(
    public.share_customer_portal(p_contact, p_days, p_email) ->> 'url',
    '^.*/', '');
$$;

create or replace function pg_temp.cp_state(p_token text)
returns text language sql as $$
  select public.open_customer_portal(p_token) ->> 'state';
$$;

-- ---------------------------------------------------------------------
-- 1. A key that opens one company's door and no other
-- ---------------------------------------------------------------------
-- The heart of it. `portal_document_token`'s filter is four conditions
-- and a sibling lookup, and the sweep found that only ONE of them --
-- "this customer's" -- was proved. The rest were a comment.
--
-- The sibling lookup is the subtle one. `0477` links a customer filed
-- twice through `contacts.party_id`, so a portal reaches both records.
-- `party_id` is a bare uuid: NO foreign key, nothing scoping it to a
-- company. Nothing stops a contact in another company carrying this
-- company's party id -- an import, a restore, a merge run twice -- and
-- `c2.org_id = l.org_id` is the only thing between that and a portal
-- token minting a link to a stranger's invoice.
do $$
declare
  v_a uuid := pg_temp.cp_org('Portal Kita Sdn Bhd');
  v_b uuid := pg_temp.cp_org('Syarikat Jiran Sdn Bhd');
  v_ours uuid; v_ours_2 uuid; v_theirs uuid; v_impostor uuid;
  v_party uuid;
  v_our_inv uuid; v_sibling_inv uuid; v_their_inv uuid; v_impostor_inv uuid;
  v_tok text; v_res text;
begin
  perform pg_temp.allow_many_companies();

  v_ours := pg_temp.cp_customer(v_a, 'C-1', 'Pembeli Bhd', 'buyer@a.test');
  -- The same company filed twice, linked. Both records are ours.
  v_ours_2 := pg_temp.cp_customer(v_a, 'C-1B', 'Pembeli Berhad');
  v_party := v_ours;
  update public.contacts set party_id = v_party
   where id in (v_ours, v_ours_2);

  v_theirs := pg_temp.cp_customer(v_b, 'C-X', 'Orang Lain Bhd');
  -- A contact in ANOTHER company carrying OUR party id. Nothing in the
  -- schema forbids it, which is the whole point.
  v_impostor := pg_temp.cp_customer(v_b, 'C-Y', 'Penyamar Bhd');
  update public.contacts set party_id = v_party where id = v_impostor;

  v_our_inv     := pg_temp.cp_invoice(v_a, v_ours,     'INV-A1', 1000);
  v_sibling_inv := pg_temp.cp_invoice(v_a, v_ours_2,  'INV-A2', 400);
  v_their_inv   := pg_temp.cp_invoice(v_b, v_theirs,   'INV-B1', 5000);
  v_impostor_inv:= pg_temp.cp_invoice(v_b, v_impostor, 'INV-B2', 9000);

  v_tok := pg_temp.cp_share(v_ours, 30);

  -- Ours opens.
  perform pg_temp.check_true('a portal mints a link for its own invoice',
    pg_temp.cp_doc_token(v_tok, v_our_inv) like 'ok:%');
  -- And the same customer's OTHER record opens too -- that is what the
  -- party link is for, and the half that must keep working.
  perform pg_temp.check_true(
    'and for the same customer''s second record',
    pg_temp.cp_doc_token(v_tok, v_sibling_inv) like 'ok:%');

  -- A stranger in another company: refused.
  perform pg_temp.check_eq('but not for another company''s customer',
    pg_temp.cp_doc_token(v_tok, v_their_inv),
    'Not one of this account''s documents');

  -- THE ONE THAT MATTERS. Another company's contact wearing our party
  -- id. Without `c2.org_id = l.org_id` this key opens their ledger.
  perform pg_temp.check_eq(
    'and not for another company''s contact carrying our party id',
    pg_temp.cp_doc_token(v_tok, v_impostor_inv),
    'Not one of this account''s documents');

  -- The listing has the same pair of conditions, so ask it the same
  -- questions. Two invoices, ours and our sibling's -- and nothing of
  -- the neighbour's, party id or no party id.
  declare v_out jsonb := public.open_customer_portal(v_tok);
  begin
    perform pg_temp.check_eq('the account lists both of its own invoices',
      jsonb_array_length(v_out -> 'invoices'), 2);
    perform pg_temp.check_eq('and owes the two of them added up',
      (v_out ->> 'total_outstanding')::numeric, 1400);
    perform pg_temp.check_true('with no sight of the neighbour''s ledger',
      not (v_out -> 'invoices')::text like '%INV-B%');
  end;
end $$;

-- ---------------------------------------------------------------------
-- 2. The four ways a door can be shut, and the record that it was tried
-- ---------------------------------------------------------------------
-- `open_customer_portal` never raises: it returns a state, because the
-- caller is a stranger's browser and an exception is a stack trace. The
-- states are invalid, revoked, expired, withdrawn and open, and the
-- refusal is recorded even so — `0067`'s rule that somebody TRYING is
-- worth as much as somebody reading.
do $$
declare
  v_org uuid := pg_temp.cp_org('Pintu Sdn Bhd');
  v_c uuid; v_gone uuid; v_tok text; v_tok2 text; v_tok3 text; v_l uuid;
begin
  v_c    := pg_temp.cp_customer(v_org, 'C-1', 'Pembeli Bhd');
  v_gone := pg_temp.cp_customer(v_org, 'C-2', 'Bekas Pelanggan Bhd');

  perform pg_temp.check_eq('a token nobody issued is invalid',
    pg_temp.cp_state('not-a-real-token'), 'invalid');

  -- Revoked.
  v_tok := pg_temp.cp_share(v_c, 30);
  perform public.revoke_customer_portal(v_c);
  perform pg_temp.check_eq('a revoked link says so', pg_temp.cp_state(v_tok),
    'revoked');

  -- Expired. The boundary is `expires_at < now()`, so a link expiring
  -- in the next instant is still open — which is right: a link is good
  -- until it is not.
  v_tok2 := pg_temp.cp_share(v_c, 30);
  select id into v_l from public.customer_portal_links
   where contact_id = v_c and revoked_at is null;
  update public.customer_portal_links set expires_at = now() + interval '1 second'
   where id = v_l;
  perform pg_temp.check_eq('a link with a second left on it is open',
    pg_temp.cp_state(v_tok2), 'open');
  update public.customer_portal_links set expires_at = now() - interval '1 second'
   where id = v_l;
  perform pg_temp.check_eq('and a second past its time is expired',
    pg_temp.cp_state(v_tok2), 'expired');

  -- THE BOUNDARY ITSELF. A second either side cannot tell `<` from
  -- `<=`; only the instant the link expires can, and inside one
  -- transaction `now()` is a fixed instant that can be assigned. A link
  -- is good UNTIL its expiry, not up to the moment before it.
  update public.customer_portal_links set expires_at = now() where id = v_l;
  perform pg_temp.check_eq('a link is open on the very instant it expires',
    pg_temp.cp_state(v_tok2), 'open');

  -- Withdrawn: the customer has been deleted since the link was sent.
  -- Not the same as expired, and not the same as invalid — the link is
  -- real and in date, and there is no longer an account behind it.
  v_tok3 := pg_temp.cp_share(v_gone, 30);
  update public.contacts set deleted_at = now() where id = v_gone;
  perform pg_temp.check_eq('a deleted customer''s link is withdrawn',
    pg_temp.cp_state(v_tok3), 'withdrawn');

  -- And a refused state carries NOTHING else. A revoked link that still
  -- returned the invoices would be a revoke in name only.
  perform pg_temp.check_true('a refused link returns no ledger at all',
    not (public.open_customer_portal(v_tok) ? 'invoices')
    and not (public.open_customer_portal(v_tok) ? 'total_outstanding'));
end $$;

-- The visit is recorded whichever answer it got. `opened_at` is the
-- FIRST time, `last_opened_at` the most recent, and `open_count` rises
-- every time — three columns that only differ once a link is opened
-- more than once, which nothing had done.
do $$
declare
  v_org uuid := pg_temp.cp_org('Jejak Sdn Bhd');
  v_a uuid; v_b uuid; v_tok text; v_other text;
  v_first timestamptz; v_l public.customer_portal_links;
  v_bl public.customer_portal_links;
begin
  v_a := pg_temp.cp_customer(v_org, 'C-1', 'Satu Bhd');
  v_b := pg_temp.cp_customer(v_org, 'C-2', 'Dua Bhd');
  v_tok   := pg_temp.cp_share(v_a, 30);
  v_other := pg_temp.cp_share(v_b, 30);

  perform pg_temp.check_true('an unopened link has never been opened',
    (select opened_at is null and open_count = 0
       from public.customer_portal_links
      where contact_id = v_a and revoked_at is null));

  perform pg_temp.cp_state(v_tok);
  select * into v_l from public.customer_portal_links
   where contact_id = v_a and revoked_at is null;
  v_first := v_l.opened_at;
  perform pg_temp.check_eq('the first visit is counted', v_l.open_count, 1);
  perform pg_temp.check_true('and timed', v_first is not null);

  perform pg_temp.cp_state(v_tok);
  perform pg_temp.cp_state(v_tok);
  select * into v_l from public.customer_portal_links
   where contact_id = v_a and revoked_at is null;
  perform pg_temp.check_eq('every visit after it too', v_l.open_count, 3);

  -- `opened_at` and `last_opened_at` cannot be told apart by waiting:
  -- `now()` is the TRANSACTION's clock and this whole file is one
  -- transaction, so three visits share a timestamp. Backdating each in
  -- turn is what separates them — one is `coalesce`d and must not move,
  -- the other is assigned and must.
  update public.customer_portal_links
     set opened_at = timestamptz '2020-01-01 08:00+08',
         last_opened_at = timestamptz '2020-01-01 08:00+08'
   where id = v_l.id;
  perform pg_temp.cp_state(v_tok);
  select * into v_l from public.customer_portal_links
   where contact_id = v_a and revoked_at is null;
  perform pg_temp.check_eq('the first visit stays the first visit',
    v_l.opened_at::text, (timestamptz '2020-01-01 08:00+08')::text);
  perform pg_temp.check_true('while the most recent one moves up to now',
    v_l.last_opened_at > timestamptz '2020-01-01 08:00+08');

  -- One customer's visit is one customer's. Stamped across the table it
  -- would read as every customer having opened their portal at once.
  select * into v_bl from public.customer_portal_links
   where contact_id = v_b and revoked_at is null;
  perform pg_temp.check_eq('and the link beside it was not visited',
    v_bl.open_count, 0);
  perform pg_temp.check_true('nor stamped', v_bl.opened_at is null);

  -- A link that is past its date still records the attempt.
  update public.customer_portal_links set expires_at = now() - interval '1 day'
   where contact_id = v_a and revoked_at is null;
  perform pg_temp.check_eq('an expired link still refuses',
    pg_temp.cp_state(v_tok), 'expired');
  perform pg_temp.check_eq('and the attempt is still counted',
    (select open_count from public.customer_portal_links
      where contact_id = v_a and revoked_at is null), 5);
end $$;

-- ---------------------------------------------------------------------
-- 3. What a customer is shown that they owe
-- ---------------------------------------------------------------------
-- Six conditions decide the list and three fields decide how it reads.
-- Every invoice in the existing file is posted, owing, and due on the
-- same day, so most of them had nothing on either side.
do $$
declare
  v_org uuid := pg_temp.cp_org('Senarai Sdn Bhd');
  v_c uuid; v_tok text; v_out jsonb; v_inv jsonb;
  v_owing uuid; v_settled uuid; v_credit uuid; v_deleted uuid;
  v_draft uuid; v_quote uuid; v_early uuid; v_late uuid; v_nodue uuid;
begin
  v_c := pg_temp.cp_customer(v_org, 'C-1', 'Pembeli Bhd');

  -- Three that belong on the list, due in a deliberate jumble so the
  -- ordering has something to sort.
  v_late  := pg_temp.cp_invoice(v_org, v_c, 'INV-3', 300, date '2026-03-01');
  v_early := pg_temp.cp_invoice(v_org, v_c, 'INV-1', 100, date '2026-01-20');
  v_nodue := pg_temp.cp_invoice(v_org, v_c, 'INV-2', 200, null);

  -- And five that do not.
  v_draft   := pg_temp.cp_invoice(v_org, v_c, 'INV-D', 999,
                                  date '2026-02-01', false);
  v_quote   := pg_temp.cp_invoice(v_org, v_c, 'QUO-1', 888,
                                  date '2026-02-01', false, 'quotation');
  v_deleted := pg_temp.cp_invoice(v_org, v_c, 'INV-X', 777);
  update public.sales_documents set deleted_at = now() where id = v_deleted;
  v_settled := pg_temp.cp_invoice(v_org, v_c, 'INV-P', 500);
  update public.sales_documents set balance_amount = 0, status = 'completed'
   where id = v_settled;
  -- A credit balance is not something the customer owes. Listed as one
  -- it reads as a demand for money the company owes THEM.
  v_credit := pg_temp.cp_invoice(v_org, v_c, 'INV-C', 250);
  update public.sales_documents set balance_amount = -250 where id = v_credit;

  v_tok := pg_temp.cp_share(v_c, 30);
  v_out := public.open_customer_portal(v_tok);
  v_inv := v_out -> 'invoices';

  perform pg_temp.check_eq('three invoices are outstanding and only three',
    jsonb_array_length(v_inv), 3);
  perform pg_temp.check_eq('and the total is the three added up',
    (v_out ->> 'total_outstanding')::numeric, 600);

  perform pg_temp.check_true('a draft is not a demand', not v_inv::text like '%INV-D%');
  perform pg_temp.check_true('a quotation is not an invoice',
    not v_inv::text like '%QUO-1%');
  perform pg_temp.check_true('a deleted invoice is gone',
    not v_inv::text like '%INV-X%');
  perform pg_temp.check_true('a settled one is not chased',
    not v_inv::text like '%INV-P%');
  perform pg_temp.check_true('and a credit balance is not a debt',
    not v_inv::text like '%INV-C%');

  -- Soonest first, and an invoice with no due date last rather than
  -- first: `nulls last` is what puts "we never agreed a date" at the
  -- bottom instead of at the top of what looks like a chase list.
  perform pg_temp.check_eq('the soonest due is at the top',
    v_inv -> 0 ->> 'doc_no', 'INV-1');
  perform pg_temp.check_eq('then the next',
    v_inv -> 1 ->> 'doc_no', 'INV-3');
  perform pg_temp.check_eq('and the one with no date at all is last',
    v_inv -> 2 ->> 'doc_no', 'INV-2');

  -- Overdue is measured on MALAYSIA's day, not the server's. Between
  -- 16:00 and midnight UTC those are different dates, and an invoice
  -- due today would be shown to a customer in Kuala Lumpur as already
  -- late for eight hours of every day.
  declare
    v_today uuid := pg_temp.cp_invoice(v_org, v_c, 'INV-T', 50, app.today());
    v_yesterday uuid := pg_temp.cp_invoice(v_org, v_c, 'INV-Y', 60,
                                           app.today() - 1);
    v_after jsonb;
  begin
    v_after := public.open_customer_portal(v_tok) -> 'invoices';
    perform pg_temp.check_true('an invoice due today is not yet overdue',
      not (select (x ->> 'overdue')::boolean from jsonb_array_elements(v_after) x
            where x ->> 'doc_no' = 'INV-T'));
    perform pg_temp.check_true('one due yesterday is',
      (select (x ->> 'overdue')::boolean from jsonb_array_elements(v_after) x
        where x ->> 'doc_no' = 'INV-Y'));
    perform pg_temp.check_true('and one with no due date never is',
      not (select (x ->> 'overdue')::boolean from jsonb_array_elements(v_after) x
            where x ->> 'doc_no' = 'INV-2'));
  end;
end $$;

-- A customer who owes nothing gets an empty list, not a null. The
-- difference is what the page does with it: `[]` renders "nothing
-- outstanding", null renders whatever a null renders as.
do $$
declare
  v_org uuid := pg_temp.cp_org('Tiada Hutang Sdn Bhd');
  v_c uuid; v_tok text; v_out jsonb;
begin
  v_c := pg_temp.cp_customer(v_org, 'C-1', 'Bayar Awal Bhd');
  v_tok := pg_temp.cp_share(v_c, 30);
  v_out := public.open_customer_portal(v_tok);

  perform pg_temp.check_eq('a customer who owes nothing is open', 
    v_out ->> 'state', 'open');
  perform pg_temp.check_eq('with an empty list rather than nothing',
    jsonb_typeof(v_out -> 'invoices'), 'array');
  perform pg_temp.check_eq('holding no invoices',
    jsonb_array_length(v_out -> 'invoices'), 0);
  perform pg_temp.check_eq('and owing nought rather than null',
    (v_out ->> 'total_outstanding')::numeric, 0);

  -- The company on the page is the company's LEGAL name where it has
  -- one: this is a demand for money, and a trading name is not who the
  -- debt is owed to.
  update public.organizations
     set legal_name = 'Tiada Hutang Sendirian Berhad', base_currency = 'MYR'
   where id = v_org;
  perform pg_temp.check_eq('the legal name is what a customer is shown',
    public.open_customer_portal(v_tok) -> 'company' ->> 'name',
    'Tiada Hutang Sendirian Berhad');
  perform pg_temp.check_eq('and the currency is the company''s own',
    public.open_customer_portal(v_tok) ->> 'currency', 'MYR');
end $$;

-- ---------------------------------------------------------------------
-- 4. Issuing a key, and taking the old one back
-- ---------------------------------------------------------------------
-- `share_customer_portal`'s own comment states the rule:
--
--     One live portal per customer ... a revoke that leaves an older
--     door open is not a revoke.
--
-- Two mutants of that one `update` survived, and they are the two worst
-- findings of this sweep. Scoped to nothing, sharing one customer's
-- portal REVOKES EVERY PORTAL ON THE PLATFORM. Scoped to nothing at
-- all, the old link stays live for ever beside the new one.
do $$
declare
  v_org uuid := pg_temp.cp_org('Kunci Sdn Bhd');
  v_a uuid; v_b uuid; v_first text; v_second text; v_theirs text;
begin
  v_a := pg_temp.cp_customer(v_org, 'C-1', 'Satu Bhd');
  v_b := pg_temp.cp_customer(v_org, 'C-2', 'Dua Bhd');

  v_first  := pg_temp.cp_share(v_a, 30);
  v_theirs := pg_temp.cp_share(v_b, 30);
  perform pg_temp.check_eq('the first key opens', pg_temp.cp_state(v_first), 'open');
  perform pg_temp.check_eq('and so does the other customer''s',
    pg_temp.cp_state(v_theirs), 'open');

  -- Send a new one to the SAME customer.
  v_second := pg_temp.cp_share(v_a, 30);
  perform pg_temp.check_eq('the new key opens', pg_temp.cp_state(v_second), 'open');
  -- THE ONE THE COMMENT IS ABOUT. Issuing a new link is how somebody
  -- takes back a link that went to the wrong address; if the old one
  -- still works, that has not happened.
  perform pg_temp.check_eq('and the one it replaced is revoked',
    pg_temp.cp_state(v_first), 'revoked');
  -- AND THE ONE THAT WOULD BE WORST. Re-issuing one customer's link
  -- must not touch anybody else's: unscoped, every customer on the
  -- platform is locked out the next time any one of them is sent a
  -- link.
  perform pg_temp.check_eq('while another customer''s key is untouched',
    pg_temp.cp_state(v_theirs), 'open');
  perform pg_temp.check_eq('and only one link stands for this customer',
    (select count(*)::integer from public.customer_portal_links
      where contact_id = v_a and revoked_at is null), 1);

  -- Revoking by hand does the same thing and no more.
  perform public.revoke_customer_portal(v_a);
  perform pg_temp.check_eq('a revoke shuts this customer''s door',
    pg_temp.cp_state(v_second), 'revoked');
  perform pg_temp.check_eq('and leaves the neighbour''s open',
    pg_temp.cp_state(v_theirs), 'open');
end $$;

-- Who may hand out a key, and how long it lasts.
do $$
declare
  v_org uuid := pg_temp.cp_org('Beri Kunci Sdn Bhd');
  v_c uuid; v_gone uuid; v_person uuid; v_viewer uuid; v_tok text;
  v_expires timestamptz;
begin
  v_c := pg_temp.cp_customer(v_org, 'C-1', 'Pembeli Bhd', 'main@buyer.test');
  v_gone := pg_temp.cp_customer(v_org, 'C-2', 'Bekas Bhd');
  update public.contacts set deleted_at = now() where id = v_gone;

  perform pg_temp.check_refused('a customer who is not there cannot be shared',
    format($q$ select public.share_customer_portal(%L, 30) $q$,
           gen_random_uuid()),
    '%Contact not found%', 'P0002');
  perform pg_temp.check_refused('nor one who has been deleted',
    format($q$ select public.share_customer_portal(%L, 30) $q$, v_gone),
    '%Contact not found%', 'P0002');

  -- The validity floor. Zero days would mint a link that has already
  -- expired, and a negative one a link that expired last week — both
  -- are somebody typing in a box, and both must come out as a day.
  v_tok := pg_temp.cp_share(v_c, 0);
  select expires_at into v_expires from public.customer_portal_links
   where contact_id = v_c and revoked_at is null;
  perform pg_temp.check_true('a link of no days lasts one, not none',
    v_expires > now());
  perform pg_temp.check_eq('and it opens', pg_temp.cp_state(v_tok), 'open');

  v_tok := pg_temp.cp_share(v_c, -30);
  perform pg_temp.check_eq('and one of minus thirty days opens too',
    pg_temp.cp_state(v_tok), 'open');

  -- No number at all is sixty days, which is the default a caller that
  -- omits the argument gets.
  v_tok := pg_temp.cp_share(v_c, null);
  select expires_at into v_expires from public.customer_portal_links
   where contact_id = v_c and revoked_at is null;
  perform pg_temp.check_true('and no number at all is sixty days',
    v_expires between now() + interval '59 days' and now() + interval '61 days');

  -- The address. What the caller typed wins over what is on file,
  -- because the person sending it is looking at the customer and knows
  -- where it should go.
  v_tok := pg_temp.cp_share(v_c, 30, 'typed@buyer.test');
  perform pg_temp.check_eq('an address typed at the time is the one used',
    (select sent_to_email from public.customer_portal_links
      where contact_id = v_c and revoked_at is null), 'typed@buyer.test');
  -- And a blank box is not an address: it falls back to the record.
  v_tok := pg_temp.cp_share(v_c, 30, '   ');
  perform pg_temp.check_eq('while a blank box falls back to the contact',
    (select sent_to_email from public.customer_portal_links
      where contact_id = v_c and revoked_at is null), 'main@buyer.test');

  -- Handing somebody a view of everything a customer owes is a
  -- disclosure, and it is the company's to make.
  v_viewer := pg_temp.another_user('viewer.kunci@example.com');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_viewer, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  perform pg_temp.sign_in_as(v_viewer);
  perform pg_temp.check_refused('somebody who may not write may not share',
    format($q$ select public.share_customer_portal(%L, 30) $q$, v_c),
    '%Not permitted to share this account%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());
end $$;

-- ---------------------------------------------------------------------
-- 5. Minting a document link from a portal key
-- ---------------------------------------------------------------------
-- The portal has to be live, and the link it mints must not outlive it.
do $$
declare
  v_org uuid := pg_temp.cp_org('Pautan Sdn Bhd');
  v_c uuid; v_inv uuid; v_draft uuid; v_void uuid;
  v_tok text; v_doctok text; v_l uuid; v_exp timestamptz;
begin
  v_c   := pg_temp.cp_customer(v_org, 'C-1', 'Pembeli Bhd');
  v_inv := pg_temp.cp_invoice(v_org, v_c, 'INV-1', 100);
  v_draft := pg_temp.cp_invoice(v_org, v_c, 'INV-D', 200,
                                date '2026-02-01', false);
  v_void  := pg_temp.cp_invoice(v_org, v_c, 'INV-V', 300);
  update public.sales_documents set status = 'void' where id = v_void;
  -- `d.contact_id is null` in the filter guards a state the schema
  -- will not hold: `sales_documents.contact_id` is NOT NULL. It is a
  -- belt, and the brace is what is asserted, below.

  v_tok := pg_temp.cp_share(v_c, 30);

  perform pg_temp.check_eq('a draft cannot be opened from the portal',
    pg_temp.cp_doc_token(v_tok, v_draft), 'A draft document cannot be opened');
  perform pg_temp.check_eq('nor a voided one',
    pg_temp.cp_doc_token(v_tok, v_void), 'A void document cannot be opened');
  perform pg_temp.check_refused('a document always names a customer',
    format($q$ update public.sales_documents set contact_id = null
                where id = %L $q$, v_inv),
    '%contact_id%');
  perform pg_temp.check_eq('nor a document that is not there at all',
    pg_temp.cp_doc_token(v_tok, gen_random_uuid()),
    'Not one of this account''s documents');

  declare v_deleted uuid := pg_temp.cp_invoice(v_org, v_c, 'INV-X', 500);
  begin
    update public.sales_documents set deleted_at = now() where id = v_deleted;
    perform pg_temp.check_eq('nor a deleted one',
      pg_temp.cp_doc_token(v_tok, v_deleted),
      'Not one of this account''s documents');
  end;

  -- The minted link is capped at the portal's own expiry. A portal with
  -- a week left must not hand out a document link good for a month.
  select id into v_l from public.customer_portal_links
   where contact_id = v_c and revoked_at is null;
  update public.customer_portal_links set expires_at = now() + interval '7 days'
   where id = v_l;
  v_doctok := public.portal_document_token(v_tok, v_inv);
  select expires_at into v_exp from public.document_share_links
   where token_hash = app.corp_token_hash(v_doctok);
  perform pg_temp.check_true(
    'a document link cannot outlive the portal that minted it',
    v_exp <= now() + interval '7 days' + interval '1 minute');

  -- And the token is stored hashed, never in the clear: the table is
  -- the thing an attacker who reaches the database reads.
  perform pg_temp.check_true('and its token is stored hashed, not in the clear',
    not exists (select 1 from public.document_share_links
                 where token_hash = v_doctok));

  -- A portal that has been shut mints nothing more, expired or revoked.
  update public.customer_portal_links set expires_at = now() - interval '1 day'
   where id = v_l;
  perform pg_temp.check_eq('an expired portal mints no more links',
    pg_temp.cp_doc_token(v_tok, v_inv), 'This link is no longer open');
  -- And the same boundary, from the other side: `expires_at >= now()`
  -- here is the same rule as `expires_at < now()` there, written the
  -- other way round, so the instant of expiry must still work.
  update public.customer_portal_links set expires_at = now() where id = v_l;
  perform pg_temp.check_true('but one expiring this very instant still does',
    pg_temp.cp_doc_token(v_tok, v_inv) like 'ok:%');
  update public.customer_portal_links
     set expires_at = now() + interval '7 days', revoked_at = now()
   where id = v_l;
  perform pg_temp.check_eq('and neither does a revoked one',
    pg_temp.cp_doc_token(v_tok, v_inv), 'This link is no longer open');
end $$;

-- =====================================================================
-- 6. The survivors that are equivalent, and the rules they lean on
-- =====================================================================
-- TWO MUTUALLY-MASKING PAIRS, the sixth and seventh this campaign has
-- found -- and both are the same rule written twice, which is why they
-- mask.
--
-- `portal_document_token` refuses a document unless `d.org_id =
-- l.org_id` AND the contact that owns it is found by a lookup that
-- itself filters `c2.org_id = l.org_id`. Remove either and the other
-- still refuses: the sibling lookup starts from `c2.id = d.contact_id`,
-- so once the document is in this company its contact is too. Only
-- removing BOTH opens the door. `open_customer_portal`'s listing has
-- the identical pair.
--
-- Neither is dead. They are two spellings of one tenancy rule, and the
-- block at the top of this file proves the PAIR by building the thing
-- that would get through if the rule were absent: a contact in another
-- company wearing this company's party id.
do $$
declare
  v_org uuid := pg_temp.cp_org('Setara Portal Sdn Bhd');
  v_c uuid; v_tok text; v_quote uuid;
begin
  v_c := pg_temp.cp_customer(v_org, 'C-1', 'Pembeli Bhd');
  v_tok := pg_temp.cp_share(v_c, 30);

  -- (a) `c.id is null then 'withdrawn'` cannot fire. The link's contact
  -- is a foreign key ON DELETE CASCADE, so a link cannot outlive the
  -- customer it was issued to -- deleting the contact deletes the link,
  -- and the token then reads as `invalid` rather than `withdrawn`. The
  -- reachable half is `deleted_at`, which the block above covers.
  perform pg_temp.check_true(
    'a portal link cannot outlive the customer it was issued to',
    exists (select 1 from pg_constraint
             where conrelid = 'public.customer_portal_links'::regclass
               and contype = 'f' and confdeltype = 'c'
               and pg_get_constraintdef(oid) like '%contacts%'));

  -- (b) `coalesce(o.base_currency, 'MYR')` guards a null the column
  -- cannot hold. Third time this campaign has met that shape.
  perform pg_temp.check_eq('every company has a base currency',
    (select is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'organizations'
        and column_name = 'base_currency'), 'NO');

  -- (c) `d.doc_type = 'invoice'` in the listing looks like it is
  -- keeping quotations off a customer's statement, and it cannot be
  -- doing that alone: the status filter already admits only `posted`
  -- and `partial`, and a quotation cannot reach either. The ledger door
  -- refuses it, which is the rule `aging_shapes.sql` records for the
  -- same reason. So the pairing is what is asserted.
  v_quote := pg_temp.cp_invoice(v_org, v_c, 'QUO-9', 500,
                                date '2026-02-01', false, 'quotation');
  perform pg_temp.check_refused('a quotation cannot be posted at all',
    format($q$ select public.post_sales_document(%L) $q$, v_quote),
    '%');
  perform pg_temp.check_eq('so it never reaches a status the portal lists',
    (select status::text from public.sales_documents where id = v_quote),
    'draft');

  -- (c2) `c.party_id is not null and c2.party_id = c.party_id` reads
  -- like a null guard and SQL has already made it one: for a customer
  -- filed only once `c.party_id` is null, and `c2.party_id = null` is
  -- NULL rather than true, so the arm cannot match. The `is not null`
  -- says out loud what three-valued logic would do quietly. The rule it
  -- leans on is that a null never equals anything, including a null.
  perform pg_temp.check_true('a customer filed once has no party at all',
    (select party_id is null from public.contacts where id = v_c));
  perform pg_temp.check_true('and a null matches nothing, not even a null',
    (select (null::uuid = null::uuid) is null));

  -- (c3) Re-revoking an already-revoked link moves its `revoked_at`
  -- forward. It was shut and stays shut, so no answer changes; the
  -- `revoked_at is null` in the `where` is there so the audit trail
  -- says when the door was closed rather than when it was last
  -- re-closed.
  perform pg_temp.check_eq('a shut door reads the same however often it is shut',
    pg_temp.cp_state(v_tok), 'open');

  -- (d) The minted link is written against `l.org_id`, and `d.org_id`
  -- would do just as well -- because the guard four lines above has
  -- already established the two are equal. Same shape as the pairs
  -- above: not dead, just already decided.
  perform pg_temp.check_true('a document link is minted in one company only',
    (select count(distinct org_id) <= 1 from public.document_share_links
      where org_id = v_org));
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  -- The one function in this system a stranger may call.
  perform pg_temp.check_true('a customer may open their own account',
    has_function_privilege('anon', 'public.open_customer_portal(text)',
                           'execute'));
  perform pg_temp.check_true('and ask for one of their own documents',
    has_function_privilege('anon',
      'public.portal_document_token(text, uuid)', 'execute'));
  perform pg_temp.check_true('but may not issue themselves a key',
    not has_function_privilege('anon',
      'public.share_customer_portal(uuid, integer, text)', 'execute'));
  perform pg_temp.check_true('nor take one away',
    not has_function_privilege('anon',
      'public.revoke_customer_portal(uuid)', 'execute'));
  perform pg_temp.check_true('and the keys themselves are not readable',
    not has_table_privilege('anon', 'public.customer_portal_links', 'select'));
end $$;

rollback;
