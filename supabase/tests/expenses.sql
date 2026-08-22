-- =====================================================================
-- iAkauntan :: posting an expense
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/expenses.sql
--
-- `post_expense` is reachable from the Expenses screen and puts money
-- in the ledger, and until this file nothing in `supabase/tests`
-- mentioned it — nor `public.expenses` at all. It is the last posting
-- function in the schema with no coverage.
--
-- Three legs and one of them is a guess: the expense account it was
-- coded to, the SST input tax when there is any, and the credit, which
-- goes to the named bank account or falls back to 1120 when the expense
-- was paid in cash. A fallback that picks the wrong account is the
-- shape 0282 found in `post_client_transaction`, so it is asserted from
-- both sides here.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.money_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- A bank the company can pay from, on its own ledger account rather
-- than on 1120, so "which account did the credit land on" is a question
-- with two different answers.
create or replace function pg_temp.a_bank(
  p_org uuid, p_code text, p_name text, p_opening numeric)
returns uuid language plpgsql as $$
declare v_acct uuid; v_bank uuid;
begin
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, parent_id)
  values (p_org, p_code, p_name, 'asset', 'bank', false,
          (select id from public.accounts where org_id = p_org and code = '1100'))
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
          p_bank, 'Grab to the client', 'R-' || p_no,
          p_currency, p_rate, p_amount, p_tax, p_total)
  returning id into v_id;
  return v_id;
end;
$$;

-- What one account took, off one journal.
create or replace function pg_temp.leg(p_entry uuid, p_code text)
returns numeric language sql stable as $$
  select coalesce(sum(l.debit - l.credit), 0)
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.entry_id = p_entry and a.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- Paid from the bank
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.money_org('Spender Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid; v_dr numeric; v_cr numeric;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp  := pg_temp.an_expense(v_org, 'EXP-1', '6250', 300.00, 18.00, 318.00, v_bank);

  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('the cost lands on the account it was coded to',
    pg_temp.leg(v_entry, '6250'), 300.00);
  perform pg_temp.check_eq('the tax lands on SST input tax',
    pg_temp.leg(v_entry, '1410'), 18.00);
  -- Negative because the bank was credited. Money left.
  perform pg_temp.check_eq('and the whole of it comes off the bank it names',
    pg_temp.leg(v_entry, '1121'), -318.00);

  -- The one thing a journal must always do. Asserted separately from
  -- the three legs above because those could each be right about the
  -- account and wrong about the number.
  select sum(l.debit), sum(l.credit) into v_dr, v_cr
    from public.gl_lines l where l.entry_id = v_entry;
  perform pg_temp.check_eq('debits and credits agree', v_dr, v_cr);
  perform pg_temp.check_eq('and come to what was spent', v_dr, 318.00);

  perform pg_temp.check_true('the expense is marked posted, and knows its entry',
    (select e.status = 'posted' and e.gl_entry_id = v_entry
        and e.posted_at is not null
       from public.expenses e where e.id = v_exp));

  -- The audit trail back. Without this the ledger holds a figure with
  -- no way to reach the document that explains it.
  perform pg_temp.check_true('and the entry names the expense it came from',
    (select g.source_table = 'expenses' and g.source_id = v_exp
       from public.gl_entries g where g.id = v_entry));

  -- The cached balance the reconciliation screen reconciles against.
  perform pg_temp.check_eq('the bank balance falls by what was paid',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    8682.00);

  -- Twice would double the cost and halve the bank.
  begin
    perform public.post_expense(v_exp);
    raise exception 'FAIL: posted the same expense twice';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'ok   an expense cannot be posted twice';
  end;
  perform pg_temp.check_eq('and the ledger holds one entry for it, not two',
    (select count(*) from public.gl_entries g
      where g.source_table = 'expenses' and g.source_id = v_exp), 1);
end $$;

-- ---------------------------------------------------------------------
-- Paid in cash
--
-- No bank account named, so the credit has nowhere of its own to go and
-- 1120 is the fallback. Two things are asserted about that: it is the
-- account that takes the money, and no bank account's cached balance
-- moves — a cash expense that quietly drew down somebody's current
-- account would put the reconciliation out by an amount that never went
-- through the bank.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.money_org('Petty Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp  := pg_temp.an_expense(v_org, 'EXP-2', '6260', 50.00, 0, 50.00);

  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('a cash expense still lands on its own account',
    pg_temp.leg(v_entry, '6260'), 50.00);
  perform pg_temp.check_eq('and is credited to 1120, not to a bank',
    pg_temp.leg(v_entry, '1120'), -50.00);
  perform pg_temp.check_eq('the named bank is untouched',
    pg_temp.leg(v_entry, '1121'), 0);
  perform pg_temp.check_eq('and its cached balance has not moved',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    9000.00);

  -- No tax, so no tax line. A zero on 1410 would put a nil figure into
  -- the SST-02 workings for a purchase that carried no input tax.
  perform pg_temp.check_eq('an expense with no tax writes no tax line',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1410'), 0);
  perform pg_temp.check_eq('so the journal is two lines',
    (select count(*) from public.gl_lines where entry_id = v_entry), 2);
end $$;

-- ---------------------------------------------------------------------
-- Bought in somebody else's currency
--
-- The ledger is in ringgit whatever the invoice was in, so every leg is
-- the foreign figure at the rate on the expense — and the bank balance
-- falls by the ringgit, not by the dollars.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.money_org('Importer Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid; v_dr numeric; v_cr numeric;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp  := pg_temp.an_expense(v_org, 'EXP-3', '6280', 100.00, 6.00, 106.00,
                               v_bank, 'USD', 4.20);

  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('the cost is converted', pg_temp.leg(v_entry, '6280'), 420.00);
  perform pg_temp.check_eq('so is the tax', pg_temp.leg(v_entry, '1410'), 25.20);
  perform pg_temp.check_eq('and so is what left the bank',
    pg_temp.leg(v_entry, '1121'), -445.20);

  select sum(l.debit), sum(l.credit) into v_dr, v_cr
    from public.gl_lines l where l.entry_id = v_entry;
  perform pg_temp.check_eq('a converted journal still balances', v_dr, v_cr);

  perform pg_temp.check_eq('the bank falls by the ringgit, not the dollars',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    8554.80);
end $$;

-- ---------------------------------------------------------------------
-- The rate that rounds both ways
--
-- The cost and the tax are converted and rounded one at a time; the
-- credit converts and rounds the total in one go. Those are not the
-- same arithmetic. Where each half rounds up and the whole does not,
-- the debits come to a cent more than the credit and the journal is
-- refused — an expense that cannot be posted at all, with a message
-- about the ledger rather than about the rate.
--
-- 10.05 plus 0.85 tax at 1.5: 15.075 and 1.275 each round up to make
-- 16.36, against a total of 10.90 at 1.5 which is exactly 16.35.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.money_org('Rounder Sdn Bhd');
  v_bank uuid; v_exp uuid; v_entry uuid; v_dr numeric; v_cr numeric;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp  := pg_temp.an_expense(v_org, 'EXP-4', '6250', 10.05, 0.85, 10.90,
                               v_bank, 'SGD', 1.5);

  v_entry := public.post_expense(v_exp);

  select sum(l.debit), sum(l.credit) into v_dr, v_cr
    from public.gl_lines l where l.entry_id = v_entry;
  perform pg_temp.check_eq('the journal balances however the rate rounds',
    v_dr, v_cr);

  -- The credit is what actually left the bank, so it is the figure that
  -- may not move: it is reconciled against a statement. The cent comes
  -- off the cost rather than the tax, because the tax figure is what
  -- the SST-02 return is built from.
  perform pg_temp.check_eq('and what left the bank is the total, converted once',
    pg_temp.leg(v_entry, '1121'), -16.35);
  perform pg_temp.check_eq('the tax is the tax, converted', pg_temp.leg(v_entry, '1410'), 1.28);
  perform pg_temp.check_eq('and the cost carries the rounding',
    pg_temp.leg(v_entry, '6250'), 15.07);
end $$;

-- ---------------------------------------------------------------------
-- What may not be posted, and by whom
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.money_org('Guard Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_sales uuid := pg_temp.another_user('sales@iakauntan.test');
  v_bank uuid; v_exp uuid; v_gone uuid; v_ok boolean;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank Current', 9000.00);
  v_exp  := pg_temp.an_expense(v_org, 'EXP-5', '6250', 100.00, 0, 100.00, v_bank);
  v_gone := pg_temp.an_expense(v_org, 'EXP-6', '6250', 100.00, 0, 100.00, v_bank);

  begin
    perform public.post_expense(gen_random_uuid());
    raise exception 'FAIL: posted an expense that does not exist';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'ok   an expense that does not exist is refused';
  end;

  -- Somebody who may raise an expense is not somebody who may put it in
  -- the ledger.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_sales, 'sales') on conflict do nothing;
  perform pg_temp.sign_in_as(v_sales);
  begin
    perform public.post_expense(v_exp);
    raise exception 'FAIL: a salesperson posted to the ledger';
  exception when sqlstate '42501' then
    raise notice 'ok   somebody who may not post is refused';
  end;

  -- And refused by this function rather than by the ledger behind it.
  --
  -- The assertion above passes with `post_expense`'s own `can_post`
  -- deleted, because `create_gl_entry_internal` checks the same thing
  -- four steps later and raises 42501 too. It reports on the ledger's
  -- guard, not on this one, which makes it no use for the thing it looks
  -- like it is testing.
  --
  -- What is this function's alone is the order. Permission is settled
  -- before the expense's own numbers are looked at, so a non-poster
  -- handed an expense that does not add up is told about the permission.
  -- Delete the guard and the same call answers 23514, from a check that
  -- runs first only because the one before it is gone.
  begin
    perform public.post_expense(
      pg_temp.an_expense(v_org, 'EXP-8', '6250', 100.00, 6.00, 100.00, v_bank));
    raise exception 'FAIL: the wrong refusal reached a salesperson';
  exception when sqlstate '42501' then
    raise notice 'ok   and refused for the reason this function gives';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- A total that disagrees with its own parts. `total_amount` is an
  -- ordinary column with a default of zero and nothing in the schema
  -- keeps it equal to `amount + tax_amount`, so this was refused before
  -- 0286 as well — but by the balance check, three steps later, in a
  -- sentence about debits and credits. What is asserted is the errcode
  -- and that it is the expense's own numbers being complained about.
  begin
    perform public.post_expense(
      pg_temp.an_expense(v_org, 'EXP-7', '6250', 100.00, 6.00, 100.00, v_bank));
    raise exception 'FAIL: posted an expense that does not add up';
  exception when sqlstate '23514' then
    raise notice 'ok   a total that disagrees with its parts is refused';
  end;

  -- A deleted expense is not a document. Every other posting function in
  -- the schema refuses one — `post_sales_document`, `post_receipt` and
  -- `post_purchase_document` all check `deleted_at` — and an expense
  -- somebody removed from the list still reaching the ledger puts a cost
  -- in the accounts that no screen will ever show them again.
  update public.expenses set deleted_at = now() where id = v_gone;
  v_ok := false;
  begin
    perform public.post_expense(v_gone);
  exception when others then
    v_ok := true;
  end;
  perform pg_temp.check_true('a deleted expense is refused', v_ok);
  perform pg_temp.check_eq('and nothing of it reaches the ledger',
    (select count(*) from public.gl_entries g
      where g.source_table = 'expenses' and g.source_id = v_gone), 0);
  perform pg_temp.check_true('nor is it marked posted',
    (select e.gl_entry_id is null and e.status <> 'posted'
       from public.expenses e where e.id = v_gone));
end $$;

rollback;
