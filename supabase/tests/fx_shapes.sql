-- =====================================================================
-- iAkauntan :: the balances a revaluation has to leave alone
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fx_shapes.sql
--
-- `fx_revaluation.sql` and `multicurrency.sql` pin the arithmetic: a
-- falling rate on a receivable is a loss, a rising one is a gain, the
-- run is idempotent, and gains and losses are stated separately. A
-- mutation sweep of the five functions under them killed 21 of 41.
--
-- What lived was, once again, everything AROUND the arithmetic. The
-- revaluation walks the whole sales and purchase ledger and its `where`
-- clause has six conditions on each side; the fixtures have one open
-- foreign invoice each, so five of those conditions had nothing on the
-- other side of them. A ringgit invoice, a settled one, an unposted
-- one, a voided one, and a customer with a receivable account of its
-- own are all ordinary rows in an ordinary ledger.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.fs_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.00, date '2026-01-01', 'manual'),
         (v_org, 'USD', 'MYR', 4.50, date '2026-03-31', 'manual');
  return v_org;
end $$;

create or replace function pg_temp.fs_customer(p_org uuid, p_code text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, 'Pembeli ' || p_code, 'customer')
  returning id into v_id;
  return v_id;
end $$;

create or replace function pg_temp.fs_invoice(
  p_org uuid, p_cust uuid, p_no text, p_amount numeric,
  p_currency char(3) default 'USD', p_rate numeric default 4.00,
  p_on date default date '2026-01-15', p_post boolean default true)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, p_on, p_cust, p_currency, p_rate,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Export sale', 1, p_amount);
  if p_post then perform public.post_sales_document(v_doc); end if;
  return v_doc;
end $$;

-- =====================================================================
-- 1. Which rate, and what happens when there is not one
-- =====================================================================
do $$
declare
  v_org uuid;
begin
  v_org := pg_temp.fs_org('Kadar Tukaran Sdn Bhd');

  -- MUTANT: `p_currency is null or p_currency = v_base` with the null
  -- half dropped. A document with no currency on it is a document in
  -- the company's own money, and asking the table for a rate from NULL
  -- finds nothing and raises -- which would take down a posting that
  -- has nothing foreign about it.
  perform pg_temp.check_eq('a null currency is the base currency',
    app.exchange_rate_for(v_org, null, date '2026-03-31'), 1);
  perform pg_temp.check_eq('and so is the base currency itself',
    app.exchange_rate_for(v_org, 'MYR', date '2026-03-31'), 1);

  -- MUTANTS: `if v_rate <= 0` deleted, and weakened to `< 0`. A rate of
  -- nought converts every foreign balance to nothing, silently, and a
  -- ledger saying a USD10,000 debtor is worth RM0 balances perfectly.
  --
  -- BOTH SURVIVE, and they survive because the table will not hold such
  -- a rate: `exchange_rates_rate_check` is `rate > 0`. The guard in the
  -- function is a second lock on a door the database already bolts, and
  -- the bolt is what this asserts -- take the constraint off and the
  -- guard is the only thing left.
  perform pg_temp.check_refused('a rate of nought cannot be recorded at all',
    format($q$ insert into public.exchange_rates
                 (org_id, from_currency, to_currency, rate, rate_date, source)
               values (%L, 'SGD', 'MYR', 0, date '2026-03-01', 'manual') $q$,
           v_org),
    '%exchange_rates_rate_check%', '23514');
  perform pg_temp.check_refused('nor a negative one',
    format($q$ insert into public.exchange_rates
                 (org_id, from_currency, to_currency, rate, rate_date, source)
               values (%L, 'THB', 'MYR', -0.13, date '2026-03-01', 'manual') $q$,
           v_org),
    '%exchange_rates_rate_check%', '23514');
  perform pg_temp.check_eq('and the constraint says so in the schema',
    (select count(*) from pg_constraint
      where conrelid = 'public.exchange_rates'::regclass
        and contype = 'c'
        and pg_get_constraintdef(oid) like '%rate > %'), 1);

  perform pg_temp.check_refused('and a currency with no rate at all says so',
    format($q$ select app.exchange_rate_for(%L, 'JPY', date '2026-03-31') $q$,
           v_org),
    '%No exchange rate%', 'P0002');

  raise notice 'ok   which rate, and what happens when there is not one';
end $$;

-- =====================================================================
-- 2. A chart with nowhere to put the difference
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_cust uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Carta Tukaran Sdn Bhd');
  v_cust := pg_temp.fs_customer(v_org, 'C-1');
  perform pg_temp.fs_invoice(v_org, v_cust, 'INV-1', 10000);

  -- MUTANT: `if v_id is null then raise` -> false. `0500` made the chart
  -- editable, so a company can be missing the gain or the loss account,
  -- and without the raise `create_gl_entry_internal` is handed a null
  -- account id and fails somewhere that does not name the problem.
  -- 4920 is Foreign Exchange Gain; renaming it out of the way is what a
  -- company that has reorganised its own chart does by accident.
  update public.accounts set code = '4929'
   where org_id = v_org and code = '4920';

  perform pg_temp.check_refused(
    'a chart with no exchange gain account says which one is missing',
    format($q$ select public.revalue_foreign_balances(%L, date '2026-03-31') $q$,
           v_org),
    '%No account 4920%', 'P0002');

  -- And the loss side, which is a different code and a different branch
  -- of the same `case`.
  update public.accounts set code = '4920'
   where org_id = v_org and code = '4929';
  update public.accounts set code = '6509'
   where org_id = v_org and code = '6500';
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 3.50, date '2026-06-30', 'manual');
  perform pg_temp.check_refused('and so does a chart with no loss account',
    format($q$ select public.revalue_foreign_balances(%L, date '2026-06-30') $q$,
           v_org),
    '%No account 6500%', 'P0002');

  raise notice 'ok   a chart with nowhere to put the difference';
end $$;

-- =====================================================================
-- 3. Which documents a revaluation touches
-- =====================================================================
--
-- Six conditions on each side of the union, and the fixtures have one
-- open foreign invoice each -- so five of them had nothing on the other
-- side. Each of the rows below is an ordinary row in an ordinary
-- ledger, and each of them must be left where it is.
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_cust   uuid;
  v_ar     uuid;
  v_entry  uuid;
  v_myr    uuid;
  v_settled uuid;
  v_draft  uuid;
  v_void   uuid;
  v_later  uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Lejar Penuh Sdn Bhd');
  v_cust := pg_temp.fs_customer(v_org, 'C-1');
  select id into v_ar from public.accounts
   where org_id = v_org and code = '1210';

  -- The one that IS revalued: USD10,000 booked at 4.00, worth 4.50 at
  -- the year end. RM5,000 of gain.
  perform pg_temp.fs_invoice(v_org, v_cust, 'INV-LIVE', 10000);

  -- MUTANT: `d.currency <> v_base` dropped. A ringgit invoice restated
  -- at a ringgit rate of one moves nothing, but it joins the grouping
  -- and the `having` no longer filters the row out cleanly -- and on the
  -- purchase side the same row would be added at the wrong sign.
  perform pg_temp.fs_invoice(v_org, v_cust, 'INV-MYR', 50000, 'MYR', 1);

  -- MUTANT: `d.balance_amount <> 0` dropped. A settled invoice has no
  -- exposure left: the money came in at whatever rate it came in at, the
  -- realised difference was booked then, and restating it now would book
  -- the same movement twice.
  v_settled := pg_temp.fs_invoice(v_org, v_cust, 'INV-PAID', 8000);
  update public.sales_documents set balance_amount = 0, paid_amount = 8000
   where id = v_settled;

  -- MUTANT: `d.gl_entry_id is not null` dropped. A draft invoice is not
  -- in the ledger, so there is nothing to restate.
  v_draft := pg_temp.fs_invoice(v_org, v_cust, 'INV-DRAFT', 7000, 'USD',
                                4.00, date '2026-01-15', false);

  -- MUTANT: `d.status <> 'void'` dropped.
  v_void := pg_temp.fs_invoice(v_org, v_cust, 'INV-VOID', 6000);
  update public.sales_documents set status = 'void' where id = v_void;

  -- MUTANT: `d.doc_date <= p_as_at` dropped. An invoice raised in April
  -- is not on the balance sheet at 31 March.
  v_later := pg_temp.fs_invoice(v_org, v_cust, 'INV-APR', 9000, 'USD',
                                4.00, date '2026-04-15');

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_true('the revaluation posted', v_entry is not null);

  -- Only INV-LIVE moved: 10,000 at 4.50 less 10,000 at 4.00.
  perform pg_temp.check_eq('only the one live foreign invoice is revalued',
    (select sum(l.debit) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_ar), 5000);
  perform pg_temp.check_eq('and the receivable moves on one line, not five',
    (select count(*) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_ar), 1);
  perform pg_temp.check_eq('with a gain of the same',
    (select sum(l.credit) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.name ilike '%gain%'), 5000);
  perform pg_temp.check_eq('and two lines in the whole entry',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);

  raise notice 'ok   which documents a revaluation touches';
end $$;

-- =====================================================================
-- 4. A customer with a receivable account of its own
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_plain uuid;
  v_own   uuid;
  v_acct  uuid;
  v_entry uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.fs_org('Akaun Sendiri Sdn Bhd');

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1215', 'Amounts owed by related companies', 'asset',
          'accounts_receivable')
  returning id into v_acct;

  v_plain := pg_temp.fs_customer(v_org, 'C-1');
  v_own   := pg_temp.fs_customer(v_org, 'C-2');
  update public.contacts set receivable_account_id = v_acct where id = v_own;

  perform pg_temp.fs_invoice(v_org, v_plain, 'INV-1', 10000);
  perform pg_temp.fs_invoice(v_org, v_own,   'INV-2', 20000);

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');

  -- MUTANT: `coalesce(c.receivable_account_id, 1210)` replaced by 1210.
  -- The subledger has to agree with the nominal AFTER the adjustment,
  -- and it cannot if the adjustment lands on a different account from
  -- the one the invoice went on.
  perform pg_temp.check_eq('the related company is restated on its own account',
    (select l.debit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_acct), 10000);
  perform pg_temp.check_eq('and the ordinary customer on the control',
    (select l.debit from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1210'), 5000);

  raise notice 'ok   a customer with a receivable account of its own';
end $$;

-- =====================================================================
-- 5. Undoing the last revaluation, and only that one
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_ar    uuid;
  v_first uuid;
  v_second uuid;
  v_third uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Nilai Semula Sdn Bhd');
  v_cust := pg_temp.fs_customer(v_org, 'C-1');
  select id into v_ar from public.accounts
   where org_id = v_org and code = '1210';
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.20, date '2026-02-28', 'manual');

  perform pg_temp.fs_invoice(v_org, v_cust, 'INV-1', 10000);

  v_first := public.revalue_foreign_balances(v_org, date '2026-02-28');
  perform pg_temp.check_eq('February restates at 4.20',
    (select sum(l.debit) from public.gl_lines l
      where l.entry_id = v_first and l.account_id = v_ar), 2000);

  -- MUTANTS: the reversal step deleted; the `is_reversal = false` filter
  -- dropped so a reversal is taken as the standing revaluation; the
  -- already-reversed filter dropped so the same entry is reversed twice;
  -- and the ordering flipped so the OLDEST revaluation is the one undone.
  --
  -- March restates from the BOOKED rate of 4.00, not from February's
  -- estimate of 4.20 -- so it is RM5,000, and the receivable's net
  -- movement across all three entries is RM5,000 and not RM7,000.
  v_second := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_eq('March restates from the booked rate, not February''s',
    (select sum(l.debit) from public.gl_lines l
      where l.entry_id = v_second and l.account_id = v_ar), 5000);

  perform pg_temp.check_eq('February was reversed exactly once',
    (select count(*) from public.gl_entries
      where org_id = v_org and reversed_entry_id = v_first
        and status = 'posted'), 1);
  perform pg_temp.check_eq('and the receivable has moved by five thousand net',
    (select coalesce(sum(l.debit) - sum(l.credit), 0) from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and l.account_id = v_ar
        and e.source = 'fx_revaluation'), 5000);

  -- Running the same date again reverses March and posts it afresh, and
  -- the net is still five thousand.
  v_third := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_eq('March was reversed once when it was redone',
    (select count(*) from public.gl_entries
      where org_id = v_org and reversed_entry_id = v_second
        and status = 'posted'), 1);
  perform pg_temp.check_eq('and February was not reversed a second time',
    (select count(*) from public.gl_entries
      where org_id = v_org and reversed_entry_id = v_first
        and status = 'posted'), 1);
  perform pg_temp.check_eq('the net movement is unchanged by running it again',
    (select coalesce(sum(l.debit) - sum(l.credit), 0) from public.gl_lines l
      join public.gl_entries e on e.id = l.entry_id
      where e.org_id = v_org and l.account_id = v_ar
        and e.source = 'fx_revaluation'), 5000);

  raise notice 'ok   undoing the last revaluation, and only that one';
end $$;

-- =====================================================================
-- 6. Who may revalue, and who may look
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_cust   uuid;
  v_viewer uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Kebenaran Tukaran Sdn Bhd');
  v_cust := pg_temp.fs_customer(v_org, 'C-1');
  perform pg_temp.fs_invoice(v_org, v_cust, 'INV-1', 10000);

  v_viewer := pg_temp.another_user('fxviewer@example.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_viewer, 'viewer')
  on conflict (org_id, user_id) do update set role = 'viewer';
  perform pg_temp.sign_in_as(v_viewer);

  -- MUTANT: `if not app.can_post(p_org_id)` -> false. A revaluation is a
  -- posting; a viewer may see the exposure and may not book it.
  perform pg_temp.check_refused('a viewer cannot revalue',
    format($q$ select public.revalue_foreign_balances(%L, date '2026-03-31') $q$,
           v_org),
    '%Insufficient privileges to post%', '42501');

  -- But may look, which is the positive control: a rule that refuses
  -- everybody is no better than one that refuses nobody.
  perform pg_temp.check_true('but may preview the exposure',
    (select count(*) from public.fx_revaluation_preview(
       v_org, date '2026-03-31')) > 0);
  perform pg_temp.sign_out();

  -- MUTANT: `if not app.is_org_member(p_org_id)` -> false on the
  -- preview. A company's open foreign exposure is its own business.
  perform pg_temp.sign_in_as(pg_temp.another_user('fxstranger@example.test'));
  perform pg_temp.check_refused('and a stranger may not even look',
    format($q$ select * from public.fx_revaluation_preview(
                 %L, date '2026-03-31') $q$, v_org),
    '%Not a member%', '42501');
  perform pg_temp.sign_out();

  raise notice 'ok   who may revalue, and who may look';
end $$;

-- =====================================================================
-- 7. A payable, a second settlement, and a rerun out of order
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_supp   uuid;
  v_own    uuid;
  v_ap     uuid;
  v_cust   uuid;
  v_bill   uuid;
  v_bill2  uuid;
  v_inv_a  uuid;
  v_inv_b  uuid;
  v_rec_a  uuid;
  v_rec_b  uuid;
  v_entry  uuid;
  v_march  uuid;
  v_feb    uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Pemiutang Sdn Bhd');

  -- MUTANT: `coalesce(c.payable_account_id, 2110)` replaced by 2110
  -- alone. The whole purchase side of the union had no case at all --
  -- every fixture in the suite revalues a receivable.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '2115', 'Amounts owed to related companies', 'liability',
          'accounts_payable')
  returning id into v_ap;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Ordinary supplier', 'supplier') returning id into v_supp;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-2', 'Related supplier', 'supplier') returning id into v_own;
  update public.contacts set payable_account_id = v_ap where id = v_own;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-1', date '2026-01-15', v_supp, 'USD', 4.00,
          5000, 5000, 5000, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 1, 'Imported goods', 1, 5000);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-2', date '2026-01-16', v_own, 'USD', 4.00,
          3000, 3000, 3000, 'draft')
  returning id into v_bill2;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill2, 1, 'Imported goods', 1, 3000);
  perform public.post_purchase_document(v_bill2);

  -- MUTANT: `having ... <> 0` -> true. An invoice raised ON the date
  -- being run, at that day's rate, moves by nothing -- and it is the
  -- ordinary last invoice of the month, not a contrivance. Without the
  -- `having` it becomes a journal line of nought against a customer.
  v_cust := pg_temp.fs_customer(v_org, 'C-1');
  perform pg_temp.fs_invoice(v_org, v_cust, 'INV-SAME', 2000, 'USD', 4.50,
                             date '2026-03-31');

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');

  -- A payable rises in ringgit when the dollar rises, and that is a
  -- LOSS: USD5,000 owed at 4.00 costs RM2,500 more at 4.50.
  perform pg_temp.check_eq('an ordinary supplier is restated on the control',
    (select l.credit from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2110'), 2500);
  perform pg_temp.check_eq('and a related one on its own account',
    (select l.credit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_ap), 1500);
  perform pg_temp.check_eq('with the whole difference booked as a loss',
    (select l.debit from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6500'), 4000);
  perform pg_temp.check_eq(
    'and the invoice raised at today''s rate is not a line at all',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1210'), 0);
  perform pg_temp.check_eq('so the entry is three lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 3);

  -- MUTANTS: the already-reversed filter dropped, and the ordering
  -- flipped. Both need a revaluation run OUT OF ORDER -- March, then
  -- February, which is what a bookkeeper does when they reopen a prior
  -- month. March is then the NEWEST entry and it is already reversed;
  -- the run has to skip it and take February's, and must not reverse
  -- March a second time.
  v_march := v_entry;
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.20, date '2026-02-28', 'manual');
  v_feb := public.revalue_foreign_balances(v_org, date '2026-02-28');

  perform pg_temp.check_eq('March was reversed when February was run',
    (select count(*) from public.gl_entries
      where org_id = v_org and reversed_entry_id = v_march
        and status = 'posted'), 1);

  -- And again at March. The standing entry is February's -- March is
  -- older by date but already reversed, and taking it would reverse it
  -- twice.
  perform public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_eq('and not a second time when March was rerun',
    (select count(*) from public.gl_entries
      where org_id = v_org and reversed_entry_id = v_march
        and status = 'posted'), 1);
  perform pg_temp.check_eq('February was the one reversed instead',
    (select count(*) from public.gl_entries
      where org_id = v_org and reversed_entry_id = v_feb
        and status = 'posted'), 1);

  raise notice 'ok   a payable, a second settlement, and a rerun out of order';
end $$;

-- =====================================================================
-- 8. One settlement's allocations, and not another's
-- =====================================================================
--
-- MUTANT: `where a.receipt_id = p_settlement_id` -> true, and the same
-- on the payment side. Every fixture settles one invoice with one
-- receipt, so the filter had nothing on the other side of it: a company
-- with two customers paying on the same day would book each one's
-- exchange difference against both.
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_inv_a uuid;
  v_inv_b uuid;
  v_fx_a  numeric;
  v_fx_b  numeric;
  v_rec_a uuid;
  v_rec_b uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Dua Resit Sdn Bhd');
  v_cust := pg_temp.fs_customer(v_org, 'C-1');

  -- Two invoices booked at different rates, so their differences are
  -- different numbers and cannot be confused with one another.
  v_inv_a := pg_temp.fs_invoice(v_org, v_cust, 'INV-A', 1000, 'USD', 4.00);
  v_inv_b := pg_temp.fs_invoice(v_org, v_cust, 'INV-B', 1000, 'USD', 4.10);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, currency, exchange_rate,
     amount, status)
  values (v_org, 'RC-A', date '2026-03-31', v_cust, 'USD', 4.50, 1000, 'posted')
  returning id into v_rec_a;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rec_a, v_inv_a, 1000);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, currency, exchange_rate,
     amount, status)
  values (v_org, 'RC-B', date '2026-03-31', v_cust, 'USD', 4.50, 1000, 'posted')
  returning id into v_rec_b;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rec_b, v_inv_b, 1000);

  v_fx_a := app.realised_fx_on_settlement(v_rec_a, true, 'USD', 4.50);
  v_fx_b := app.realised_fx_on_settlement(v_rec_b, true, 'USD', 4.50);

  -- 1,000 at (4.50 - 4.00) and 1,000 at (4.50 - 4.10).
  perform pg_temp.check_eq('the first receipt books its own difference',
    v_fx_a, 500);
  perform pg_temp.check_eq('and the second books its own',
    v_fx_b, 400);
  perform pg_temp.check_true('which are not the same number',
    v_fx_a <> v_fx_b);
  perform pg_temp.check_true('nor the sum of both',
    v_fx_a <> 900 and v_fx_b <> 900);

  -- The rate on a document is NOT NULL and defaults to one, which is
  -- why `coalesce(d.exchange_rate, 1)` cannot be told from
  -- `coalesce(d.exchange_rate, 0)` by any row this database will hold.
  -- The column is what makes that mutant equivalent, so the column is
  -- what is asserted.
  perform pg_temp.check_eq('no document can be on file without a rate',
    (select count(*) from information_schema.columns
      where table_schema = 'public' and column_name = 'exchange_rate'
        and table_name in ('sales_documents', 'purchase_documents',
                           'receipts', 'purchase_payments')
        and is_nullable = 'YES'), 0);

  raise notice 'ok   one settlement''s allocations, and not another''s';
end $$;

-- =====================================================================
-- 9. The three filters that look redundant and are not
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_supp  uuid;
  v_stray uuid;
  v_paid  uuid;
  v_live  uuid;
  v_bill_a uuid;
  v_bill_b uuid;
  v_pay_a uuid;
  v_pay_b uuid;
  v_entry uuid;
  v_ar    uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org  := pg_temp.fs_org('Penapis Sdn Bhd');
  v_cust := pg_temp.fs_customer(v_org, 'C-1');
  select id into v_ar from public.accounts
   where org_id = v_org and code = '1210';

  -- MUTANT: `d.currency <> v_base` dropped.
  --
  -- NOTHING NORMALISES THE RATE ON A BASE-CURRENCY DOCUMENT. An invoice
  -- in ringgit will happily carry an exchange rate of 4.50 -- posting
  -- does not object, because for a base-currency document the rate is
  -- never read. Except here: without the filter this invoice is
  -- "revalued" from 4.50 to 1.00 and RM3,500 of loss appears from
  -- nowhere. The filter is the only thing between a stray field and the
  -- profit and loss account.
  v_stray := pg_temp.fs_invoice(v_org, v_cust, 'INV-MYR', 1000, 'MYR', 4.50);
  perform pg_temp.check_eq('a ringgit invoice really can carry a stray rate',
    (select exchange_rate from public.sales_documents where id = v_stray),
    4.50);

  -- MUTANT: `d.balance_amount <> 0` dropped. A settled invoice has no
  -- exposure; its realised difference was booked when the money came.
  v_paid := pg_temp.fs_invoice(v_org, v_cust, 'INV-PAID', 8000);
  update public.sales_documents set balance_amount = 0, paid_amount = 8000
   where id = v_paid;

  v_live := pg_temp.fs_invoice(v_org, v_cust, 'INV-LIVE', 1000);

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_eq('only the live foreign invoice is restated',
    (select l.debit from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_ar), 500);
  perform pg_temp.check_eq('and the entry is two lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);

  -- MUTANT: `where a.payment_id = p_settlement_id` -> true on the
  -- PURCHASE side. The receipt side is covered above; this is its twin,
  -- and a twin is exactly the sort of thing a fixture covers on one
  -- side and forgets on the other.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Overseas supplier', 'supplier') returning id into v_supp;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-A', date '2026-01-15', v_supp, 'USD', 4.00,
          1000, 1000, 1000, 'draft') returning id into v_bill_a;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill_a, 1, 'Imported goods', 1, 1000);
  perform public.post_purchase_document(v_bill_a);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-B', date '2026-01-16', v_supp, 'USD', 4.10,
          1000, 1000, 1000, 'draft') returning id into v_bill_b;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill_b, 1, 'Imported goods', 1, 1000);
  perform public.post_purchase_document(v_bill_b);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, currency, exchange_rate,
     amount, status)
  values (v_org, 'PY-A', date '2026-03-31', v_supp, 'USD', 4.50, 1000, 'posted')
  returning id into v_pay_a;
  insert into public.payment_allocations
    (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay_a, v_bill_a, 1000);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, currency, exchange_rate,
     amount, status)
  values (v_org, 'PY-B', date '2026-03-31', v_supp, 'USD', 4.50, 1000, 'posted')
  returning id into v_pay_b;
  insert into public.payment_allocations
    (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay_b, v_bill_b, 1000);

  -- Paying a dollar bill when the dollar has risen costs more ringgit,
  -- so each of these is a LOSS, and they are different losses.
  perform pg_temp.check_eq('the first payment books its own difference',
    app.realised_fx_on_settlement(v_pay_a, false, 'USD', 4.50), -500);
  perform pg_temp.check_eq('and the second books its own',
    app.realised_fx_on_settlement(v_pay_b, false, 'USD', 4.50), -400);

  -- MUTANT: the ordering of the standing-revaluation lookup flipped.
  -- It can only be told from the right one when TWO revaluations stand
  -- un-reversed at once, and that never happens -- each run reverses the
  -- one before it. The invariant is what makes the mutant equivalent,
  -- so the invariant is what is asserted.
  perform public.revalue_foreign_balances(v_org, date '2026-02-28');
  perform public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_eq('at most one revaluation ever stands un-reversed',
    (select count(*) from public.gl_entries e
      where e.org_id = v_org and e.source = 'fx_revaluation'
        and e.status = 'posted' and e.is_reversal = false
        and not exists (select 1 from public.gl_entries x
                         where x.reversed_entry_id = e.id
                           and x.status = 'posted')), 1);

  raise notice 'ok   the three filters that look redundant and are not';
end $$;

-- =====================================================================
-- The six a second sweep found, and the asymmetry between them
--
-- The sweep in this file's header killed 21 of 41 across five
-- functions. This one mutated `revalue_foreign_balances` alone -- 33
-- mutants across the four files that reach it -- and 26 died. The seven
-- that lived include one that is worth more than the rest put together:
--
-- **A VOID SALES INVOICE is excluded and asserted; a VOID BILL is
-- excluded and not.** The two halves of the union have six conjuncts
-- each and the file built the full set of negatives for the sales side
-- only, so the purchase side's `d.status <> 'void'` had nothing on the
-- other side of it. Six rules asserted on one half of a symmetric
-- query and one of them unasserted on the other is the commonest shape
-- there is for a union, and the only way to see it is to mutate each
-- half separately.
--
-- The rest: the date boundary (every invoice in the suite is dated the
-- 15th and valued on the 31st, so nothing lands ON the valuation day),
-- a deleted invoice, the contact on each of the two revaluation legs,
-- and the org scope on the lookup that picks WHICH prior revaluation to
-- reverse.
-- =====================================================================
do $$
declare
  v_org   uuid; v_other uuid;
  v_owner uuid := pg_temp.test_user();
  v_cust  uuid; v_cust2 uuid; v_supp uuid;
  v_ar    uuid; v_ap uuid;
  v_live  uuid; v_onday uuid; v_gone uuid; v_bill uuid; v_voidbill uuid;
  v_first uuid; v_second uuid; v_theirs uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.fs_org('Nilai Semula Celah Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_cust  := pg_temp.fs_customer(v_org, 'C-1');
  v_cust2 := pg_temp.fs_customer(v_org, 'C-2');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal USD', 'supplier') returning id into v_supp;
  select id into v_ar from public.accounts where org_id = v_org and code = '1210';
  select id into v_ap from public.accounts where org_id = v_org and code = '2110';

  -- ------------------------------------------------------------------
  -- 1. THE DATE BOUNDARY: an invoice dated the valuation day itself
  -- ------------------------------------------------------------------
  -- `d.doc_date <= p_as_at`. Every invoice in this file is dated the
  -- 15th and valued on the 31st, so narrowing the rule to `<` changed
  -- nothing. A sale invoiced on the last day of the month is the
  -- ordinary close, not a corner case -- and it is already in the
  -- ledger at the booked rate, so leaving it out understates the
  -- adjustment by its whole difference.
  v_live  := pg_temp.fs_invoice(v_org, v_cust, 'INV-MID', 1000,
                                'USD', 4.00, date '2026-01-15');
  v_onday := pg_temp.fs_invoice(v_org, v_cust2, 'INV-ONDAY', 2000,
                                'USD', 4.00, date '2026-03-31');

  -- ------------------------------------------------------------------
  -- 2. A DELETED INVOICE
  -- ------------------------------------------------------------------
  -- Soft-deleted rows stay in the table and keep a non-zero balance,
  -- so `d.deleted_at is null` is the only thing keeping them out.
  v_gone := pg_temp.fs_invoice(v_org, v_cust, 'INV-GONE', 8000,
                               'USD', 4.00, date '2026-01-15');
  update public.sales_documents set deleted_at = now() where id = v_gone;

  -- ------------------------------------------------------------------
  -- 3. A VOID BILL, the half the sales side already had
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-LIVE', date '2026-01-15', v_supp, 'USD', 4.00,
          500, 500, 500, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 1, 'Import', 1, 500);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'bill', 'BILL-VOID', date '2026-01-15', v_supp, 'USD', 4.00,
          9000, 9000, 9000, 'draft')
  returning id into v_voidbill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_voidbill, 1, 'Cancelled import', 1, 9000);
  perform public.post_purchase_document(v_voidbill);
  update public.purchase_documents set status = 'void' where id = v_voidbill;

  -- ------------------------------------------------------------------
  -- The run, and what it may and may not have seen
  -- ------------------------------------------------------------------
  -- USD 4.00 booked, USD 4.50 at the close: 50 sen on every dollar.
  --   INV-MID    1000 -> gain 500
  --   INV-ONDAY  2000 -> gain 1000   (the boundary)
  --   BILL-LIVE   500 -> loss 250    (a payable costs more)
  --   INV-GONE   8000 -> nothing, deleted
  --   BILL-VOID  9000 -> nothing, void
  v_first := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_true('the revaluation posts', v_first is not null);

  perform pg_temp.check_eq(
    'the receivable is written up by every live foreign invoice, the one '
    'dated the valuation day included',
    (select round(sum(l.debit - l.credit), 2) from public.gl_lines l
      where l.entry_id = v_first and l.account_id = v_ar), 1500);
  -- Credit less debit on a liability, so a POSITIVE figure is the
  -- payable growing -- which is what a rising rate does to money owed
  -- in dollars.
  perform pg_temp.check_eq(
    'and the payable grows by the live bill alone, not by the void one',
    (select round(sum(l.credit - l.debit), 2) from public.gl_lines l
      where l.entry_id = v_first and l.account_id = v_ap), 250);

  -- THE CONTACT, on both legs separately. `report_contact_statement`
  -- reads gl_lines.contact_id, so a revaluation leg without one moves
  -- the nominal and leaves the subledger behind -- which is exactly
  -- what the function's own comment says the grouping exists to
  -- prevent. The gain leg and the loss leg are built in two different
  -- jsonb_build_object calls and either can lose it alone.
  perform pg_temp.check_eq('each gain leg names the customer it restates',
    (select count(*) from public.gl_lines
      where entry_id = v_first and account_id = v_ar
        and contact_id is null), 0);
  perform pg_temp.check_eq('and the loss leg names the supplier',
    (select contact_id from public.gl_lines
      where entry_id = v_first and account_id = v_ap), v_supp);
  perform pg_temp.check_eq(
    'with one line per customer, so the subledger still agrees',
    (select count(*) from public.gl_lines
      where entry_id = v_first and account_id = v_ar), 2);

  -- ------------------------------------------------------------------
  -- 4. WHICH prior revaluation is reversed
  -- ------------------------------------------------------------------
  -- The lookup is scoped to the company. Another company's standing
  -- revaluation, dated LATER so it sorts first, is what makes the scope
  -- observable: without it this run reverses THEIR adjustment and
  -- leaves ours standing, so both sets of books are wrong and neither
  -- figure in this company's ledger says so.
  v_other := pg_temp.fs_org('Syarikat Lain Nilai Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_theirs := pg_temp.fs_invoice(
    v_other, pg_temp.fs_customer(v_other, 'X-1'), 'INV-X', 700,
    'USD', 4.00, date '2026-01-15');
  perform pg_temp.sign_in_as(v_owner);
  -- Dated 30 April, after ours, so `order by entry_date desc` finds it
  -- first the moment the org scope is gone.
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_other, 'USD', 'MYR', 4.70, date '2026-04-30', 'manual');
  v_theirs := public.revalue_foreign_balances(v_other, date '2026-04-30');
  perform pg_temp.check_true('the other company revalues too',
    v_theirs is not null);

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org, 'USD', 'MYR', 4.60, date '2026-04-30', 'manual');
  v_second := public.revalue_foreign_balances(v_org, date '2026-04-30');

  perform pg_temp.check_eq('a second run reverses OUR standing adjustment',
    (select count(*) from public.gl_entries
      where reversed_entry_id = v_first and status = 'posted'), 1);
  perform pg_temp.check_eq('and leaves the other company''s alone',
    (select count(*) from public.gl_entries
      where reversed_entry_id = v_theirs and status = 'posted'), 0);
  perform pg_temp.check_eq(
    'so April measures from the booked rate and not from March''s estimate',
    (select round(sum(l.debit - l.credit), 2) from public.gl_lines l
      where l.entry_id = v_second and l.account_id = v_ar),
    -- 60 sen on 3,000 dollars of live invoices
    1800);

  -- What this block does NOT prove, said here so the next sweep does
  -- not re-chase it: `order by e.entry_date desc, e.created_at desc` on
  -- that lookup is an EQUIVALENT mutation target, because there can
  -- never be two rows to order. Each run reverses the one candidate it
  -- finds before posting at most one new one, a reversal carries
  -- `is_reversal = true` and is excluded, and a reversed entry is
  -- excluded by the `not exists`. The only state with two candidates
  -- needs a reversal that is no longer `posted`, and this schema has no
  -- function that unposts or voids a gl_entry -- the undo everywhere is
  -- another reversal. So the ORDER BY is correct, load-bearing if that
  -- invariant ever breaks, and unobservable today.
  raise notice 'ok   revaluation: the boundary, the deleted, the VOID BILL, the party, the company';
end $$;


rollback;
