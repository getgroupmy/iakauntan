-- =====================================================================
-- iAkauntan :: 0730 the door behind the twelve
--
-- `0727`, `0728` and `0729` closed the fallbacks: a posting function
-- that was handed no bank account used to credit account 1120 -- "Bank
-- Accounts", the HEADING that `upsert_bank_account` hangs the real ones
-- beneath in 1121-1199 -- and the entry balanced, reported and
-- reconciled against nothing. Those all refuse now.
--
-- This closes the other way in, which refusing a MISSING account never
-- touched: **a bank account whose own ledger account IS the heading.**
-- A posting naming one of those passes every null check and lands on
-- the heading anyway. Twelve companies have one -- active, named "CIMB
-- Current Account", "Maybank Current Account", with real balances --
-- and that is most of the 97 lines sitting on the heading across 14
-- companies.
--
-- **Nothing here moves a posted line, and the twelve rows are left
-- exactly as they are, by the user's decision.** What changes is that a
-- THIRTEENTH cannot be made.
--
-- ## Why this is a trigger and not another guard
--
-- `upsert_bank_account` already refuses a handed-in ledger account
-- unless it is a non-group bank or cash account. Account 1120 is seeded
-- `is_group = false` with subtype `bank`, so it passes that guard --
-- which is exactly how the twelve came to exist through the product's
-- own screen. A seventh guard in that function would close the screen
-- and leave every other writer open, and there are five others.
--
-- ## The update that must keep working
--
-- The trigger returns early when an UPDATE leaves `account_id` alone.
-- That is not tidiness: `current_balance` is written by every posting
-- function and by `resync_bank_balance`, so a trigger that refused
-- those twelve rows' updates would stop their reconciliations to make a
-- point about a column nobody is changing. They can still be renamed,
-- rebalanced and deactivated. They cannot be repointed AT the heading,
-- and nothing new can be created on it.
--
-- ## What the fixtures cost, measured
--
-- `supabase/tests` could not have caught any of this, because **69
-- fixture sites across 29 files hung their bank account on the heading
-- themselves** -- so "the function used the account it was handed" and
-- "the function fell through to the heading" were the same row. A first
-- attempt at this trigger failed 29 of the 382 assertion files, which
-- is how that number was measured rather than guessed. The sweep is in
-- this commit: those sites now use `pg_temp.test_bank_account`, which
-- does what `0529` does, and the assertions that read the heading read
-- the fixture's own account instead.
--
-- Two of those sites were not fixtures but CLAIMS, and both had to go:
-- `bank_accounts.sql` asserted that "a caller may name the GL account
-- itself" by naming 1120 and checking it was accepted. It was. It is
-- now the refusal, with the control beside it.
--
-- ## The four demo seeders, and the one the allow-list missed
--
-- Four seeders insert a `bank_accounts` row on the heading, so the
-- trigger would have broken `app.demo_rebuild()` in production on the
-- next reseed -- found by looking for the writers before writing the
-- trigger, not after. They are restated here from
-- `pg_get_functiondef` against production, md5-verified first, with
-- only the bank account changed:
--
--   app.demo_sinar_bank        0dbbfbbd6d4fb0f7a2e1b5b9b85ce25b
--   app.demo_purchases         71b611df14ade732378b03c7f31e6895
--   app.demo_practice_books    c5d41ea2ba8f3db7edb76386677bed02
--   app.demo_legal_guaman      6c4a4121f4998d7422044d06960f4fc3
--
-- `app.demo_purchases` is the interesting one. **`0729`'s allow-list
-- does not contain it, and should have:** its body reads
--
--     where org_id = p_org and code = case when p_bank_type = 'cash'
--                                          then '1110' else '1120' end
--
-- so the sweep for a body matching the heading's code as a literal
-- comparison never saw it. That is the third time in three days that a
-- pattern-match stood in for a question about behaviour -- run 2183's
-- lesson, then `0729`'s nine-versus-one, now this. The assertion in
-- `money_names_the_account.sql` is a net with a known mesh, and this
-- migration's header is the place that says so.
--
-- The seeders now call `app.demo_bank_account`, which hands back an
-- account the org already has -- heading and all, because a seeder has
-- no business moving a posted line -- and otherwise makes one in
-- 1121-1199 the way `0529` does. `demo_sinar_bank` then reads its
-- ledger account OFF the bank account, because its paid-up capital
-- journal must debit the same account the receipts credit; posting one
-- to the heading and the other to the child would leave the demo's
-- bank balance disagreeing with the demo's bank ledger.
--
-- A cash till still points at 1110 "Cash in hand". That is a leaf with
-- nothing beneath it, and `bank_accounts.account_type` has permitted
-- `cash` since `0003`, so a till is an ordinary bank account and the
-- rule here is about the heading, not about cash.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A bank account a demo seeder can have without using the heading
-- ---------------------------------------------------------------------
--
-- Returns the one the company already has, or makes one. An org that
-- has been seeded before keeps the account it has -- heading and all --
-- because a seeder's job is to put books in front of somebody, not to
-- repoint an account that already carries postings. That decision
-- belongs to a person.
--
-- `is_client_account` is excluded from the search for the same reason
-- `app.demo_purchases` excludes it: a law firm has two, and paying the
-- firm's own supplier out of money held for a client is the breach of
-- rule 7 of the Solicitors' Accounts Rules 1990 that `0430` exists to
-- make visible.
create or replace function app.demo_bank_account(
  p_org            uuid,
  p_name           text,
  p_bank_name      text default null,
  p_account_number text default null,
  p_type           text default 'current',
  p_bank_code      text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id     uuid;
  v_gl     uuid;
  v_code   text;
  v_parent uuid;
begin
  select b.id into v_id from public.bank_accounts b
   where b.org_id = p_org and b.is_active and not b.is_client_account
   order by b.is_default desc, b.created_at
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  if p_type = 'cash' then
    -- A leaf, and the one a till belongs on. Unchanged from what the
    -- seeders did before.
    select id into v_gl from public.accounts
     where org_id = p_org and code = '1110';
  end if;

  if v_gl is null then
    select id into v_parent from public.accounts
     where org_id = p_org and code = '1100' limit 1;

    -- The next code with no LIVE account on it.
    select to_char(n, 'FM0000') into v_code
      from generate_series(1121, 1199) as n
     where not exists (
       select 1 from public.accounts a
        where a.org_id = p_org and a.code = to_char(n, 'FM0000')
          and a.deleted_at is null)
     order by n
     limit 1;

    if v_code is null then
      raise exception 'The bank range 1121-1199 is full in this company.'
        using errcode = '23514';
    end if;

    -- `0532`: the chart holds one account per code, retired ones
    -- included -- `accounts_org_id_code_key` does not care that a row
    -- is soft-deleted -- so a code whose account was retired must be
    -- REVIVED and cannot be inserted. `supabase/tests/account_revival.sql`
    -- counts the helpers that forget, and caught this one.
    v_gl := app.revive_account(p_org, v_code);
    if v_gl is null then
      insert into public.accounts
        (org_id, code, name, account_type, account_subtype, parent_id,
         is_group)
      values (p_org, v_code, p_name, 'asset', 'bank', v_parent, false)
      returning id into v_gl;
    end if;
  end if;

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, bank_code, account_number,
     account_type, currency, opening_balance, current_balance,
     is_active, is_default)
  values (p_org, v_gl, p_name, p_bank_name, p_bank_code, p_account_number,
          p_type, 'MYR', 0, 0, true,
          not exists (select 1 from public.bank_accounts b
                       where b.org_id = p_org and b.is_active))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function app.demo_bank_account(uuid, text, text, text, text, text) is
  'The bank account a demo tenant pays from: the one it already has, or '
  'a new one on its own ledger account in 1121-1199. Demo seeders used '
  'to insert one on the 1120 heading, which 0730 refuses.';

revoke all on function app.demo_bank_account(uuid, text, text, text, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- app.demo_sinar_bank -- restated, bank account changed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_sinar_bank(p_org uuid, p_owner uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_bank_gl  uuid;
  v_capital  uuid;
  v_bank     uuid;
  v_doc      record;
  v_id       uuid;
  v_date     date;
  v_receipts integer := 0;
  v_payments integer := 0;
  v_in       numeric(18,2) := 0;
  v_out      numeric(18,2) := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_capital from public.accounts where org_id = p_org and code = '3100';

  -- On a ledger account of its own rather than on the heading, and
  -- `v_bank_gl` is read OFF it: the paid-up capital journal below
  -- debits the same account the receipts and payments credit, and if
  -- those two disagreed the demo's bank balance would not be the demo's
  -- bank ledger.
  v_bank := app.demo_bank_account(
    p_org, 'Maybank Current Account', 'Malayan Banking Berhad',
    '514233880011', 'current', 'MBBEMYKL');
  select account_id into v_bank_gl from public.bank_accounts where id = v_bank;

  perform public.create_gl_entry(
    p_org, date_trunc('year', app.today())::date + 1, 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank_gl,
        'description', 'Paid-up capital', 'debit', 700000, 'credit', 0),
      jsonb_build_object('account_id', v_capital,
        'description', 'Paid-up capital', 'debit', 0, 'credit', 700000)),
    'Issue of ordinary shares — paid-up capital', null, null, 'SC-2026-01');

  for v_doc in select d.id, d.doc_no, d.contact_id, d.doc_date, d.total_amount
                 from public.sales_documents d
                where d.org_id = p_org and d.doc_type = 'invoice'
                  and d.status = 'posted'
                  and d.doc_date <= app.today() - 45
                order by d.doc_date, d.doc_no loop
    v_date := least(v_doc.doc_date + 21, app.today());

    insert into public.receipts (org_id, receipt_no, receipt_date, contact_id,
                                 payment_mode_code, bank_account_id, reference,
                                 currency, exchange_rate, amount, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'receipt'), v_date,
            v_doc.contact_id, '03', v_bank, 'Settlement of ' || v_doc.doc_no,
            'MYR', 1, v_doc.total_amount, p_owner)
    returning id into v_id;

    insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
    values (p_org, v_id, v_doc.id, v_doc.total_amount);

    perform public.post_receipt(v_id);
    v_receipts := v_receipts + 1;
    v_in := v_in + v_doc.total_amount;
  end loop;

  for v_doc in select d.id, d.doc_no, d.contact_id, d.doc_date, d.total_amount
                 from public.purchase_documents d
                where d.org_id = p_org and d.doc_type = 'bill'
                  and d.status = 'posted'
                  and d.doc_date <= app.today() - 60
                order by d.doc_date, d.doc_no loop
    v_date := least(v_doc.doc_date + 35, app.today());

    insert into public.purchase_payments (org_id, payment_no, payment_date, contact_id,
                                          payment_mode_code, bank_account_id, reference,
                                          currency, exchange_rate, amount, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'payment'), v_date,
            v_doc.contact_id, '03', v_bank, 'Settlement of ' || v_doc.doc_no,
            'MYR', 1, v_doc.total_amount, p_owner)
    returning id into v_id;

    insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
    values (p_org, v_id, v_doc.id, v_doc.total_amount);

    perform public.post_purchase_payment(v_id);
    v_payments := v_payments + 1;
    v_out := v_out + v_doc.total_amount;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar cash: %s receipts (%s) and %s supplier payments (%s).',
                v_receipts, v_in, v_payments, v_out);
end $function$;

-- ---------------------------------------------------------------------
-- app.demo_purchases -- restated, bank account changed
--
-- This is the one `0729`'s allow-list missed, because its heading
-- lookup was a CASE expression rather than the literal comparison the
-- sweep matches on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_purchases(p_org uuid, p_owner uuid, p_supplier text, p_supplier_code text, p_what text, p_account_code text, p_amount numeric, p_bank_name text, p_bank_code text, p_bank_no text, p_bank_type text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_supp    uuid;
  v_acct    uuid;
  v_bank    uuid;
  v_doc     uuid;
  v_pay     uuid;
  v_settled numeric(18,2);
  v_open    numeric(18,2);
  v_date    date;
begin
  perform app.demo_act_as(p_owner);

  -- The bank the money leaves from. Five of the six had no
  -- `bank_accounts` row at all -- measured on a rebuild -- and without
  -- one `post_purchase_payment` has no account to credit.
  --
  -- `p_bank_name` is the account's NAME and `p_bank_code` is the bank's,
  -- which is how every caller passes them; the parameter names are the
  -- misleading part, not the mapping.
  v_bank := app.demo_bank_account(
    p_org, p_bank_name, p_bank_code, p_bank_no, p_bank_type);

  select id into v_acct from public.accounts
   where org_id = p_org and code = p_account_code;

  insert into public.contacts
    (org_id, code, name, contact_type, email, phone)
  values (p_org, p_supplier_code, p_supplier, 'supplier',
          lower(replace(p_supplier_code, '-', '')) || '@pembekal.demo',
          '03-8000 1000')
  on conflict (org_id, code) do nothing;
  select id into v_supp from public.contacts
   where org_id = p_org and code = p_supplier_code;

  -- The settled one, two months back, so the payment has somewhere to
  -- sit between the bill and today.
  v_settled := round(p_amount, 2);
  v_date    := app.today() - 75;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_date, v_date + 30, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, uom_code, unit_price, account_id)
  values (p_org, v_doc, 1, 'item', p_what, 1, 'C62', v_settled, v_acct);

  perform public.post_purchase_document(v_doc);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, payment_mode_code,
     bank_account_id, reference, currency, exchange_rate, amount, created_by)
  select p_org, app.next_document_number_internal(p_org, 'payment'),
         v_date + 28, v_supp,
         case when p_bank_type = 'cash' then '01' else '03' end,
         v_bank, 'Settlement of ' || d.doc_no, 'MYR', 1, d.total_amount,
         p_owner
    from public.purchase_documents d where d.id = v_doc
  returning id into v_pay;

  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  select p_org, v_pay, d.id, d.total_amount
    from public.purchase_documents d where d.id = v_doc;

  perform public.post_purchase_payment(v_pay);

  -- And the one still owed. Forty days old, so it is past its terms and
  -- lands in an ageing bucket rather than in "current".
  v_open := round(p_amount * 0.6, 2);
  v_date := app.today() - 40;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_date, v_date + 30, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, uom_code, unit_price, account_id)
  values (p_org, v_doc, 1, 'item', p_what, 1, 'C62', v_open, v_acct);

  perform public.post_purchase_document(v_doc);

  perform app.demo_sync_bank_balance(p_org);
  perform set_config('request.jwt.claims', '', true);

  return format('%s: 2 bills from %s, %s paid and %s outstanding.',
                p_supplier_code, p_supplier, v_settled, v_open);
end $function$;

-- ---------------------------------------------------------------------
-- app.demo_practice_books -- restated, bank account changed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_practice_books(p_org uuid, p_owner uuid, p_what text, p_fee numeric, p_customer text DEFAULT 'Kumpulan Awan Sdn Bhd'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rev      uuid;
  v_na       uuid;
  v_rate     numeric;
  v_cust     uuid;
  v_bank     uuid;
  v_doc      uuid;
  v_rcp      uuid;
  v_month    date;
  v_date     date;
  v_raised   integer := 0;
  v_settled  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_rev from public.accounts
   where org_id = p_org and code = '4100';
  select id, rate into v_na, v_rate from public.tax_codes
   where org_id = p_org and code = 'NA';

  insert into public.contacts (org_id, code, name, contact_type, entity_type,
                               email, city, state_code, created_by)
  values (p_org, 'CUST-001', p_customer, 'customer', 'sdn_bhd',
          'accounts@kumpulanawan.demo', 'Kuala Lumpur', '14', p_owner)
  on conflict (org_id, code) do nothing;
  select id into v_cust from public.contacts
   where org_id = p_org and code = 'CUST-001';

  -- The account number is still derived from the org id, so a reseed of
  -- the same company produces the same number.
  v_bank := app.demo_bank_account(
    p_org, 'Current account', 'Malayan Banking Berhad',
    '5' || lpad((abs(hashtext(p_org::text)) % 100000000)::text, 11, '0'));

  v_month := date_trunc('year', app.today())::date;
  while v_month <= app.today() loop
    v_date := least(v_month + 6, app.today());

    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, subject, created_by)
    values (p_org, 'invoice',
            app.next_document_number_internal(p_org, 'invoice'),
            v_date, v_date + 30, v_cust, 'draft', 'MYR', 1,
            p_what || ' — ' || to_char(v_month, 'Mon YYYY'), p_owner)
    returning id into v_doc;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description,
       quantity, unit_price, tax_code_id, tax_rate, account_id)
    values (p_org, v_doc, 1, 'item', p_what, 1, p_fee, v_na, v_rate, v_rev);

    perform public.post_sales_document(v_doc);
    v_raised := v_raised + 1;

    -- Anything older than two months has been paid. The two that have
    -- not are what the portfolio's "who owes what" is made of, and what
    -- a single payment across four companies settles.
    if v_date < (app.today() - 60) then
      insert into public.receipts
        (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
         payment_mode_code, currency, exchange_rate, amount,
         unapplied_amount, reference, created_by)
      values (p_org, app.next_document_number_internal(p_org, 'receipt'),
              v_date + 30, v_cust, v_bank, '03', 'MYR', 1, p_fee, p_fee,
              'Bank transfer', p_owner)
      returning id into v_rcp;

      perform public.allocate_with_discount(v_rcp, v_doc, p_fee, null,
                                            v_date + 30);
      perform public.post_receipt(v_rcp);
      v_settled := v_settled + 1;
    end if;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('%s: %s invoices, %s settled.',
                (select name from public.organizations where id = p_org),
                v_raised, v_settled);
end $function$;

-- ---------------------------------------------------------------------
-- app.demo_legal_guaman -- restated, office account changed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_legal_guaman(p_org uuid, p_owner uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_today  date := app.today();
  v_client uuid;
  v_office uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_txn uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid;
  v_rate numeric(18, 2) := 450.00;
  v_inv1 uuid;
  v_inv2 uuid;
  v_held numeric(18, 2);
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  -- The client account, 1150 and 2300, all from the setup function
  -- rather than by hand: a client account this seed created itself
  -- might not be one `is_client_account` recognises, and then the whole
  -- demo would be office money wearing a label.
  perform public.setup_legal_module(p_org);
  select b.id into v_client from public.bank_accounts b
   where b.org_id = p_org and b.is_client_account;
  if v_client is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Guaman Aziz: skipped, the legal setup made no client account.';
  end if;

  -- The firm's OWN account, on a ledger account of its own. It used to
  -- be the 1120 heading, which made the fee crossing below a movement
  -- between an account and the parent of every account -- the one thing
  -- this demo exists to show, shown wrong.
  v_office := app.demo_bank_account(
    p_org, 'Office Current', 'Maybank', '514022331');

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-001', 'Puan Aminah Yusof', 'customer',
          'aminah@guamanaziz.demo') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-002', 'Encik Rajan Menon', 'customer',
          'rajan@guamanaziz.demo') returning id into v_c2;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-003', 'Lim Holdings Sdn Bhd', 'customer',
          'accounts@limholdings.demo') returning id into v_c3;

  v_m1 := public.open_matter(
    p_org, 'M-2026-001', 'Sale of a house at Taman Seri',
    v_c1, 'Chong Wei Seng', 'conveyancing', p_owner, p_owner,
    null, v_rate, null);
  v_m2 := public.open_matter(
    p_org, 'M-2026-002', 'Tenancy dispute — Lot 14 Jalan Ampang',
    v_c2, 'Harta Sewa Sdn Bhd', 'litigation', p_owner, p_owner,
    null, v_rate, null);
  v_m3 := public.open_matter(
    p_org, 'M-2026-003', 'Shareholders'' agreement',
    v_c3, null, 'corporate', p_owner, p_owner,
    6000, v_rate, null);

  -- ------------------------------------------------------------------
  -- The client-money cycle, on the conveyancing matter
  -- ------------------------------------------------------------------
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     created_by)
  values (p_org, v_m1, 'CT-2026-001', v_today - 45, 'receipt',
          v_client, 50000, 'MYR',
          'Deposit and completion money on account', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- Negative, because `post_client_transaction` takes the amount as the
  -- caller signs it: `v_amount := v_txn.amount` and the double entry is
  -- built from `greatest(v_amount, 0)` and `greatest(-v_amount, 0)`.
  -- Money out written as a positive number would debit the client bank
  -- again -- the demo would show RM96,800 held against RM50,000 ever
  -- received, and the books would still balance.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     payee, created_by)
  values (p_org, v_m1, 'CT-2026-002', v_today - 20, 'payment',
          v_client, -42300, 'MYR',
          'Balance purchase price to the vendor''s solicitors',
          'Tetuan Chong & Co', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- The only lawful way the firm's fee crosses from client to office,
  -- and 0549 is where it became lawful. This block used to write the
  -- transfer on its own: the client ledger went down by 4,500, the
  -- office account was never debited, and there was no bill for it to
  -- settle. The demo showed the movement doing the wrong thing, which
  -- is worse than not showing it.
  --
  -- A fee is billed first, because that is the order the rules impose:
  -- money is not taken out of client account until there is a rendered
  -- bill to take it against.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, matter_id,
     status, currency, exchange_rate, subject, created_by)
  values (p_org, 'invoice',
          app.next_document_number_internal(p_org, 'invoice'),
          v_today - 14, v_today, v_c1, v_m1, 'draft', 'MYR', 1,
          'Fees and disbursements on the completed sale', p_owner)
  returning id into v_inv1;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, unit_price, account_id)
  select p_org, v_inv1, 1, 'item',
         'Professional fees, sale of the property', 1, 4500, a.id
    from public.accounts a
   where a.org_id = p_org and a.account_type = 'revenue'
   order by a.code
   limit 1;

  perform public.post_sales_document(v_inv1);

  -- And then the crossing, both legs: out of the client account, into
  -- the office one, against that bill.
  perform public.settle_from_client_account(
    v_m1, v_inv1, 4500, v_today - 12, v_office);

  -- ------------------------------------------------------------------
  -- Time, on the two matters that are billed by the hour
  -- ------------------------------------------------------------------
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, activity_code,
     minutes, hourly_rate, amount, is_billable)
  values
    (p_org, v_m2, p_owner, v_today - 30,
     'Client attendance and review of the tenancy agreement', 'ATTEND',
     90, v_rate, round(90 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 26,
     'Letter of demand drafted and sent', 'DRAFT',
     120, v_rate, round(120 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 18,
     'Telephone attendance on the opposing solicitors', 'ATTEND',
     30, v_rate, round(30 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 15,
     'Internal file note after the without-prejudice call', 'ADMIN',
     20, v_rate, round(20 / 60.0 * v_rate, 2), false),
    -- More hours than the agreed fee covers, which is what
    -- `report_matters_over_agreed_fee` exists to say out loud.
    (p_org, v_m3, p_owner, v_today - 40,
     'First draft of the shareholders'' agreement', 'DRAFT',
     360, v_rate, round(360 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 33,
     'Two rounds of amendments after the board meeting', 'DRAFT',
     300, v_rate, round(300 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 22,
     'Completion meeting and execution', 'ATTEND',
     240, v_rate, round(240 / 60.0 * v_rate, 2), true);

  -- The litigation matter is billed; the corporate one is not, so the
  -- over-the-agreed-fee report has an open matter to report on rather
  -- than a closed one nobody can act on.
  v_inv2 := public.bill_matter_time(v_m2, v_today - 40, v_today,
                                    v_today + 14);

  -- Read from the bank account the postings moved, not recomputed from
  -- the transactions with a sign convention of this function's own. A
  -- summary that does its own arithmetic can agree with itself while
  -- disagreeing with the ledger, which is how the sign error above
  -- survived its first run: the sentence said RM3,200 and the client
  -- account held RM96,800.
  select current_balance into v_held
    from public.bank_accounts where id = v_client;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Guaman Aziz: 3 matters for 3 clients, RM%s still held in the '
    'client account after completion money out and the fee transferred '
    'to office, one matter billed by the hour and one over its agreed '
    'fee.', to_char(v_held, 'FM999,999,990.00'));
end $function$;

-- ---------------------------------------------------------------------
-- And the picker stops offering it
-- ---------------------------------------------------------------------
--
-- `public.unregistered_bank_accounts` (`0689`, md5
-- 081e1d37b2300f7ee329d252739ed1ec) lists chart accounts money can sit
-- in that no bank account points at, and the dialog registers whichever
-- one is chosen through `upsert_bank_account`. It excludes groups and
-- says why: "a group heading cannot hold a balance and
-- `upsert_bank_account` refuses one anyway".
--
-- 1120 is not a group. In a company where nothing points at it yet it
-- was in that list -- so after the trigger above, the dialog would
-- offer a row that is refused on arrival, which is the exact thing that
-- function's own comment exists to avoid. One more line in the `where`.
--
-- The comment is EXTENDED by a sentence rather than rewritten. Run 2185
-- was a red build caused by replacing one of these outright: a
-- `comment on function` is published in `docs/api/openapi.json` and
-- `llms.txt`, and the rewrite silently dropped three documented
-- refusals.
create or replace function public.unregistered_bank_accounts(
  p_org_id uuid)
returns table (
  account_id      uuid,
  code            text,
  name            text,
  account_subtype app.account_subtype,
  balance         numeric)
language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
  select a.id, a.code, a.name, a.account_subtype,
         round(coalesce(a.current_balance, 0), 2)
    from public.accounts a
   where a.org_id = p_org_id
     -- Only somebody who may post the books. Registering one is a
     -- change to how money is recorded, and `upsert_bank_account`
     -- refuses anybody else anyway -- so offering the list to a reader
     -- would be offering a button that cannot be pressed.
     and app.can_post(p_org_id)
     and a.deleted_at is null
     -- Money can sit in it. A group heading cannot hold a balance and
     -- `upsert_bank_account` refuses one anyway.
     and not a.is_group
     -- Nor the bank heading, which is not a group and is still a
     -- heading: `app.bank_account_not_the_heading` refuses it, so
     -- offering it would be offering a button that cannot be pressed.
     -- 0730.
     and a.code <> '1120'
     and a.account_subtype in ('bank', 'cash')
     -- And nothing already points at it, active or not.
     and not exists (
       select 1 from public.bank_accounts b where b.account_id = a.id)
   order by a.code;
$$;

comment on function public.unregistered_bank_accounts(uuid) is
  'Chart accounts money can sit in that no bank account points at -- '
  'the ones somebody added under Bank on the chart and then went '
  'looking for in a bank dropdown. Answers the question; decides '
  'nothing. Registering one is `upsert_bank_account` with its '
  '`p_account_id`, which has accepted an existing account since 0529. '
  'A deactivated bank account still counts as registered, because '
  'offering it again would make a second bank account against one '
  'ledger account. 0689. The 1120 bank heading is left out as well: '
  'it is not a group, so the group test misses it, and 0730 refuses a '
  'bank account on it.';

-- ---------------------------------------------------------------------
-- The door
-- ---------------------------------------------------------------------
--
-- The heading's code is held in a constant rather than written into the
-- comparison, because `pg_get_functiondef` returns a function's
-- comments as part of its body and
-- `supabase/tests/money_names_the_account.sql` sweeps those bodies for
-- the literal comparison this file exists to prevent. A trigger that
-- enforced the rule by spelling it the forbidden way would fail the
-- assertion that polices it -- which `0729` met the first time and is
-- the reason this reads as it does.
create or replace function app.bank_account_not_the_heading()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_heading constant text := '1120';
  v_this    text;
  v_group   boolean;
begin
  -- A balance is not a repointing. `current_balance` is written by
  -- every posting function and by `resync_bank_balance`, and the twelve
  -- companies already on the heading must keep reconciling.
  if tg_op = 'UPDATE'
     and new.account_id is not distinct from old.account_id then
    return new;
  end if;

  -- Cannot currently fire: `bank_accounts.account_id` is `not null`.
  -- Kept because a trigger that assumes its own table's constraints is
  -- a trigger that breaks the day one is relaxed, and because the
  -- failure it would hide here is a bank account with no ledger account
  -- at all, which is the same harm one directory along.
  if new.account_id is null then
    return new;
  end if;

  select a.code, a.is_group into v_this, v_group
    from public.accounts a
   where a.id = new.account_id;

  if v_group then
    raise exception
      'Account % is a heading, not an account money can sit in. A bank '
      'account needs a ledger account of its own: pick one beneath it, '
      'or let upsert_bank_account make one.', v_this
      using errcode = '23514';
  end if;

  if v_this = v_heading then
    raise exception
      'Account % is the heading the bank accounts hang beneath, so a '
      'balance there belongs to no reconciliation and agrees with no '
      'statement. upsert_bank_account makes one in 1121-1199 -- use '
      'that, or choose an account already there.', v_this
      using errcode = '23514';
  end if;

  return new;
end;
$$;

comment on function app.bank_account_not_the_heading() is
  'Refuses a bank account whose ledger account is a heading, or is the '
  'seeded bank heading itself. BEFORE, so no such row is ever written. '
  'An UPDATE that leaves account_id alone is let through, so the twelve '
  'companies already on the heading keep reconciling and keep their '
  'balances; 0730 moves nothing already posted.';

drop trigger if exists bank_account_not_the_heading on public.bank_accounts;
create trigger bank_account_not_the_heading
  before insert or update on public.bank_accounts
  for each row execute function app.bank_account_not_the_heading();

comment on column public.bank_accounts.account_id is
  'The ledger account this bank account IS. Enforced by '
  'app.bank_account_not_the_heading(): never a heading, and never the '
  'seeded bank heading, because a balance there reconciles against '
  'nothing.';
