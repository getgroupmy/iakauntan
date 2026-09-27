-- =====================================================================
-- iAkauntan :: a photographed statement becomes bank lines
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_statement_scan.sql
--
-- `0683`. The path a bank statement takes from a photograph to
-- `bank_transactions` runs through four pieces that were built at four
-- different times and have never been asserted as one thing:
--
--   `scan_targets`         says the target repeats          (0682)
--   `scan_target_fields`   says which five columns          (0683)
--   `scan_extraction_targets` is what the reader is sent    (0682)
--   `import_bank_transactions` is what the rows land in     (0369)
--
-- The seam that breaks silently is between the middle two and the
-- last: the field names ticked in `scan_target_fields` are what the
-- reader answers under, and they have to be the keys
-- `import_bank_transactions` reads. Nothing joins those two -- one is
-- a table of strings, the other is `->>` on a jsonb -- so a rename on
-- either side is invisible until a statement imports as nothing.
--
-- And `scan_extraction_targets` only offers a target that has at least
-- one field, which is the quiet failure `0683` exists to prevent: with
-- the ticks missing the reader is never asked for statement lines and
-- every photograph comes back correctly empty.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_acct  uuid;
  v_t     jsonb;
  v_out   jsonb;
  v_n     integer;
  v_col   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Statement Scan Sdn Bhd');

  -- -------------------------------------------------------------------
  -- The target repeats, and it is ticked
  -- -------------------------------------------------------------------
  perform pg_temp.check_true(
    'a bank statement is a target that repeats',
    (select repeats from public.scan_targets
      where module_code = 'accounting' and action = 'bank_statement'));

  select count(*) into v_n from public.scan_target_fields
   where module_code = 'accounting' and action = 'bank_statement';
  perform pg_temp.check_eq(
    'and it ships with its five printed columns ticked', v_n, 5);

  -- Every ticked column is a real column of the table the target
  -- names. `set_scan_target_fields` refuses one that is not, but this
  -- seed goes in with a plain insert and would not be refused.
  for v_col in
    select column_name from public.scan_target_fields
     where module_code = 'accounting' and action = 'bank_statement'
  loop
    perform pg_temp.check_true(
      format('%s is a real column of bank_transactions', v_col),
      exists (select 1 from information_schema.columns
               where table_schema = 'public'
                 and table_name = 'bank_transactions'
                 and column_name = v_col));
  end loop;

  perform pg_temp.check_true(
    'the running balance is among them, because it is what proves the rest',
    exists (select 1 from public.scan_target_fields
             where module_code = 'accounting' and action = 'bank_statement'
               and column_name = 'running_balance'));

  perform pg_temp.check_true(
    'and every one of them tells the reader what to look for',
    not exists (select 1 from public.scan_target_fields
                 where module_code = 'accounting'
                   and action = 'bank_statement'
                   and coalesce(trim(description), '') = ''));

  -- -------------------------------------------------------------------
  -- What the reader is actually sent
  --
  -- `scan_extraction_targets` drops a target with no fields, so before
  -- `0683` this returned nothing for a statement and no photograph of
  -- one could ever produce a row.
  -- -------------------------------------------------------------------
  select x into v_t
    from jsonb_array_elements(public.scan_extraction_targets()) x
   where x ->> 'key' = 'accounting.bank_statement';

  perform pg_temp.check_true(
    'the reader is offered the statement target at all', v_t is not null);
  perform pg_temp.check_true(
    'and told that it repeats', (v_t -> 'repeats')::boolean);
  perform pg_temp.check_eq(
    'with all five fields on it',
    jsonb_array_length(v_t -> 'fields'), 5);

  -- -------------------------------------------------------------------
  -- The seam: the names the reader answers under are the names the
  -- import reads
  -- -------------------------------------------------------------------
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current', 'Maybank', '514011223344', 'MYR')
  returning id into v_acct;

  -- Built from the ticked names themselves rather than typed out, so
  -- the assertion moves when the ticks move.
  v_out := public.import_bank_transactions(v_acct, (
    select jsonb_agg(line order by n)
      from (
        select 1 as n, jsonb_object_agg(f.column_name,
                 case f.column_name
                   when 'transaction_date' then '2026-09-01'
                   when 'description'      then 'BEGINNING BALANCE ADJ'
                   when 'reference'        then 'REF001'
                   when 'amount'           then '1900.00'
                   when 'running_balance'  then '1900.00'
                 end) as line
          from public.scan_target_fields f
         where f.module_code = 'accounting' and f.action = 'bank_statement'
        union all
        select 2, jsonb_object_agg(f.column_name,
                 case f.column_name
                   when 'transaction_date' then '2026-09-03'
                   when 'description'      then 'CHQ 100123'
                   when 'reference'        then 'REF002'
                   when 'amount'           then '-250.00'
                   when 'running_balance'  then '1650.00'
                 end)
          from public.scan_target_fields f
         where f.module_code = 'accounting' and f.action = 'bank_statement'
      ) s));

  perform pg_temp.check_eq(
    'a reading under the ticked names imports as lines',
    (v_out ->> 'imported')::integer, 2);
  perform pg_temp.check_eq(
    'and its balances were checked against each other',
    (v_out ->> 'balance_checks')::integer, 1);
  perform pg_temp.check_eq(
    'and the closing figure comes off the statement, not a typed one',
    (v_out ->> 'closing_balance')::numeric, 1650.00);

  perform pg_temp.check_true(
    'a withdrawal read as a negative amount is stored as one',
    exists (select 1 from public.bank_transactions
             where bank_account_id = v_acct
               and amount = -250.00
               and transaction_type = 'withdrawal'));

  -- The balance is not decoration: a reading that dropped the middle
  -- line of three is refused rather than imported short. This is the
  -- only defence there is against a reader that skipped a line, and it
  -- works only because `running_balance` is ticked above.
  perform pg_temp.check_refused(
    'a reading with a line missing is refused, not imported short',
    format($q$select public.import_bank_transactions(%L, %L::jsonb)$q$,
      v_acct,
      '[{"transaction_date":"2026-10-01","amount":"100.00","running_balance":"1750.00"},
        {"transaction_date":"2026-10-03","amount":"100.00","running_balance":"1950.00"}]'),
    '%running balance%');
end $$;

rollback;
