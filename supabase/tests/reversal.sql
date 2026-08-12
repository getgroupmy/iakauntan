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

rollback;
