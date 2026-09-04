-- =====================================================================
-- iAkauntan :: the certificates a withholding run has to refuse
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/withholding_shapes.sql
--
-- `withholding.sql` pins the rates in the Act, the arithmetic, the
-- journal and the late-payment penalty. A mutation sweep of the four
-- functions under it still killed only 23 of 48 one-line mutants, and
-- the reason is worth naming on its own:
--
--   **AN ASSERTION THAT CATCHES AN ERROR CODE CATCHES ANY ERROR WITH
--   THAT CODE.** `withholding.sql` proves an unposted bill is refused by
--   calling it and catching `22023`. Delete the unposted-bill guard
--   entirely and the call still raises `22023` -- from the NEXT guard,
--   because a draft bill's balance is nought and any tax is more than
--   nought. The test passes, the guard is gone, and nothing says so.
--
-- The rest of what lived was permissions -- `withholding.sql` checks
-- who may EXECUTE the functions and never signs in as somebody who may
-- not POST -- and the whole of `remit_withholding`'s bank account.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ws_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end $$;

create or replace function pg_temp.ws_supplier(
  p_org uuid, p_code text, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, p_name, 'supplier')
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.ws_bill(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric,
  p_date date default date '2026-02-10',
  p_currency char(3) default 'MYR', p_rate numeric default 1,
  p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id,
     currency, exchange_rate, status)
  values (p_org, 'bill', p_no, p_date, p_date + 30, p_contact,
          p_currency, p_rate, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Technical services', 1, p_amount);
  if p_post then perform public.post_purchase_document(v_doc); end if;
  return v_doc;
end $$;

-- =====================================================================
-- 1. The account the tax is held in
-- =====================================================================
do $$
declare
  v_org uuid;
  r     record;
begin
  v_org := pg_temp.ws_org('Akaun Pegangan Sdn Bhd');

  -- The bootstrap chart already carries 2145, so the branch that BUILDS
  -- one is only reached by a company whose chart does not -- which is
  -- every company that has edited its own since `0500`, and every
  -- company seeded before the account existed. Taking it away is how
  -- that branch is reached at all.
  delete from public.accounts where org_id = v_org and code = '2145';
  perform app.withholding_account(v_org);

  select * into r from public.accounts
   where org_id = v_org and code = '2145';
  perform pg_temp.check_true('an absent account is built', r.id is not null);

  -- MUTANTS: the account created as an ASSET, and created with no
  -- parent. Tax withheld from a supplier is money the company is
  -- holding for LHDN: it belongs on the liabilities side of the balance
  -- sheet, under the tax it will be paid over with. Filed as an asset it
  -- would net off against the bank; filed with no parent it would sit
  -- outside the tax grouping the balance sheet is built from and the
  -- statement would still add up.
  perform pg_temp.check_eq('the withholding payable is a liability',
    r.account_type::text, 'liability');
  perform pg_temp.check_eq('and a tax one', r.account_subtype::text,
    'tax_payable');
  perform pg_temp.check_eq('filed under the other tax liabilities',
    (select code from public.accounts where id = r.parent_id), '2100');
  perform pg_temp.check_true('and it is not a heading',
    not r.is_group);

  raise notice 'ok   the account the tax is held in';
end $$;

-- =====================================================================
-- 2. What create_withholding refuses, and for the right reason
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_supp  uuid;
  v_bill  uuid;
  v_draft uuid;
  v_gone  uuid;
  v_said  text;
  v_id    uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Enggan Sdn Bhd');
  v_supp := pg_temp.ws_supplier(v_org, 'S-1', 'Overseas Ltd');
  v_bill := pg_temp.ws_bill(v_org, v_supp, 'BILL-1', 100000);

  -- MUTANT: `if not found then raise 'Bill % not found'` -> false. A
  -- caller-supplied id that names nothing has to be refused by name, not
  -- fall through into a null record.
  begin
    perform public.create_withholding(gen_random_uuid(), 'S109B_SPECIAL');
    raise exception 'FAIL: a bill that does not exist was withheld from';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a bill that does not exist is refused';
  end;

  -- MUTANT: `and deleted_at is null` dropped. A bill somebody removed is
  -- not a bill, and a certificate against one would settle a payable
  -- that no longer has a document behind it.
  v_gone := pg_temp.ws_bill(v_org, v_supp, 'BILL-DEL', 5000);
  update public.purchase_documents set deleted_at = now() where id = v_gone;
  begin
    perform public.create_withholding(v_gone, 'S109B_SPECIAL');
    raise exception 'FAIL: a deleted bill was withheld from';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a deleted bill is refused';
  end;

  -- MUTANT: `if v_bill.gl_entry_id is null` -> false.
  --
  -- THE ASSERTION THAT WAS PASSING FOR THE WRONG REASON. A draft bill
  -- with NO LINES has a balance of nought, so any tax is more than the
  -- balance and the NEXT guard raises the same `22023`. The draft here
  -- carries RM50,000 of lines, so its balance would be ample -- the only
  -- thing standing between it and a certificate is the guard under test.
  -- And the message is checked, not just the code.
  v_draft := pg_temp.ws_bill(v_org, v_supp, 'BILL-DRAFT', 50000,
                             date '2026-02-10', 'MYR', 1, false);
  begin
    perform public.create_withholding(v_draft, 'S109B_SPECIAL',
                                      p_gross_amount => 1000);
    raise exception 'FAIL: withheld against a bill that was never posted';
  exception when sqlstate '22023' then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true(
      'and it is refused for being unposted, not for being empty',
      v_said like '%Post the bill%');
    raise notice 'ok   an unposted bill is refused, by name';
  end;

  -- MUTANT: `and is_active` dropped on the type lookup. A section
  -- repealed or superseded is switched off rather than deleted, because
  -- certificates already raised under it still name it -- and a new
  -- certificate must not be.
  update public.ref_withholding_types set is_active = false
   where code = 'S109F_OTHER';
  begin
    perform public.create_withholding(v_bill, 'S109F_OTHER');
    raise exception 'FAIL: a withholding type no longer in force was used';
  exception when sqlstate '22023' then
    raise notice 'ok   a type that is no longer in force is refused';
  end;
  update public.ref_withholding_types set is_active = true
   where code = 'S109F_OTHER';

  -- MUTANT: `if v_gross <= 0` -> false. A bill of nothing, or a gross
  -- given as nought, is not something to raise a certificate for -- and
  -- the tax would come out at nought, which `post_withholding` then
  -- refuses in its own words rather than this one.
  begin
    perform public.create_withholding(v_bill, 'S109B_SPECIAL',
                                      p_gross_amount => 0);
    raise exception 'FAIL: a certificate was raised on nothing';
  exception when sqlstate '22023' then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('and it says there is nothing to withhold from',
      v_said like '%nothing to withhold%');
    raise notice 'ok   a certificate on nothing is refused';
  end;

  -- MUTANT: `if v_tax > v_bill.balance_amount` -> `>=`. Withholding
  -- EXACTLY what is left is lawful and ordinary: a bill settled entirely
  -- by tax, which is what happens when the whole payment is withholdable
  -- and the rate is a hundred per cent of nothing left after an earlier
  -- part payment. Refusing it would be a rule the Act does not have.
  v_id := public.create_withholding(v_bill, 'S109B_SPECIAL',
            p_gross_amount => 100000, p_rate => 100);
  perform pg_temp.check_eq('withholding exactly the balance is allowed',
    (select tax_amount from public.withholding_certificates where id = v_id),
    100000);
  delete from public.withholding_certificates where id = v_id;

  -- MUTANT: `round(v_gross * v_rate / 100.0, 2)` unrounded. A
  -- certificate is a form with two decimal places on it. Three per cent
  -- of RM1,234.56 is RM37.0368.
  v_id := public.create_withholding(v_bill, 'S107A_B',
            p_gross_amount => 1234.56);
  perform pg_temp.check_eq('the tax on the certificate is in sen',
    (select tax_amount::text from public.withholding_certificates
      where id = v_id), '37.04');
  -- The `round(..., 2)` in the function and the column's own scale say
  -- the same thing, which is why a mutant deleting the round survives.
  -- It survives BECAUSE OF THE COLUMN, so the column is what is
  -- asserted: widen it and the function is the only thing left rounding.
  perform pg_temp.check_eq('because the column is in sen too',
    (select numeric_scale from information_schema.columns
      where table_name = 'withholding_certificates'
        and column_name = 'tax_amount'), 2);
  perform pg_temp.check_eq('as is the gross it is taken from',
    (select numeric_scale from information_schema.columns
      where table_name = 'withholding_certificates'
        and column_name = 'gross_amount'), 2);

  raise notice 'ok   what create_withholding refuses';
end $$;

-- =====================================================================
-- 3. The month the Act gives, taken from the type
-- =====================================================================
--
-- MUTANT: `make_interval(months => t.remit_months)` replaced by a flat
-- one month. Every seeded type happens to be one month, so the two are
-- the same answer everywhere in the suite -- equivalent BECAUSE OF THE
-- DATA, which is a different thing from equivalent by construction. The
-- column exists so a future section with a different period can be added
-- as data rather than as code, and this is the case that proves it can.
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_supp uuid;
  v_bill uuid;
  v_id   uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Tempoh Remit Sdn Bhd');
  v_supp := pg_temp.ws_supplier(v_org, 'S-1', 'Overseas Ltd');
  v_bill := pg_temp.ws_bill(v_org, v_supp, 'BILL-1', 100000,
                            date '2026-01-31');

  perform pg_temp.check_eq('every section in force remits within a month',
    (select count(*) from public.ref_withholding_types
      where is_active and remit_months <> 1), 0);

  v_id := public.create_withholding(v_bill, 'S109_ROYALTY',
            p_gross_amount => 1000);
  perform pg_temp.check_eq('so the end of January falls due at the end of February',
    (select due_date::text from public.withholding_certificates where id = v_id),
    '2026-02-28');

  -- A section with two months, added as data. If the column were ignored
  -- this certificate would still say February.
  insert into public.ref_withholding_types
    (code, section, name, rate, form_code, payee, remit_months,
     is_active, sort_order)
  values ('TEST_TWO', 'ITA s.999', 'A section with a longer period',
          5, 'CP999', 'non_resident', 2, true, 999);

  v_id := public.create_withholding(v_bill, 'TEST_TWO',
            p_gross_amount => 1000);
  perform pg_temp.check_eq('and a two-month section falls due at the end of March',
    (select due_date::text from public.withholding_certificates where id = v_id),
    '2026-03-31');
  perform pg_temp.check_eq('with the section it was issued under',
    (select section from public.withholding_certificates where id = v_id),
    'ITA s.999');

  -- The certificate references the type, so the type goes only after
  -- it does. Both go: the file rolls back, but leaving reference data
  -- behind between blocks is how one test starts depending on another.
  delete from public.withholding_certificates where wht_code = 'TEST_TWO';
  delete from public.ref_withholding_types where code = 'TEST_TWO';
  raise notice 'ok   the month the Act gives, taken from the type';
end $$;

-- =====================================================================
-- 4. A foreign bill, and the supplier's own payable account
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_supp  uuid;
  v_own   uuid;
  v_ap    uuid;
  v_bill  uuid;
  v_id    uuid;
  v_entry uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Mata Wang Sdn Bhd');
  v_supp := pg_temp.ws_supplier(v_org, 'S-1', 'Overseas Ltd');

  -- MUTANT: `coalesce(v_bill.exchange_rate, 1)` -> 1 on the certificate,
  -- and `round(c.tax_amount * coalesce(c.exchange_rate, 1), 2)` -> the
  -- tax alone in the journal. A certificate is raised in the currency of
  -- the bill and posted in the currency of the books; USD1,000 withheld
  -- at 4.50 is RM4,500 of liability to LHDN, and RM1,000 would be a
  -- quarter of what is owed.
  insert into public.exchange_rates (org_id, from_currency, to_currency,
    rate_date, rate, source)
  values (v_org, 'USD', 'MYR', date '2026-02-10', 4.5, 'manual')
  on conflict do nothing;

  v_bill := pg_temp.ws_bill(v_org, v_supp, 'BILL-USD', 10000,
                            date '2026-02-10', 'USD', 4.5);

  v_id := public.create_withholding(v_bill, 'S109B_SPECIAL',
            p_gross_amount => 10000);
  perform pg_temp.check_eq('the certificate is in the currency of the bill',
    (select currency::text from public.withholding_certificates where id = v_id),
    'USD');
  perform pg_temp.check_eq('and carries the rate it was billed at',
    (select exchange_rate from public.withholding_certificates where id = v_id),
    4.5);
  perform pg_temp.check_eq('the tax is a thousand dollars',
    (select tax_amount from public.withholding_certificates where id = v_id),
    1000);

  v_entry := public.post_withholding(v_id);
  perform pg_temp.check_eq('and four and a half thousand ringgit in the books',
    (select sum(l.credit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2145'), 4500);

  -- MUTANT: `coalesce(ct.payable_account_id, ...)` replaced by the
  -- chart's 2110 alone. A supplier can be given a payable account of its
  -- own -- a related company, a director's loan account -- and the
  -- withholding has to come off the same account the bill went on.
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Akaun Pembekal Sdn Bhd');
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '2115', 'Amounts owed to related companies', 'liability',
          'accounts_payable')
  returning id into v_ap;
  v_own := pg_temp.ws_supplier(v_org, 'S-R', 'Syarikat Berkaitan Sdn Bhd');
  update public.contacts set payable_account_id = v_ap where id = v_own;

  v_bill := pg_temp.ws_bill(v_org, v_own, 'BILL-R', 100000);
  v_id := public.create_withholding(v_bill, 'S107A_A',
            p_gross_amount => 100000);
  v_entry := public.post_withholding(v_id);

  perform pg_temp.check_eq('the withholding comes off the account the bill went on',
    (select l.debit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_ap), 10000);
  perform pg_temp.check_eq('and not off the general trade payables',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2110'), 0);

  raise notice 'ok   a foreign bill, and the supplier''s own payable';
end $$;

-- =====================================================================
-- 5. What post_withholding refuses, and what it records
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_supp  uuid;
  v_bill  uuid;
  v_id    uuid;
  v_said  text;
  r       record;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Pos Sijil Sdn Bhd');
  v_supp := pg_temp.ws_supplier(v_org, 'S-1', 'Overseas Ltd');
  v_bill := pg_temp.ws_bill(v_org, v_supp, 'BILL-1', 100000);

  -- MUTANT: the not-found guard.
  begin
    perform public.post_withholding(gen_random_uuid());
    raise exception 'FAIL: a certificate that does not exist was posted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a certificate that does not exist is refused';
  end;

  v_id := public.create_withholding(v_bill, 'S109B_SPECIAL',
            p_gross_amount => 10000);
  perform public.post_withholding(v_id);

  -- MUTANT: `if c.gl_entry_id is not null` -> false. Posting twice would
  -- take the payable down twice and credit LHDN twice for one payment.
  --
  -- `when others` would catch the wrong thing here: without the guard
  -- the second post inserts a second allocation, the bill goes over,
  -- and `apply_allocation` raises. The message is what tells the two
  -- refusals apart.
  begin
    perform public.post_withholding(v_id);
    raise exception 'FAIL: a certificate was posted twice';
  exception when others then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true(
      'and it is refused for being posted, not for over-allocating',
      v_said like '%already posted%');
    raise notice 'ok   a certificate is posted once';
  end;

  -- MUTANT: `set gl_entry_id = v_entry, status = 'posted'` with the
  -- status dropped. The screen reads the status; a certificate that has
  -- reached the ledger and still says draft is one somebody posts again.
  select * into r from public.withholding_certificates where id = v_id;
  perform pg_temp.check_eq('a posted certificate says so', r.status::text,
    'posted');
  perform pg_temp.check_true('and knows when', r.posted_at is not null);

  -- MUTANT: `if c.tax_amount = 0` -> false. A rate of nought is a valid
  -- rate to record -- an exemption certificate under a treaty -- and it
  -- is not a journal.
  v_id := public.create_withholding(v_bill, 'S109B_SPECIAL',
            p_gross_amount => 10000, p_rate => 0);
  perform pg_temp.check_eq('a certificate at nil is raised', 
    (select tax_amount from public.withholding_certificates where id = v_id), 0);
  begin
    perform public.post_withholding(v_id);
    raise exception 'FAIL: a certificate for nothing was posted';
  exception when sqlstate '22023' then
    raise notice 'ok   but a certificate for nothing is not posted';
  end;

  raise notice 'ok   what post_withholding refuses';
end $$;

-- =====================================================================
-- 6. The bank account the tax is actually paid from
-- =====================================================================
--
-- The whole of this was unasserted: `withholding.sql` remits without
-- naming an account, so the cross-organization guard, the lookup, the
-- fallback and the balance update were four branches with one case
-- between them.
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_supp   uuid;
  v_bill   uuid;
  v_id     uuid;
  v_bank   uuid;
  v_second uuid;
  v_theirs uuid;
  v_acct   uuid;
  v_entry  uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Bank Remit Sdn Bhd');
  v_supp := pg_temp.ws_supplier(v_org, 'S-1', 'Overseas Ltd');
  v_bill := pg_temp.ws_bill(v_org, v_supp, 'BILL-1', 100000);

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1131', 'Maybank current account', 'asset', 'bank')
  returning id into v_acct;
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_id, current_balance)
  values (v_org, 'Maybank', 'Maybank Berhad', '5140', v_acct, 500000)
  returning id into v_bank;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1132', 'CIMB current account', 'asset', 'bank')
  returning id into v_acct;
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_id, current_balance)
  values (v_org, 'CIMB', 'CIMB Bank Berhad', '8010', v_acct, 300000)
  returning id into v_second;

  v_other  := pg_temp.ws_org('Syarikat Lain Sdn Bhd');
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_other, '1131', 'Their account', 'asset', 'bank')
  returning id into v_acct;
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_id, current_balance)
  values (v_other, 'Theirs', 'Public Bank', '9999', v_acct, 100000)
  returning id into v_theirs;

  v_id := public.create_withholding(v_bill, 'S107A_A',
            p_gross_amount => 100000);
  perform public.post_withholding(v_id);

  -- MUTANT: the cross-organization guard removed. Without the raise the
  -- lookup finds nothing, the fallback quietly takes the company's own
  -- cash account, the entry posts, and nobody is any the wiser that the
  -- account they named was not theirs.
  begin
    perform public.remit_withholding(v_id, date '2026-03-15', v_theirs);
    raise exception 'FAIL: another company''s bank account paid the tax';
  exception when sqlstate '42501' then
    raise notice 'ok   another company''s bank account is refused';
  end;

  -- MUTANT: `v_bank := null`, so the named account is ignored and the
  -- fallback takes over. The company chose which account to pay from.
  v_entry := public.remit_withholding(v_id, date '2026-03-15', v_bank,
                                      'CP37D/2026/03');
  perform pg_temp.check_eq('the tax is paid from the account that was named',
    (select l.credit from public.gl_lines l
      join public.bank_accounts b on b.account_id = l.account_id
      where l.entry_id = v_entry and b.id = v_bank), 10000);
  perform pg_temp.check_eq('and not from the default cash account',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1120'), 0);

  -- MUTANT: the entry dated `current_date`. A remittance made in March
  -- and posted into today's period is a payment in the wrong month.
  perform pg_temp.check_eq('and the journal is dated the day it was paid',
    (select entry_date::text from public.gl_entries where id = v_entry),
    '2026-03-15');

  -- MUTANT: `set current_balance = current_balance` -- the balance never
  -- moves; and `where org_id = c.org_id` alone -- every account in the
  -- company moves. The money left ONE account.
  perform pg_temp.check_eq('the named account is ten thousand lighter',
    (select current_balance from public.bank_accounts where id = v_bank),
    490000);
  perform pg_temp.check_eq('and the other account is untouched',
    (select current_balance from public.bank_accounts where id = v_second),
    300000);

  perform pg_temp.check_eq('the certificate is completed',
    (select status::text from public.withholding_certificates where id = v_id),
    'completed');
  perform pg_temp.check_eq('and carries the reference it was paid under',
    (select remittance_ref from public.withholding_certificates where id = v_id),
    'CP37D/2026/03');

  raise notice 'ok   the bank account the tax is paid from';
end $$;

-- =====================================================================
-- 7. Somebody who may look but not post
-- =====================================================================
--
-- `withholding.sql` checks who may EXECUTE these functions, which is a
-- different question from who may post through them. All four
-- `app.can_post` guards lived because nothing had ever signed in as a
-- member without the right.
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_supp   uuid;
  v_bill   uuid;
  v_id     uuid;
  v_viewer uuid;
  v_said   text;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.ws_org('Pemerhati Sdn Bhd');
  v_supp := pg_temp.ws_supplier(v_org, 'S-1', 'Overseas Ltd');
  v_bill := pg_temp.ws_bill(v_org, v_supp, 'BILL-1', 100000);
  v_id   := public.create_withholding(v_bill, 'S107A_A',
              p_gross_amount => 100000);
  perform public.post_withholding(v_id);

  v_viewer := pg_temp.another_user('viewer@example.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_viewer, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  perform pg_temp.sign_in_as(v_viewer);

  begin
    perform public.create_withholding(v_bill, 'S107A_A',
              p_gross_amount => 1000);
    raise exception 'FAIL: a viewer raised a certificate';
  exception when sqlstate '42501' then
    raise notice 'ok   a viewer cannot raise a certificate';
  end;

  begin
    perform public.post_withholding(v_id);
    raise exception 'FAIL: a viewer posted a certificate';
  exception when sqlstate '42501' then
    raise notice 'ok   nor post one';
  end;

  -- `remit_withholding` and `create_gl_entry` both refuse a viewer, and
  -- both with 42501 -- so catching the code alone would pass with the
  -- guard deleted. They word it differently, and the wording is what
  -- says WHICH of the two turned this away: the outer guard, before any
  -- of the bank balance or the certificate has been touched.
  begin
    perform public.remit_withholding(v_id, date '2026-03-15');
    raise exception 'FAIL: a viewer remitted a certificate';
  exception when sqlstate '42501' then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_eq(
      'and remitting is refused before the ledger is reached',
      v_said, 'Insufficient privileges to post');
    raise notice 'ok   nor remit one';
  end;

  perform pg_temp.sign_out();
  raise notice 'ok   somebody who may look but not post';
end $$;

rollback;
