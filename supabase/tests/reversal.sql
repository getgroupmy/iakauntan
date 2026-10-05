-- =====================================================================
-- iAkauntan :: reversing a journal
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reversal.sql
--
-- One assertion, made three times against the three callers: a reversal
-- has to come to nothing. `reverse_gl_entry` used to post a mirror and
-- void the original, and since every report filters on `posted`, the
-- original disappeared and the mirror stayed — so a reversed journal
-- left the ledger holding its exact opposite.
--
-- Voiding a RM 1,000 invoice put revenue on the wrong side by 1,000 and
-- showed the customer 1,000 in credit. This file is why that cannot
-- come back.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.rev_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.acct(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.accounts where org_id = p_org and code = p_code;
$$;

create or replace function pg_temp.balance(
  p_org uuid, p_code text, p_as_at date default date '2026-12-31')
returns numeric language sql as $$
  select coalesce(
    (select closing_balance from public.report_trial_balance(p_org, null, p_as_at)
      where code = p_code), 0);
$$;

-- ---------------------------------------------------------------------
-- A journal and its contra
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rev_org('Reversal Sdn Bhd');
  v_entry uuid; v_mirror uuid;
begin
  v_entry := public.post_manual_journal(v_org, date '2026-03-01',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 7500, 'credit', 0, 'description', 'In'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 7500, 'description', 'In')),
    'Capital introduced');

  perform pg_temp.check_eq('the journal is in the ledger',
    pg_temp.balance(v_org, '1120'), 7500);

  v_mirror := public.reverse_gl_entry(v_entry, date '2026-03-02');

  -- The whole point.
  perform pg_temp.check_eq('and a reversal comes to nothing',
    pg_temp.balance(v_org, '1120'), 0);
  perform pg_temp.check_eq('on both sides of it',
    pg_temp.balance(v_org, '3100'), 0);

  -- Contra-ed rather than deleted: 0059 refuses to post a reversal into
  -- a closed period, which only makes sense if the original stays where
  -- it is and the correction lands somewhere open.
  perform pg_temp.check_true('the original is still posted, not hidden',
    (select status = 'posted' from public.gl_entries where id = v_entry));
  perform pg_temp.check_true('and the mirror says what it reverses',
    (select is_reversal and reversed_entry_id = v_entry
       from public.gl_entries where id = v_mirror));

  -- Reversing the contra would put the entry back.
  begin
    perform public.reverse_gl_entry(v_entry, date '2026-03-03');
    raise exception 'FAIL: reversed the same journal twice';
  exception when sqlstate '22023' then
    raise notice 'ok   a journal is only reversed once';
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Voiding an invoice
--
-- The caller that made this worth finding.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rev_org('Void Sdn Bhd');
  v_cust uuid; v_doc uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Customer Bhd', 'customer') returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', date '2026-03-01', date '2026-03-31',
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_doc, 1, 'Consulting', 1, 1000);
  perform public.post_sales_document(v_doc);

  perform pg_temp.check_eq('the invoice earns revenue',
    pg_temp.balance(v_org, '4100'), -1000);
  perform pg_temp.check_eq('and the customer owes for it',
    pg_temp.balance(v_org, '1210'), 1000);

  perform public.void_sales_document(v_doc, 'raised in error');

  -- Not -1000 and not +1000. Nothing.
  perform pg_temp.check_eq('voiding it leaves no revenue',
    pg_temp.balance(v_org, '4100'), 0);
  perform pg_temp.check_eq('and leaves the customer owing nothing',
    pg_temp.balance(v_org, '1210'), 0);
  perform pg_temp.check_true('with the document marked void',
    (select status = 'void' from public.sales_documents where id = v_doc));

  -- The aged listing reads the same ledger, so it has to agree.
  perform pg_temp.check_eq('and nothing is left on the aged listing',
    (select coalesce(sum(base_outstanding), 0)
       from public.report_ar_aging(v_org, date '2026-12-31')), 0);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Revaluing twice
--
-- Each run undoes the standing revaluation before posting a fresh one.
-- With the same rate at both dates the position has not moved, so the
-- second run has to leave what the first one left — not double it, and
-- not cancel it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.rev_org('Revalue Sdn Bhd');
  v_cust uuid; v_doc uuid; v_after_one numeric; v_after_two numeric;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Overseas Bhd', 'customer') returning id into v_cust;

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date)
  values (v_org, 'USD', 'MYR', 4.50, date '2026-03-01');

  -- Booked at 4.00, worth 4.50 at both revaluation dates.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', date '2026-02-01', date '2026-03-03',
          v_cust, 'USD', 4.00, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_doc, 1, 'Consulting', 1, 1000);
  perform public.post_sales_document(v_doc);

  perform public.revalue_foreign_balances(v_org, date '2026-03-31');
  v_after_one := pg_temp.balance(v_org, '1210', date '2026-03-31');

  -- 1,000 dollars booked at 4.00 is 4,000; at 4.50 it is 4,500.
  perform pg_temp.check_eq('the first revaluation writes the balance up',
    v_after_one, 4500);

  perform public.revalue_foreign_balances(v_org, date '2026-04-30');
  v_after_two := pg_temp.balance(v_org, '1210', date '2026-04-30');

  perform pg_temp.check_eq('and the second one leaves it where it was',
    v_after_two, v_after_one);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What a reversal is besides a balance
-- ---------------------------------------------------------------------
-- The header of this file says, accurately and modestly, "one assertion,
-- made three times against the three callers: a reversal has to come to
-- nothing". A mutation sweep of `public.reverse_gl_entry` measured what
-- that modesty costs. 34 mutants
-- (`supabase/tests/mutants/reverse_gl_entry.py`) against this file and
-- the fifteen others that reach the function: **16 of 33 died, and all
-- seventeen survivors were things that do not change a balance.** This
-- file alone killed 13.
--
-- Every guard was open -- a journal that is not there, a stranger, a
-- draft -- and so was the whole of `0059`'s period machinery and the
-- whole of `0421`'s date machinery, which is the migration this
-- function's current form exists for. **`0421` is called "what day the
-- money moved", and all three of its date mutants lived here.** The
-- sixteen files net to the same balance whichever day the contra is
-- dated, so no one of them had to care.
--
-- The provenance was open too: the reversal could call itself a manual
-- journal, forget which document it reverses, drop the reference, post a
-- USD journal in ringgit at a rate of one, and forget who each line was
-- for. None of that moves a trial balance by a cent. All of it is what
-- an auditor reads.
do $$
declare
  v_org   uuid := pg_temp.rev_org('Balikkan Sdn Bhd');
  v_e     uuid;
  v_draft uuid;
  v_e2    uuid;
  v_r     uuid;
  v_apr   uuid;
  v_may   uuid;
  v_other uuid;
begin
  v_e := public.post_manual_journal(v_org, date '2026-03-01',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 100)),
    'To be reversed');

  -- --- the guards ----------------------------------------------------
  -- MUTANT: `if not found then raise` dropped. Without it the function
  -- carries on with an all-null record, and what the caller gets back is
  -- a privilege error about an organization that is null -- which is a
  -- refusal, so a test that only checked "it was refused" would pass.
  -- The MESSAGE is the assertion.
  perform pg_temp.check_refused('a journal that is not there cannot be reversed',
    format($q$ select public.reverse_gl_entry(%L, date '2026-03-02') $q$,
           gen_random_uuid()),
    '%not found%');

  -- MUTANT: `v_entry.status <> 'posted'` dropped. A draft journal is not
  -- in the ledger, so reversing it posts a contra of something that was
  -- never there -- and the pair does not net to zero, it is one entry of
  -- pure opposite.
  insert into public.gl_entries
    (org_id, entry_no, entry_date, fiscal_period_id, source, description,
     currency, exchange_rate, status)
  values (v_org, 'JV-NOT-POSTED', date '2026-03-01',
          app.period_for_date(v_org, date '2026-03-01'), 'manual',
          'Typed but never posted', 'MYR', 1, 'draft')
  returning id into v_draft;
  insert into public.gl_lines
    (org_id, entry_id, line_no, account_id, debit, credit)
  values (v_org, v_draft, 1, pg_temp.acct(v_org, '1120'), 100, 0),
         (v_org, v_draft, 2, pg_temp.acct(v_org, '3100'), 0, 100);
  perform pg_temp.check_refused('a draft journal cannot be reversed',
    format($q$ select public.reverse_gl_entry(%L, date '2026-03-02') $q$, v_draft),
    '%Only posted journals%', '22023');

  -- MUTANT: `app.can_post` dropped. Sixteen files reverse something and
  -- not one of them did it as somebody who may not post.
  v_other := pg_temp.another_user('stranger.reversal@iakauntan.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused('a stranger cannot reverse this company''s journal',
    format($q$ select public.reverse_gl_entry(%L, date '2026-03-02') $q$, v_e),
    '%Insufficient privileges%', '42501');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- --- the period, which is what 0059 is for ------------------------
  -- MUTANTS, three at once:
  --   * `if v_status <> 'open'` dropped -- a closed period accepts it;
  --   * `period_for_date(org, v_on)` -> `(org, v_entry.entry_date)` --
  --     the period is taken from the ORIGINAL, which is open, so the
  --     closed month the correction is aimed at never gets looked at;
  --   * `v_status <> 'open'` -> `= 'closed'` -- which is why the LOCKED
  --     period below is a separate fixture and not a repeat.
  select id into v_apr from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-04-01';
  perform public.set_fiscal_period_status(v_apr, 'closed');
  perform pg_temp.check_refused('a reversal cannot be posted into a closed month',
    format($q$ select public.reverse_gl_entry(%L, date '2026-04-15') $q$, v_e),
    '%is closed%', '23514');

  select id into v_may from public.fiscal_periods
   where org_id = v_org and start_date = date '2026-05-01';
  perform public.set_fiscal_period_status(v_may, 'locked');
  perform pg_temp.check_refused('nor into a locked one',
    format($q$ select public.reverse_gl_entry(%L, date '2026-05-15') $q$, v_e),
    '%is locked%', '23514');

  -- MUTANT: `if v_period_id is null then raise` dropped. `rev_org` makes
  -- 2026 and nothing else, so 2027 is outside every fiscal year. Without
  -- the refusal the entry is written with a null `fiscal_period_id` and
  -- appears in no period's report at all.
  perform pg_temp.check_refused('nor into a year that has not been opened',
    format($q$ select public.reverse_gl_entry(%L, date '2027-01-05') $q$, v_e),
    '%No fiscal period covers%', '23514');

  -- --- the date, which is what 0421 is for --------------------------
  -- MUTANTS: `v_on := coalesce(p_date, app.today())` -> `app.today()`,
  -- and `v_on` -> `v_entry.entry_date` in the insert. Both leave the
  -- pair netting to zero and both put the correction in the wrong month.
  v_r := public.reverse_gl_entry(v_e, date '2026-06-10');
  perform pg_temp.check_eq('a reversal is dated the day it is given',
    (select entry_date::text from public.gl_entries where id = v_r),
    date '2026-06-10'::text);
  perform pg_temp.check_eq('and lands in that month''s period, not the original''s',
    (select start_date::text from public.fiscal_periods f
      join public.gl_entries e on e.fiscal_period_id = f.id
     where e.id = v_r), date '2026-06-01'::text);

  -- MUTANT: `coalesce(p_date, app.today())` -> `p_date`. Called with no
  -- date at all the function has to fall back to today; without the
  -- coalesce `v_on` is null and it refuses with "No fiscal period covers
  -- <NULL>", which is the same errcode as the assertion above and would
  -- not be noticed by it.
  --
  -- Today is whatever day this runs, so the year is opened by asking
  -- rather than by assuming -- a test that hard-coded 2026 here would
  -- start failing on the first of January and name the wrong cause.
  if app.period_for_date(v_org, app.today()) is null then
    perform public.create_fiscal_year(
      v_org, date_trunc('year', app.today())::date);
  end if;
  v_e2 := public.post_manual_journal(v_org, date '2026-03-03',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 50, 'credit', 0),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 50)),
    'Reversed with no date');
  -- Called into a variable FIRST, and not inline. `reverse_gl_entry` is
  -- VOLATILE and it WRITES, and
  --
  --     where id = public.reverse_gl_entry(v_e2)
  --
  -- re-evaluates it once per row the scan compares -- so the first call
  -- posted a reversal and the second was refused with "has already been
  -- reversed", from inside the assertion, naming a journal the reader
  -- would have to go and look up. A writing function belongs on the
  -- left of an assignment, never in a WHERE clause.
  v_r := public.reverse_gl_entry(v_e2);
  perform pg_temp.check_eq('a reversal with no date given is dated today',
    (select entry_date::text from public.gl_entries where id = v_r),
    app.today()::text);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What the contra says about itself, and in which currency
-- ---------------------------------------------------------------------
-- The provenance half of the same sweep. A reversal that nets to zero
-- and says nothing true about itself is the posting an auditor cannot
-- follow in either direction: not from the document to the ledger, and
-- not back.
do $$
declare
  v_org  uuid := pg_temp.rev_org('Rujukan Sdn Bhd');
  v_cust uuid;
  v_item uuid;
  v_tax  uuid;
  v_src  uuid := gen_random_uuid();
  v_e    uuid;
  v_r    uuid;
  v_no   text;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-R', 'Overseas Bhd', 'customer') returning id into v_cust;
  insert into public.items (org_id, code, name, item_type)
  values (v_org, 'I-R', 'Consulting', 'service') returning id into v_item;
  select id into v_tax from public.tax_codes
   where org_id = v_org order by code limit 1;

  -- A USD journal that came from somewhere, with a reference, a
  -- customer, an item and a tax code on the line.
  v_e := public.create_gl_entry(
    v_org, date '2026-03-01', 'sales_invoice'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1210'),
                         'debit', 4200, 'credit', 0,
                         'description', 'Invoice to Overseas',
                         'contact_id', v_cust, 'item_id', v_item,
                         'tax_code_id', v_tax),
      -- The second line deliberately has NO description of its own.
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 0, 'credit', 4200)),
    'Sale to Overseas Bhd', 'sales_documents', v_src, 'INV-OS-1', 'USD', 4.2);
  select entry_no into v_no from public.gl_entries where id = v_e;

  v_r := public.reverse_gl_entry(v_e, date '2026-03-02');

  -- MUTANT: `v_entry.source` -> `'manual'`. A reversal of a sale is
  -- still a sale; filed as a manual journal it drops out of every
  -- report that selects on the source.
  perform pg_temp.check_eq('the contra keeps the original''s source',
    (select source::text from public.gl_entries where id = v_r), 'sales_invoice');
  -- MUTANT: `v_entry.source_table, v_entry.source_id` -> `null, null`.
  perform pg_temp.check_eq('and says what kind of document it reverses',
    (select source_table from public.gl_entries where id = v_r),
    'sales_documents');
  perform pg_temp.check_eq('and which one',
    (select source_id from public.gl_entries where id = v_r), v_src);
  -- MUTANT: the description -> `v_entry.description`. Two entries with
  -- the same description and opposite signs, and nothing on the page
  -- saying which is the correction.
  perform pg_temp.check_eq('and names itself after what it reverses',
    (select description from public.gl_entries where id = v_r),
    'Reversal of ' || v_no);
  -- MUTANT: `v_entry.reference` -> null.
  perform pg_temp.check_eq('and carries the original''s reference',
    (select reference from public.gl_entries where id = v_r), 'INV-OS-1');

  -- MUTANTS: header currency -> base, header rate -> 1. The ringgit
  -- amounts are on the lines, so the trial balance is unmoved either
  -- way; what moves is every statement printed in the customer's own
  -- currency.
  perform pg_temp.check_eq('the contra is in the currency of the original',
    (select currency::text from public.gl_entries where id = v_r), 'USD');
  perform pg_temp.check_eq('at the rate of the original',
    (select exchange_rate from public.gl_entries where id = v_r), 4.2);

  -- MUTANTS: line currency -> base, line rate -> 1.
  perform pg_temp.check_true('and so is every line of it',
    (select bool_and(currency = 'USD' and exchange_rate = 4.2)
       from public.gl_lines where entry_id = v_r));

  -- MUTANT: `'Reversal: ' || coalesce(description, '')` -> `description`.
  perform pg_temp.check_eq('each line says it is a reversal',
    (select description from public.gl_lines
      where entry_id = v_r and account_id = pg_temp.acct(v_org, '1210')),
    'Reversal: Invoice to Overseas');
  -- MUTANT: the `coalesce` dropped. On the line that has no description
  -- of its own, `'Reversal: ' || null` is NULL -- so the label does not
  -- merely lose a suffix, it disappears. This is the only assertion that
  -- can see it, and it needs a line with no description, which no
  -- fixture in the suite had.
  perform pg_temp.check_eq('including the line that had none of its own',
    (select description from public.gl_lines
      where entry_id = v_r and account_id = pg_temp.acct(v_org, '4100')),
    'Reversal: ');

  -- MUTANT: `contact_id, item_id, tax_code_id` -> `null, null, null`.
  -- One assertion kills that mutant because it is one expression; all
  -- three are named so that a later mutant dropping only one of them
  -- has somewhere to die.
  perform pg_temp.check_eq('the contra remembers who the line was for',
    (select contact_id from public.gl_lines
      where entry_id = v_r and account_id = pg_temp.acct(v_org, '1210')),
    v_cust);
  perform pg_temp.check_eq('and what it was for',
    (select item_id from public.gl_lines
      where entry_id = v_r and account_id = pg_temp.acct(v_org, '1210')),
    v_item);
  perform pg_temp.check_eq('and under which tax code',
    (select tax_code_id from public.gl_lines
      where entry_id = v_r and account_id = pg_temp.acct(v_org, '1210')),
    v_tax);

  -- MUTANT: `and r.status = 'posted'` dropped from the double-reversal
  -- check. A reversal that was itself voided is not a reversal any more,
  -- and the original has to be reversible again -- otherwise a mistake
  -- in the correction locks the entry for ever. Nothing in the schema
  -- voids a gl_entry today (0009 and 0059 did, and 0421 replaced both),
  -- so the state is built here directly; the conjunct is defensive and
  -- this is what it defends.
  update public.gl_entries set status = 'void' where id = v_r;
  perform pg_temp.check_true('a VOIDED reversal does not lock the original',
    public.reverse_gl_entry(v_e, date '2026-03-04') is not null);

  perform pg_temp.sign_out();
end $$;

rollback;
