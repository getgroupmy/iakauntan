-- =====================================================================
-- iAkauntan :: what a bank line means
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_rules.sql
--
-- `0625`. A rule reads a statement line and says what it is. The three
-- things worth asserting are not "does a LIKE work":
--
--   * **order decides.** Two rules match the same line and the
--     bookkeeper's ordering picks one. A suggestion that changed
--     between two reads, or handed back both, would hand the decision
--     back to the person the rule exists to spare.
--   * **direction is the sign, not the label.** A statement that calls
--     a refund a "deposit" and one that calls it "other" have to match
--     the same rule, and `transaction_type` is whatever the bank wrote.
--   * **the empty rule is refused.** A rule with no condition matches
--     every line on the statement, and a rule with no action matches
--     and does nothing. Both read as a half-filled form and behave as a
--     disaster; both are constraints rather than form validation,
--     because form validation holds until somebody writes a row another
--     way.
--
-- And the whole of 0625 posts nothing, which the last block checks by
-- looking at what the functions are rather than by trusting the prose.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.bank_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.an_account(p_org uuid, p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.bank_accounts (org_id, name, account_id, currency)
  values (p_org, p_name,
          (select id from public.accounts
            where org_id = p_org and code = '1120'), 'MYR')
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function pg_temp.a_line(
  p_org uuid, p_bank uuid, p_desc text, p_amount numeric,
  p_ref text default null, p_type text default 'other')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.bank_transactions
    (org_id, bank_account_id, transaction_date, description, reference,
     amount, transaction_type)
  values (p_org, p_bank, date '2026-04-10', p_desc, p_ref, p_amount, p_type)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- A rule has to say something and has to do something
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.bank_org('Peraturan Bank Sdn Bhd');
  v_acct uuid := (select id from public.accounts
                   where org_id = v_org and code = '6210');
  v_msg  text;
begin
  begin
    insert into public.bank_rules (org_id, name, account_id)
    values (v_org, 'Catches everything', v_acct);
    v_msg := null;
  exception when check_violation then v_msg := 'refused';
  end;
  perform pg_temp.check_eq('a rule with no condition is refused', v_msg,
    'refused');

  begin
    insert into public.bank_rules (org_id, name, description_contains)
    values (v_org, 'Does nothing', 'TNB');
    v_msg := null;
  exception when check_violation then v_msg := 'refused';
  end;
  perform pg_temp.check_eq('and a rule with no action is refused', v_msg,
    'refused');

  begin
    insert into public.bank_rules
      (org_id, name, amount_min, amount_max, account_id)
    values (v_org, 'Backwards window', 500, 100, v_acct);
    v_msg := null;
  exception when check_violation then v_msg := 'refused';
  end;
  perform pg_temp.check_eq('and a window that holds nothing', v_msg,
    'refused');

  -- One that says and does something goes in.
  insert into public.bank_rules
    (org_id, name, description_contains, account_id)
  values (v_org, 'Electricity', 'TNB', v_acct);
  perform pg_temp.check_eq('a rule that says and does something is kept',
    (select count(*) from public.bank_rules where org_id = v_org), 1);
end $$;

-- ---------------------------------------------------------------------
-- Order decides, and direction is the sign
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.bank_org('Susunan Sdn Bhd');
  v_bank  uuid;
  v_power uuid := (select id from public.accounts
                    where org_id = v_org and code = '6210');
  v_other uuid := (select id from public.accounts
                    where org_id = v_org and code = '6900');
  v_bill  uuid;
  v_in    uuid;
  v_small uuid;
  v_odd   uuid;
begin
  v_bank := pg_temp.an_account(v_org, 'Current account');

  v_bill  := pg_temp.a_line(v_org, v_bank, 'GIRO TNB BILL PAYMENT', -430.55,
                            'TNB0425', 'withdrawal');
  -- A refund of the same bill, which the bank labelled `other` rather
  -- than `deposit`. Every statement does this differently.
  v_in    := pg_temp.a_line(v_org, v_bank, 'TNB REFUND', 120.00, null,
                            'other');
  v_small := pg_temp.a_line(v_org, v_bank, 'GIRO TNB BILL PAYMENT', -12.00,
                            'TNB0425', 'withdrawal');
  -- Money going OUT that the bank labelled `other`. Every fixture above
  -- happens to agree with its label, so a rule reading `direction` off
  -- `transaction_type` instead of the sign would pass every assertion
  -- in this file -- a mutation sweep found exactly that and it survived.
  v_odd   := pg_temp.a_line(v_org, v_bank, 'TNB DIRECT DEBIT', -250.00,
                            'TNB0425', 'other');

  -- Two rules over the same words. The narrower one is ordered first.
  insert into public.bank_rules
    (org_id, name, sort_order, description_contains, direction,
     amount_min, account_id)
  values (v_org, 'Big electricity bills', 10, 'TNB', 'out', 100, v_power);
  insert into public.bank_rules
    (org_id, name, sort_order, description_contains, account_id)
  values (v_org, 'Anything TNB', 90, 'TNB', v_other);

  -- The count first, deliberately. Every assertion below reads the
  -- suggestion as a scalar subquery, and a function that started
  -- returning two rows would kill those with `more than one row
  -- returned by a subquery` -- a death rather than an expectation, and
  -- a mutation sweep that greps for the word FAIL scores it as a
  -- survivor. Asked as a count first, the same mutant reads as what it
  -- is.
  perform pg_temp.check_eq('it suggests exactly one coding',
    (select count(*) from public.suggest_bank_coding(v_bill)), 1);
  perform pg_temp.check_eq('and it is the first rule in order',
    (select s.rule_name from public.suggest_bank_coding(v_bill) s),
    'Big electricity bills');

  -- Money in does not match a rule that says `out`, whatever the bank
  -- called the line, and falls through to the broader rule.
  perform pg_temp.check_eq('direction is read off the sign',
    (select s.rule_name from public.suggest_bank_coding(v_in) s),
    'Anything TNB');

  -- Under the window, so the narrow rule does not take it either.
  perform pg_temp.check_eq('and so is the amount window',
    (select s.rule_name from public.suggest_bank_coding(v_small) s),
    'Anything TNB');

  -- The one whose label disagrees with its sign. It is money out, so
  -- the narrow rule takes it however the bank chose to describe it.
  perform pg_temp.check_eq(
    'a payment the bank called "other" is still money out',
    (select s.rule_name from public.suggest_bank_coding(v_odd) s),
    'Big electricity bills');

  -- The window is about the SIZE of the line. `amount_min = 100`
  -- against a payment of -430.55 has to mean four hundred ringgit, not
  -- "greater than a hundred", or every rule about money going out
  -- would need to be written backwards.
  perform pg_temp.check_eq('a payment of 430 is inside "at least 100"',
    (select s.rule_name from public.suggest_bank_coding(v_bill) s),
    'Big electricity bills');

  -- ------------------------------------------------------------------
  -- Coverage counts what each rule would actually claim
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the narrow rule claims both big payments',
    (select c.matches from public.bank_rule_coverage(v_org, v_bank) c
      where c.rule_name = 'Big electricity bills'), 2);
  perform pg_temp.check_eq('and the broad rule claims what is left',
    (select c.matches from public.bank_rule_coverage(v_org, v_bank) c
      where c.rule_name = 'Anything TNB'), 2);

  -- A line nothing describes, which is the number that says whether
  -- the rules are worth having.
  perform pg_temp.a_line(v_org, v_bank, 'CASH DEPOSIT MACHINE', 900.00);
  perform pg_temp.check_eq('and one line is still unexplained',
    public.bank_lines_unexplained(v_org, v_bank), 1);

  -- Switching a rule off takes its lines back rather than hiding it.
  update public.bank_rules set is_active = false
   where org_id = v_org and name = 'Big electricity bills';
  perform pg_temp.check_eq('an inactive rule claims nothing',
    (select c.matches from public.bank_rule_coverage(v_org, v_bank) c
      where c.rule_name = 'Big electricity bills'), 0);
  perform pg_temp.check_eq('and the broad rule picks the lines up',
    (select c.matches from public.bank_rule_coverage(v_org, v_bank) c
      where c.rule_name = 'Anything TNB'), 4);
end $$;

-- ---------------------------------------------------------------------
-- Whose statement it is
-- ---------------------------------------------------------------------
do $$
declare
  v_org      uuid := pg_temp.bank_org('Sulit Bank Sdn Bhd');
  v_bank     uuid;
  v_line     uuid;
  v_stranger uuid := pg_temp.another_user('nosy@bankrules.test');
  v_msg      text;
begin
  v_bank := pg_temp.an_account(v_org, 'Current account');
  v_line := pg_temp.a_line(v_org, v_bank, 'SALARY PAYMENT', -9000);

  perform pg_temp.sign_in_as(v_stranger);
  begin
    perform * from public.suggest_bank_coding(v_line);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('a stranger cannot read the statement', v_msg,
    'refused');

  begin
    perform public.bank_lines_unexplained(v_org);
    v_msg := null;
  exception when sqlstate '42501' then v_msg := 'refused';
  end;
  perform pg_temp.sign_in_as(v_stranger);
  perform pg_temp.check_eq('nor count what it does not explain', v_msg,
    'refused');
end $$;

-- ---------------------------------------------------------------------
-- And none of it posts
--
-- The claim in 0625's header, checked rather than trusted. A function
-- that is `stable` cannot write, and Postgres enforces that -- so this
-- asserts the property the prose promises instead of grepping for the
-- word `insert`.
-- ---------------------------------------------------------------------
do $$
declare v_writes text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_writes
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.proname in ('suggest_bank_coding', 'bank_rule_coverage',
                       'bank_lines_unexplained', 'bank_rule_matches')
     and p.provolatile = 'v';

  if v_writes is not null then
    raise exception
      'FAIL 0625 says it suggests and posts nothing, and % is volatile, '
      'which is the only way it could write.', v_writes
      using errcode = 'P0004';
  end if;
  raise notice 'ok   nothing in 0625 can write';
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('the table has the grant its policy needs',
    has_table_privilege('authenticated', 'public.bank_rules', 'select'));
  perform pg_temp.check_true('and a stranger has none of it',
    not has_table_privilege('anon', 'public.bank_rules', 'select'));
  perform pg_temp.check_true('suggesting is a signed-in user''s',
    has_function_privilege('authenticated',
      'public.suggest_bank_coding(uuid)', 'execute'));
  perform pg_temp.check_true('and not a stranger''s',
    not has_function_privilege('anon',
      'public.suggest_bank_coding(uuid)', 'execute'));
end $$;

rollback;
