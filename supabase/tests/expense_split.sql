-- =====================================================================
-- iAkauntan :: one charge, two accounts
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/expense_split.sql
--
-- An expense named one account until 0496. The RM 500 on the card
-- statement that was part flights and part entertainment had to be
-- typed as two expenses with two numbers and one receipt between them.
--
-- What is asserted here is the arithmetic and the scope. The debits
-- have to come to the same figure the bank was credited, which stops
-- being automatic the moment the charge is in somebody else's currency
-- and each line is converted on its own; and a split must reach only
-- this company's accounts and only this expense's lines.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.split_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.a_bank(
  p_org uuid, p_code text, p_name text, p_opening numeric)
returns uuid language plpgsql as $$
declare v_acct uuid; v_bank uuid;
begin
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, parent_id)
  values (p_org, p_code, p_name, 'asset', 'bank', false,
          (select id from public.accounts
            where org_id = p_org and code = '1100'))
  returning id into v_acct;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance)
  values (p_org, v_acct, p_name, 'Maybank', '5140' || p_code, 'MYR',
          p_opening, p_opening)
  returning id into v_bank;
  return v_bank;
end;
$$;

create or replace function pg_temp.an_expense(
  p_org uuid, p_no text, p_account_code text,
  p_amount numeric, p_tax numeric, p_total numeric,
  p_bank uuid default null,
  p_currency text default 'MYR', p_rate numeric default 1)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id,
     description, reference, currency, exchange_rate,
     amount, tax_amount, total_amount)
  values (p_org, p_no, date '2026-03-04',
          (select id from public.accounts
            where org_id = p_org and code = p_account_code),
          p_bank, 'The company card', 'R-' || p_no,
          p_currency, p_rate, p_amount, p_tax, p_total)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.acct(p_org uuid, p_code text)
returns uuid language sql stable as $$
  select id from public.accounts where org_id = p_org and code = p_code;
$$;

create or replace function pg_temp.leg(p_entry uuid, p_code text)
returns numeric language sql stable as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = p_entry and a.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- The card statement
--
-- RM 500 out of the bank, RM 320 of it flights and RM 180 of it
-- entertainment. One expense, one receipt, one payment.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.split_org('Card Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid; v_dr numeric; v_cr numeric;
  v_n integer;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  -- Typed the way somebody starts: one account, and a total read off
  -- the top of the receipt before the lines were added up.
  v_exp := pg_temp.an_expense(v_org, 'EXP-1', '6280', 400.00, 0, 400.00,
                              v_bank);

  v_n := public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                       'description', 'Flights', 'amount', 320),
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6260'),
                       'description', 'Client dinner', 'amount', 180)));
  perform pg_temp.check_eq('a charge can be split in two', v_n, 2);

  -- The split is the expense: the header is written from the lines
  -- rather than checked against them, so there is no state in which
  -- the parts and the total disagree. All three of these were typed
  -- otherwise -- 400 on 6280 -- and the split is what they now say.
  perform pg_temp.check_true('the header follows the split',
    (select e.amount = 500.00 and e.total_amount = 500.00
        and e.account_id = pg_temp.acct(v_org, '6250')
       from public.expenses e where e.id = v_exp));

  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('each account is debited its own share',
    pg_temp.leg(v_entry, '6250'), 320.00);
  perform pg_temp.check_eq('and the other its own',
    pg_temp.leg(v_entry, '6260'), 180.00);
  perform pg_temp.check_eq('and the bank is credited once, for the whole',
    pg_temp.leg(v_entry, '1121'), -500.00);

  select sum(l.debit), sum(l.credit) into v_dr, v_cr
    from public.gl_lines l where l.entry_id = v_entry;
  perform pg_temp.check_eq('debits and credits agree', v_dr, v_cr);
  perform pg_temp.check_eq('and the journal is three lines, not four',
    (select count(*) from public.gl_lines where entry_id = v_entry), 3);

  perform pg_temp.check_eq('the bank balance falls by the whole charge',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    8500.00);
end $$;

-- ---------------------------------------------------------------------
-- Another expense's split
--
-- Two split expenses in the same company. A read that forgets which
-- expense it is reading puts one card charge's accounts on the other's
-- journal, and both would still balance.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.split_org('Two Cards Sdn Bhd');
  v_bank uuid; v_one uuid; v_two uuid; v_entry uuid;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_one := pg_temp.an_expense(v_org, 'EXP-1', '6250', 100.00, 0, 100.00,
                              v_bank);
  v_two := pg_temp.an_expense(v_org, 'EXP-2', '6250', 70.00, 0, 70.00,
                              v_bank);

  perform public.set_expense_split(v_one, jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                       'amount', 60),
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6260'),
                       'amount', 40)));
  perform public.set_expense_split(v_two, jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6280'),
                       'amount', 70)));

  v_entry := public.post_expense(v_one);
  perform pg_temp.check_eq('and not another expense''s share',
    pg_temp.leg(v_entry, '6280'), 0);
  perform pg_temp.check_eq('the first charge posts its own two lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 3);

  perform pg_temp.check_eq('and the reader answers per expense',
    (select count(*) from public.expense_split(v_two)), 1);
end $$;

-- ---------------------------------------------------------------------
-- In somebody else's currency
--
-- USD 100.00 at 3.7775, split 33.33 / 33.33 / 33.34. Converted line by
-- line the debits come to 377.74 -- 125.90, 125.90, 125.94 -- and the
-- bank was credited 377.75. A journal a cent out is a journal that
-- will not post, so the largest line takes the difference.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.split_org('Importer Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid; v_dr numeric; v_cr numeric;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp := pg_temp.an_expense(v_org, 'EXP-9', '6250', 100.00, 0, 100.00,
                              v_bank, 'USD', 3.7775);

  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                       'amount', 33.33),
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6260'),
                       'amount', 33.33),
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6280'),
                       'amount', 33.34)));

  v_entry := public.post_expense(v_exp);

  select sum(l.debit), sum(l.credit) into v_dr, v_cr
    from public.gl_lines l where l.entry_id = v_entry;
  perform pg_temp.check_eq('a split in a foreign currency still balances',
    v_dr, v_cr);
  perform pg_temp.check_eq('and comes to the ringgit that left the bank',
    v_cr, 377.75);

  -- 33.33 * 3.7775 = 125.904..., which rounds to 125.90. The third
  -- line is the largest, so it carries what is left of the 377.75
  -- rather than its own 125.94.
  perform pg_temp.check_eq('the two smaller lines convert on their own',
    pg_temp.leg(v_entry, '6250'), 125.90);
  perform pg_temp.check_eq('and the cent lands on the largest line',
    pg_temp.leg(v_entry, '6280'), 125.95);
end $$;

-- ---------------------------------------------------------------------
-- What a split may not do
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.split_org('Careful Sdn Bhd');
  v_other uuid := pg_temp.split_org('Somebody Else Sdn Bhd');
  v_them  uuid := pg_temp.another_user('reader@example.test');
  v_bank  uuid; v_exp uuid;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp := pg_temp.an_expense(v_org, 'EXP-5', '6250', 100.00, 0, 100.00,
                              v_bank);

  -- An account id from another company, which is what a request body
  -- carries and what nothing in the schema would otherwise refuse: the
  -- line would post one company's spending into another's ledger and
  -- each screen would look right on its own.
  begin
    perform public.set_expense_split(v_exp, jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_other, '6250'),
                         'amount', 100)));
    raise exception
      'FAIL a company cannot split an expense into somebody else''s account';
  exception when others then
    if sqlerrm like 'FAIL %' then raise; end if;
    raise notice
      'ok   a company cannot split an expense into somebody else''s account';
  end;
  perform pg_temp.check_eq('and the refusal leaves no half-written split',
    (select count(*) from public.expense_lines where expense_id = v_exp), 0);

  -- A line with no money in it is a typing accident, not a split.
  begin
    perform public.set_expense_split(v_exp, jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                         'amount', 100),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6260'),
                         'amount', 0)));
    raise exception 'FAIL a line with no amount is refused';
  exception when others then
    if sqlerrm like 'FAIL %' then raise; end if;
    raise notice 'ok   a line with no amount is refused';
  end;

  -- Somebody who may read the company but not write to it.
  perform pg_temp.sign_in_as(v_them);
  begin
    perform public.set_expense_split(v_exp, jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                         'amount', 100)));
    raise exception 'FAIL a reader cannot split an expense';
  exception when others then
    if sqlerrm like 'FAIL %' then raise; end if;
    raise notice 'ok   a reader cannot split an expense';
  end;
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- Once it is in the ledger, what it was for is a journal, not an edit.
  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                       'amount', 60),
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6260'),
                       'amount', 40)));
  perform public.post_expense(v_exp);
  begin
    perform public.set_expense_split(v_exp, jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6280'),
                         'amount', 100)));
    raise exception 'FAIL a posted expense cannot be re-split';
  exception when others then
    if sqlerrm like 'FAIL %' then raise; end if;
    raise notice 'ok   a posted expense cannot be re-split';
  end;
  perform pg_temp.check_eq('and the split it was posted on is still there',
    (select count(*) from public.expense_lines where expense_id = v_exp), 2);
end $$;

-- ---------------------------------------------------------------------
-- And the expense that was never split
--
-- Every expense recorded before 0496 has no lines, and posting one has
-- to be exactly what it was: the header account takes the whole debit.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.split_org('Plain Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp := pg_temp.an_expense(v_org, 'EXP-7', '6250', 300.00, 18.00, 318.00,
                              v_bank);

  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('an expense with no split posts as it always did',
    pg_temp.leg(v_entry, '6250'), 300.00);
  perform pg_temp.check_eq('with its tax still on 1410',
    pg_temp.leg(v_entry, '1410'), 18.00);
  perform pg_temp.check_eq('and the bank credited the whole',
    pg_temp.leg(v_entry, '1121'), -318.00);

  -- Emptying a split puts an expense back to where it started.
  perform pg_temp.check_eq('a split can be taken off again',
    public.set_expense_split(
      pg_temp.an_expense(v_org, 'EXP-8', '6250', 10.00, 0, 10.00, v_bank),
      '[]'::jsonb), 0);
end $$;

rollback;
