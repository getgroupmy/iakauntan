-- =====================================================================
-- iAkauntan :: an expense adds up its own total
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/expense_total.sql
--
-- `0722`. `expenses.total_amount` was the one money figure in this
-- database that the app computed and the database only stored --
-- `Repo.recordExpense` sent `amount + taxAmount` and nothing here
-- checked it. Every other document total is derived by SQL.
--
-- What has to be true now:
--
--   * A TOTAL NOBODY SENT IS STILL RIGHT. An insert that leaves
--     `total_amount` off gets the sum, rather than the column default
--     of 0 -- which is what an importer or a support session would hit.
--   * A WRONG TOTAL IS OVERWRITTEN, not stored and not rejected. The
--     trigger is BEFORE and derives; `0722` says why that beats a check
--     constraint, which would have refused writes `0496`, `0639` and
--     `0692` already make.
--   * CHANGING A PART CHANGES THE TOTAL. An update that moves `amount`
--     alone must not leave a total belonging to the old figure.
--   * AND IT ROUNDS TO THE SEN, because the column's scale would anyway
--     and the rounding should be visible where it is decided.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_account uuid;
  v_id      uuid;
  v_total   numeric;
  v_tax     numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Belanja Tepat Sdn Bhd');

  select id into v_account
    from public.accounts
   where org_id = v_org and code = '6100'
   limit 1;
  if v_account is null then
    select id into v_account from public.accounts
     where org_id = v_org limit 1;
  end if;
  if v_account is null then
    raise exception 'FAIL: the fixture company has no accounts to spend on';
  end if;

  -- -------------------------------------------------------------------
  -- A total nobody sent
  -- -------------------------------------------------------------------
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, amount, tax_amount)
  values (v_org, 'EXP-T1', date '2026-03-04', v_account, 1086.12, 86.89)
  returning id, total_amount into v_id, v_total;

  if v_total is distinct from 1173.01 then
    raise exception
      'FAIL: an expense of 1086.12 + 86.89 totalled %, not 1173.01. '
      'The total is derived by app.expense_total(); a 0 here means the '
      'trigger is not on the table.', v_total;
  end if;

  -- -------------------------------------------------------------------
  -- A wrong total is overwritten rather than stored
  --
  -- This is the one that matters. Every writer of this column computes
  -- the sum today, so the column is right by convention -- the question
  -- is what happens to the writer that does not.
  -- -------------------------------------------------------------------
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id,
     amount, tax_amount, total_amount)
  values (v_org, 'EXP-T2', date '2026-03-04', v_account, 100.00, 6.00,
          999999.99)
  returning total_amount into v_total;

  if v_total is distinct from 106.00 then
    raise exception
      'FAIL: an expense sent a total of 999999.99 against parts of '
      '100.00 + 6.00 and stored %. The total must be derived from its '
      'parts whoever writes it.', v_total;
  end if;

  -- -------------------------------------------------------------------
  -- Changing a part changes the total
  -- -------------------------------------------------------------------
  update public.expenses
     set amount = 250.00
   where id = v_id
  returning total_amount into v_total;

  if v_total is distinct from 336.89 then
    raise exception
      'FAIL: the amount moved to 250.00 with 86.89 of tax and the total '
      'is %, not 336.89. An update that touches one part has to move '
      'the total with it.', v_total;
  end if;

  -- And the other part, on its own.
  update public.expenses
     set tax_amount = 0
   where id = v_id
  returning total_amount, tax_amount into v_total, v_tax;

  if v_tax is distinct from 0 or v_total is distinct from 250.00 then
    raise exception
      'FAIL: the tax was cleared and the expense totals % with % of '
      'tax, not 250.00 with 0.', v_total, v_tax;
  end if;

  -- -------------------------------------------------------------------
  -- Sub-sen input is rounded at the COLUMN, not by the trigger
  --
  -- This started as an assertion that the trigger's `round(..., 2)`
  -- rounds 0.005 + 0.005 to 0.01, and it failed against a real Postgres
  -- with 0.02. The premise was wrong in a way worth keeping:
  --
  --   `amount` and `tax_amount` are THEMSELVES numeric(18, 2). A BEFORE
  --   trigger sees NEW already coerced to the table's rowtype, so each
  --   part is rounded to the sen -- 0.005 to 0.01, half away from zero
  --   -- before the addition happens. 0.01 + 0.01 is 0.02.
  --
  -- Which means the trigger's own `round(..., 2)` cannot currently fire:
  -- the sum of two numeric(18, 2) values is always exactly two decimal
  -- places. It is kept as insurance against a scale changing, and `0722`
  -- says so rather than implying it does work it cannot.
  --
  -- What is asserted here is the reachable truth, and it is the one
  -- somebody entering a sub-sen figure actually needs: the money is
  -- rounded, not truncated. Truncation would lose a sen per line.
  -- -------------------------------------------------------------------
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, amount, tax_amount)
  values (v_org, 'EXP-T3', date '2026-03-04', v_account, 0.005, 0.004)
  returning total_amount into v_total;

  if v_total is distinct from 0.01 then
    raise exception
      'FAIL: 0.005 and 0.004 were stored as parts and totalled %. Each '
      'part rounds to the sen at the column -- 0.01 and 0.00 -- so the '
      'total is 0.01. A 0.00 here would mean the column TRUNCATES, '
      'which loses a sen a line.', v_total;
  end if;

  raise notice 'ok   an expense derives its own total from its parts';
end;
$$;

rollback;
