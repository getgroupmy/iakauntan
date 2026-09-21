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

-- ---------------------------------------------------------------------
-- The fifteen a mutation sweep found
--
-- Forty-six one-line mutants of `post_expense` against twenty-three test
-- files. Thirty-one died, the best starting ratio of this programme --
-- and every one of them is the arithmetic this file was written for:
-- the total converted once into a variable, the cost leg taken as the
-- remainder rather than converted on its own, each line but the largest
-- converted separately, the largest chosen by AMOUNT and taking what is
-- left, the credit leg gross of tax, the bank balance reduced by the
-- converted total.
--
-- The fifteen that survived are the front door, the DATE, and what each
-- line CARRIES -- the party, the project, the description, the tax code.
-- None of those changes a figure, which is exactly why none was
-- asserted: every one of them is invisible to a test that adds the
-- debits up.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.split_org('Bawa Sdn Bhd');
  v_owner uuid := (select user_id from public.org_members
                    where org_id = v_org and role = 'owner' limit 1);
  v_bank uuid; v_exp uuid; v_entry uuid; v_msg text;
  v_contact uuid; v_tax uuid; v_stranger uuid;
begin
  v_bank := pg_temp.a_bank(v_org, '1121', 'Maybank', 9000.00);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S', 'Kedai', 'supplier') returning id into v_contact;
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, is_exempt)
  values (v_org, 'SST6', 'Service tax', '01', 6, false) returning id into v_tax;
  insert into public.projects (org_id, code, name)
  values (v_org, 'P-A', 'Projek A'), (v_org, 'P-B', 'Projek B')
  on conflict do nothing;

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.post_expense(gen_random_uuid());
    raise exception 'an expense that does not exist was posted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an expense that does not exist',
      v_msg like 'Expense % not found');
  end;

  v_exp := pg_temp.an_expense(v_org, 'EXP-P1', '6280', 100.00, 0, 100.00, v_bank);
  perform public.post_expense(v_exp);
  begin
    perform public.post_expense(v_exp);
    raise exception 'an expense was posted twice';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('and one already posted is refused',
      v_msg, 'Expense EXP-P1 is already posted');
  end;
  perform pg_temp.check_eq('with the bank charged once, not twice',
    (select current_balance from public.bank_accounts where id = v_bank),
    8900.00::numeric);

  -- ==================================================================
  -- 2. The date
  --
  -- THE DATE, for the eighth time in this programme. The journal takes
  -- the day the money was spent. Dated today, a card charge entered in
  -- April lands in whatever month it was typed -- the profit and loss
  -- disagrees with the statement it was read from, and a locked period
  -- does not stop it, because the entry was never in that period.
  -- ==================================================================
  v_exp := pg_temp.an_expense(v_org, 'EXP-P2', '6280', 200.00, 0, 200.00, v_bank);
  v_entry := public.post_expense(v_exp);
  perform pg_temp.check_true('the journal is dated the day it was spent',
    (select entry_date = date '2026-03-04' from public.gl_entries
      where id = v_entry));

  -- ==================================================================
  -- 3. What the lines carry
  --
  -- The party, so a supplier's spend can be found without a bill; the
  -- project, so it reaches the budget; the description, so the general
  -- ledger reads as something other than the expense number repeated.
  -- ==================================================================
  -- Assigned to a variable, never called from a WHERE clause: the
  -- helper inserts, and the planner may run it once per row scanned.
  v_exp := pg_temp.an_expense(v_org, 'EXP-P3', '6280', 300.00, 0, 300.00,
                              v_bank);
  update public.expenses
     set contact_id = v_contact, project_code = 'P-A',
         description = 'Kad syarikat'
   where id = v_exp;
  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('an unsplit expense names its party',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6280'
        and l.contact_id = v_contact), 1);
  perform pg_temp.check_eq('and carries its project',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6280'
        and l.project_code = 'P-A'), 1);

  -- Split, with a line that names its own project and one that does
  -- not, and a line with its own wording.
  v_exp := pg_temp.an_expense(v_org, 'EXP-P4', '6280', 500.00, 0,
                              500.00, v_bank);
  update public.expenses
     set contact_id = v_contact, project_code = 'P-A',
         description = 'Kad syarikat'
   where id = v_exp;
  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6280'),
                       'amount', 320.00, 'description', 'Tambang',
                       'project_code', 'P-B'),
    jsonb_build_object('account_id', pg_temp.acct(v_org, '6250'),
                       'amount', 180.00)));
  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('every split line names the party',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code in ('6280', '6250')
        and l.contact_id = v_contact), 2);
  perform pg_temp.check_eq('a line''s own project is the one used',
    (select l.project_code from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6280'), 'P-B');
  perform pg_temp.check_eq('and a line with none takes the expense''s',
    (select l.project_code from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6250'), 'P-A');
  perform pg_temp.check_eq('a line''s own wording is the one written',
    (select l.description from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6280'), 'Tambang');
  perform pg_temp.check_eq('and a line with none takes the expense''s',
    (select l.description from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6250'), 'Kad syarikat');

  -- The lines are written in their own order, so the general ledger
  -- reads down the receipt rather than up it.
  perform pg_temp.check_eq('the split lines are written in order',
    (select string_agg(a.code, ',' order by l.line_no)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code in ('6280', '6250')),
    '6280,6250');

  -- ==================================================================
  -- 4. The tax line
  --
  -- The figure was asserted; what makes it claimable was not. A tax
  -- line with no tax code on it is not in the SST return, and an input
  -- credit that is not in the return is not claimed.
  -- ==================================================================
  v_exp := pg_temp.an_expense(v_org, 'EXP-P5', '6280', 100.00, 6.00,
                              106.00, v_bank);
  update public.expenses set tax_code_id = v_tax where id = v_exp;
  v_entry := public.post_expense(v_exp);
  perform pg_temp.check_eq('the input tax line names the tax code',
    (select count(*) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1410'
        and l.tax_code_id = v_tax), 1);
  perform pg_temp.check_eq('and declares the tax it is claiming',
    (select l.tax_amount from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1410'), 6.00::numeric);

  -- ==================================================================
  -- 5. An expense paid in cash
  --
  -- No bank_accounts row to adjust. The ledger leg falls back to 1120,
  -- and the balance update must NOT run -- there is nothing for it to
  -- run against, and firing it unconditionally would move whichever
  -- account a null id happened to reach, or none at all while claiming
  -- to have.
  -- ==================================================================
  declare v_before numeric;
  begin
    select current_balance into v_before from public.bank_accounts where id = v_bank;
    v_exp := pg_temp.an_expense(v_org, 'EXP-P6', '6280', 50.00, 0, 50.00,
                                null);
    v_entry := public.post_expense(v_exp);
    perform pg_temp.check_eq('cash comes out of the current account',
      pg_temp.leg(v_entry, '1120'), -50.00::numeric);
    perform pg_temp.check_eq('and no bank account balance moves',
      (select current_balance from public.bank_accounts where id = v_bank),
      v_before);
  end;

  -- ==================================================================
  -- 6. The rate the journal is stamped with
  --
  -- Not the conversion -- that is asserted above and all through this
  -- file -- but the rate RECORDED on the entry. It is what a
  -- revaluation reads to know what this entry was taken at, and what a
  -- reader comparing the ringgit against the foreign figure divides by.
  -- Written as 1 on a journal converted at 4.70, the two disagree and
  -- nothing recomputes it.
  -- ==================================================================
  declare v_usd uuid;
  begin
    v_usd := pg_temp.an_expense(v_org, 'EXP-P7', '6280', 100.00, 0, 100.00,
                                v_bank, 'USD', 4.70);
    v_entry := public.post_expense(v_usd);
    perform pg_temp.check_eq('the journal is stamped with the rate used',
      (select exchange_rate from public.gl_entries where id = v_entry),
      4.70::numeric);
    perform pg_temp.check_eq('and with the currency it was spent in',
      (select currency from public.gl_entries where id = v_entry), 'USD');
    perform pg_temp.check_eq('while the ledger carries the ringgit',
      pg_temp.leg(v_entry, '6280'), 470.00::numeric);
  end;

  -- TWO EQUIVALENT MUTANTS, the eleventh and twelfth of this programme,
  -- both unreachable rather than untested.
  --
  -- `coalesce(v_exp.exchange_rate, 1)` cannot fire: expenses.exchange_rate
  -- is NOT NULL.
  --
  -- And `if v_exp.bank_account_id is not null` around the balance
  -- update cannot change an outcome either, because
  -- `update bank_accounts where id = null` matches no row. It is kept
  -- because it states the intent where a reader looks for it, and
  -- because a later change joining that update to something else would
  -- need it. The cash probe above asserts the behaviour it guards.

  -- ==================================================================
  -- 7. Who may post one
  -- ==================================================================
  v_stranger := pg_temp.another_user('stranger@bawa.test');
  v_exp := pg_temp.an_expense(v_org, 'EXP-P8', '6280', 20.00, 0, 20.00,
                              v_bank);
  perform pg_temp.sign_in_as(v_stranger);
  begin
    perform public.post_expense(v_exp);
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('somebody who may not post may not post one',
    v_msg, 'Insufficient privileges to post');

  raise notice 'ok   expenses: the fifteen a sweep found';
end $$;


-- ---------------------------------------------------------------------
-- 0639: the department a claimed cost belongs to
--
-- `expenses` carried a `project_code` and no `department_code`, so a
-- cost claimed on an expense reached `gl_lines` with a null department
-- however carefully it had been coded -- and the P&L's department
-- filter answered confidently while omitting every one of them.
--
-- A department whose spending arrived that way read as a department
-- that had UNDERSPENT. That is the worst shape a reporting hole can
-- take: an error that reads as an error gets fixed, and this one read
-- as good news.
--
-- What is asserted is the whole path, header and line, plus the two
-- legs that must NOT carry it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.split_org('Claimed Costs Sdn Bhd');
  v_bank uuid;
  v_exp uuid;
  v_entry uuid;
  v_tax_acct uuid;
begin
  insert into public.departments (org_id, code, name)
  values (v_org, 'OPS', 'Operations'), (v_org, 'MKT', 'Marketing');

  select id into v_bank from public.bank_accounts where org_id = v_org
   limit 1;
  if v_bank is null then
    insert into public.bank_accounts (org_id, name, account_id)
    values (v_org, 'Current', (select id from public.accounts
                                where org_id = v_org and code = '1110'))
    returning id into v_bank;
  end if;

  -- A whole claim for one department, which is the common case: a trip.
  v_exp := pg_temp.an_expense(v_org, 'EXP-D1', '6100',
                              100, 0, 100, v_bank);
  update public.expenses set department_code = 'OPS' where id = v_exp;
  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('the claimed cost carries its department',
    (select department_code from public.gl_lines
      where entry_id = v_entry
        and account_id = (select id from public.accounts
                           where org_id = v_org and code = '6100')),
    'OPS');

  -- And the bank leg does NOT. A payment out of an account is not a
  -- departmental cost, and putting one on it would make every
  -- department's figures include the cash it spent as well as the
  -- expense that spent it.
  perform pg_temp.check_true('but the bank leg does not',
    (select department_code is null from public.gl_lines
      where entry_id = v_entry and credit > 0));

  -- A split claim, where each line answers for itself. The line wins
  -- over the header, the same way `project_code` already does.
  v_exp := pg_temp.an_expense(v_org, 'EXP-D2', '6100',
                              300, 0, 300, v_bank);
  update public.expenses set department_code = 'OPS' where id = v_exp;
  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = v_org and code = '6100'),
      'amount', 200, 'department_code', 'MKT'),
    jsonb_build_object(
      'account_id', (select id from public.accounts
                      where org_id = v_org and code = '6200'),
      'amount', 100)));
  v_entry := public.post_expense(v_exp);

  perform pg_temp.check_eq('a split line overrides the header',
    (select department_code from public.gl_lines
      where entry_id = v_entry and debit = 200),
    'MKT');

  perform pg_temp.check_eq('and a line that names none falls back to it',
    (select department_code from public.gl_lines
      where entry_id = v_entry and debit = 100),
    'OPS');

  -- So one claim reaches two departments, which is the reason the
  -- column is on the line as well as the header.
  perform pg_temp.check_eq('one claim, two departments',
    (select count(distinct department_code)::int from public.gl_lines
      where entry_id = v_entry and debit > 0), 2);

  -- Input tax is not a departmental cost either. Asserted separately
  -- from the bank leg because it is a DEBIT, so a rule written as
  -- "only debits carry a department" would pass the test above and
  -- still double-count here.
  select id into v_tax_acct from public.accounts
   where org_id = v_org and code = '1410';
  v_exp := pg_temp.an_expense(v_org, 'EXP-D3', '6100',
                              100, 6, 106, v_bank);
  update public.expenses set department_code = 'OPS' where id = v_exp;
  v_entry := public.post_expense(v_exp);
  perform pg_temp.check_true('and reclaimed tax carries no department',
    (select department_code is null from public.gl_lines
      where entry_id = v_entry and account_id = v_tax_acct));

  -- Null stays null. Most claims have no departmental meaning, and a
  -- dimension that has to be filled in is a dimension people type
  -- anything into.
  v_exp := pg_temp.an_expense(v_org, 'EXP-D4', '6100',
                              40, 0, 40, v_bank);
  v_entry := public.post_expense(v_exp);
  perform pg_temp.check_eq('a claim may name no department at all',
    (select count(*)::int from public.gl_lines
      where entry_id = v_entry and department_code is not null), 0);

  -- The project is untouched by any of this. Both dimensions are
  -- independent, and a claim can carry one, the other or both.
  insert into public.projects (org_id, code, name)
  values (v_org, 'JOB-7', 'Job seven');
  v_exp := pg_temp.an_expense(v_org, 'EXP-D5', '6100',
                              70, 0, 70, v_bank);
  update public.expenses
     set department_code = 'MKT', project_code = 'JOB-7'
   where id = v_exp;
  v_entry := public.post_expense(v_exp);
  perform pg_temp.check_eq('and carries both dimensions at once',
    (select project_code || '/' || department_code from public.gl_lines
      where entry_id = v_entry and debit = 70),
    'JOB-7/MKT');
end $$;

rollback;
