-- =====================================================================
-- iAkauntan :: an expense is kept as it was posted (0824)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posted_expense_kept.sql
--
-- `post_expense` journals an expense and marks it posted. Before `0824`
-- a client could rewrite a posted RM500 expense to RM50, move its date,
-- set it back to draft and delete it, with the RM500 out of the bank
-- left in the ledger to explain itself. Asked as the owner, with the
-- role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pe (org uuid, bank uuid, exp1 uuid, exp2 uuid, entry uuid);
grant select, update on t_pe to authenticated;

do $$
declare
  r t_pe;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Belanja Beku Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  r.bank := pg_temp.test_bank_account(r.org, 'Maybank current', 'current', 'MYR', 0, 0, '1234');
  insert into t_pe select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_pe;
  r record;
begin
  select * into d from t_pe;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- Recorded as the app records one: a draft.
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id,
     description, currency, exchange_rate, amount, tax_amount)
  values (d.org, 'EXP-1', date '2026-03-04',
          (select id from public.accounts where org_id = d.org and code = '6100'),
          d.bank, 'Printer ink', 'MYR', 1, 450, 0)
  returning id into d.exp1;
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id,
     description, currency, exchange_rate, amount, tax_amount)
  values (d.org, 'EXP-2', date '2026-03-05',
          (select id from public.accounts where org_id = d.org and code = '6100'),
          d.bank, 'Toner', 'MYR', 1, 80, 0)
  returning id into d.exp2;
  update t_pe set exp1 = d.exp1, exp2 = d.exp2;

  -- A draft is the app's to correct, as before.
  update public.expenses set amount = 500, description = 'Printer ink, two boxes'
   where id = d.exp1;
  perform pg_temp.check_eq('a draft is corrected as before',
    (select amount || '/' || status from public.expenses where id = d.exp1), '500.00/draft');

  -- Its state is the functions'.
  perform pg_temp.check_refused('a draft is not marked posted by hand',
    format($q$update public.expenses set status = 'posted' where id = %L$q$, d.exp2),
    'EXP-2 becomes posted by posting it%', '42501');
  perform pg_temp.check_refused('nor given a posting time',
    format('update public.expenses set posted_at = now() where id = %L', d.exp2),
    'EXP-2 becomes posted by posting it%', '42501');

  -- Nor created posted.
  for r in select * from (values
      ('status', '''posted''', 'an expense is not created posted'),
      ('posted_at', 'now()', 'nor with a posting time'),
      ('gl_entry_id', 'gen_random_uuid()', 'nor with a journal'))
      as t(col, val, label)
  loop
    perform pg_temp.check_refused(r.label,
      format($q$insert into public.expenses
                  (org_id, expense_no, expense_date, account_id, bank_account_id,
                   currency, exchange_rate, amount, tax_amount, %s)
                values (%L, 'EXP-X', date '2026-03-06',
                        (select id from public.accounts where org_id = %L and code = '6100'),
                        %L, 'MYR', 1, 10, 0, %s)$q$,
             r.col, d.org, d.org, d.bank, r.val),
      'An expense is recorded as a draft%', '42501');
  end loop;

  -- Posted by posting it.
  perform public.post_expense(d.exp1);
  select gl_entry_id into d.entry from public.expenses where id = d.exp1;
  update t_pe set entry = d.entry;
  perform pg_temp.check_eq('EXP-1 is posted: RM500 out of the bank on 4 March',
    (select e.status || '/' || e.total_amount || '/' || e.expense_date || '/'
            || (select sum(l.credit) from public.gl_lines l where l.entry_id = e.gl_entry_id)
       from public.expenses e where e.id = d.exp1), 'posted/500.00/2026-03-04/500.00');

  perform pg_temp.check_refused('a draft is not handed a posted one''s journal',
    format('update public.expenses set gl_entry_id = %L where id = %L', d.entry, d.exp2),
    'EXP-2 becomes posted by posting it%', '42501');

  -- What was measured: rewritten, set back, deleted.
  perform pg_temp.check_refused('a posted expense is not rewritten to RM50',
    format('update public.expenses set amount = 50, total_amount = 50 where id = %L', d.exp1),
    'EXP-1 is posted, and its amount is what its journal was built from.%', '42501');
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.expenses where id = %L', d.exp1),
    'EXP-1 is posted: its journal is in the ledger%', '42501');

  -- Every journalled column, each on its own, so none is kept only by
  -- another. The trigger answers before a foreign key or a policy does,
  -- so any value will do.
  for r in select * from (values
      ('org_id', 'gen_random_uuid()'),
      ('expense_no', '''EXP-99'''),
      ('expense_date', 'date ''2026-05-01'''),
      ('contact_id', 'gen_random_uuid()'),
      ('account_id', 'gen_random_uuid()'),
      ('bank_account_id', 'gen_random_uuid()'),
      ('payment_mode_code', '''02'''),
      ('currency', '''USD'''),
      ('exchange_rate', '4.5'),
      ('amount', '50'),
      ('tax_code_id', 'gen_random_uuid()'),
      ('tax_amount', '30'),
      ('total_amount', '50'),
      ('branch_id', 'gen_random_uuid()'),
      ('department_code', '''OPS'''),
      ('project_code', '''P-1'''),
      ('matter_id', 'gen_random_uuid()'),
      ('status', '''draft'''),
      ('gl_entry_id', 'null'),
      ('posted_at', 'null'),
      ('deleted_at', 'now()'))
      as t(col, val)
  loop
    perform pg_temp.check_refused(format('nor its %s', r.col),
      format('update public.expenses set %s = %s where id = %L', r.col, r.val, d.exp1),
      format('EXP-1 is posted, and its %s is what its journal was built from.%%', r.col),
      '42501');
  end loop;

  -- What can still be put right.
  -- (Its receipt is in the attachments module, a table of its own.)
  update public.expenses
     set description = 'Printer ink, two boxes (HP 63)',
         reference = 'INV-88213'
   where id = d.exp1;
  perform pg_temp.check_eq('its description and reference can still be put right',
    (select description || '/' || reference from public.expenses where id = d.exp1),
    'Printer ink, two boxes (HP 63)/INV-88213');

  perform pg_temp.check_eq('so it still says what its journal says',
    (select status || '/' || total_amount || '/' || expense_date
       from public.expenses where id = d.exp1), 'posted/500.00/2026-03-04');

  -- And a draft is deleted as before.
  delete from public.expenses where id = d.exp2;
  perform pg_temp.check_eq('a draft is deleted as before',
    (select count(*)::integer from public.expenses where id = d.exp2), 0);
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: `post_expense` and `set_expense_split` are the only
-- writers of `expenses` and both are definers, which run as the owner at
-- any depth. It is kept for the first trigger that writes an expense on
-- a client's behalf.
do $$
declare d t_pe;
begin
  select * into d from t_pe;
  update public.expenses set project_code = 'P-OWNER' where id = d.exp1;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select project_code from public.expenses where id = d.exp1), 'P-OWNER');
end $$;

rollback;
