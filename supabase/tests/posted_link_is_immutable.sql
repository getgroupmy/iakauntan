-- =====================================================================
-- iAkauntan :: the link to the journal is written once
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posted_link_is_immutable.sql
--
-- `0403`. Eleven posting routines refuse a second posting by reading
-- `gl_entry_id` and nothing else, and every table they read it from
-- grants UPDATE to `authenticated`.
--
-- Measured before the fix, as an `accountant` under
-- `set local role authenticated`: an RM100 expense posted,
-- `gl_entry_id` set to null by hand, `post_expense` called again — two
-- entries, RM200 charged to the profit and loss for RM100 of petrol.
-- `expenses` on purpose, because `0402` had already shut this on the
-- two document tables and the question here is whether it was ever
-- about documents.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_link (org uuid, acct uuid, exp uuid, entry uuid,
                               cat uuid, rcp uuid, other_entry uuid);
grant select on t_link to authenticated;

do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user(); v_acct uuid;
  v_exp uuid; v_entry uuid; v_cat uuid;
  v_rcp uuid; v_other uuid; v_other_entry uuid;
begin
  v_org := pg_temp.test_org('Sekali Sahaja Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  select id into v_cat from public.accounts
   where org_id = v_org and not is_group and is_active
     and account_type = 'expense' order by code limit 1;

  insert into public.expenses
    (org_id, expense_no, expense_date, description, amount, tax_amount,
     total_amount, currency, exchange_rate, account_id)
  values (v_org, 'EXP-1', current_date, 'Petrol', 100, 0, 100, 'MYR', 1,
          v_cat) returning id into v_exp;
  v_entry := public.post_expense(v_exp);

  -- A second, unposted expense: setting the link for the first time is
  -- what posting is, and this migration must not have touched it.
  insert into public.expenses
    (org_id, expense_no, expense_date, description, amount, tax_amount,
     total_amount, currency, exchange_rate, account_id)
  values (v_org, 'EXP-2', current_date, 'Tol', 20, 0, 20, 'MYR', 1,
          v_cat) returning id into v_rcp;

  -- A journal belonging to something else, so the "pointed at a
  -- different one" probe below is refused by the rule rather than by a
  -- foreign key. Mutation testing caught that: with the rule switched
  -- off, an all-zeros id died on `expenses_gl_entry_id_fkey` and the
  -- assertion passed while proving nothing. `0399` made the same
  -- mistake and left the same note.
  insert into public.expenses
    (org_id, expense_no, expense_date, description, amount, tax_amount,
     total_amount, currency, exchange_rate, account_id)
  values (v_org, 'EXP-OTHER', current_date, 'Parkir', 5, 0, 5, 'MYR', 1,
          v_cat) returning id into v_other;
  v_other_entry := public.post_expense(v_other);

  v_acct := pg_temp.another_user('sekali@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_acct, 'accountant', 'active');

  insert into t_link values (v_org, v_acct, v_exp, v_entry, v_cat, v_rcp,
                             v_other_entry);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select acct from t_link),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_msg text; v_before bigint; v_second uuid;
begin
  select * into c from t_link;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this member really may post',
    app.can_post(c.org));
  perform pg_temp.check_eq('the expense really is posted',
    (select gl_entry_id from public.expenses where id = c.exp), c.entry);

  v_before := (select count(*) from public.gl_entries where org_id = c.org);

  -- ------------------------------------------------------------------
  -- Clearing it
  -- ------------------------------------------------------------------
  begin
    update public.expenses set gl_entry_id = null where id = c.exp;
    raise exception
      'FAIL: a posted expense was unposted by clearing its own column';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal says what would happen next',
      v_msg like '%carry it twice%');
    perform pg_temp.check_true('and names the journal it is already in',
      v_msg like ('%' || c.entry || '%'));
    raise notice 'ok   the link to the journal cannot be cleared';
  end;

  -- ------------------------------------------------------------------
  -- Pointing it somewhere else
  -- ------------------------------------------------------------------
  -- Clearing it is the obvious move and not the only one: an entry id
  -- belonging to something else would make `post_expense` refuse while
  -- the expense reported a journal that is not its own.
  begin
    update public.expenses set gl_entry_id = c.other_entry
     where id = c.exp;
    raise exception 'FAIL: a posted expense was pointed at another journal';
  exception when sqlstate '42501' then
    raise notice 'ok   nor pointed at a different one';
  end;

  perform pg_temp.check_eq('so it still names the journal it posted as',
    (select gl_entry_id from public.expenses where id = c.exp), c.entry);

  -- And the routine that reads it still refuses, which is the thing the
  -- cleared column was walking around.
  begin
    perform public.post_expense(c.exp);
    raise exception 'FAIL: a posted expense was posted a second time';
  exception when others then
    raise notice 'ok   and the expense cannot be posted a second time';
  end;
  perform pg_temp.check_eq('one expense, one journal',
    (select count(*) from public.gl_entries where org_id = c.org), v_before);

  -- ------------------------------------------------------------------
  -- Setting it for the first time is what posting is
  -- ------------------------------------------------------------------
  -- The positive control. A rule that refused this would have refused
  -- every posting in the schema, and would still have passed every
  -- assertion above.
  v_second := public.post_expense(c.rcp);
  perform pg_temp.check_true('an unposted expense still posts', v_second is not null);
  perform pg_temp.check_eq('and now carries the journal it posted as',
    (select gl_entry_id from public.expenses where id = c.rcp), v_second);
  perform pg_temp.check_eq('which is a second entry, not the first one again',
    (select count(*) from public.gl_entries where org_id = c.org), v_before + 1);

  -- Everything else about a posted row goes on moving. `0402` is what a
  -- full freeze looks like; this migration takes one column.
  update public.expenses set description = 'Petrol, KL to Ipoh',
                             reference = 'RCPT-88'
   where id = c.exp;
  perform pg_temp.check_eq('and the rest of a posted expense is still writable',
    (select reference from public.expenses where id = c.exp), 'RCPT-88');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- Every table that carries the column, not a list of them
-- ---------------------------------------------------------------------
-- The migration builds its triggers from the catalogue for this reason:
-- a rule like this is worth something only if it is everywhere, and a
-- list written today does not cover the table added next year. So the
-- question is asked of the catalogue here too, rather than of the list.
do $$
declare v_missing text; v_n int;
begin
  select count(*), string_agg(c.relname, ', ' order by c.relname)
         filter (where not exists (
           select 1 from pg_trigger t
            where t.tgrelid = c.oid and t.tgname = 'refuse_reposting'))
    into v_n, v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
   where n.nspname = 'public' and c.relkind = 'r'
     and a.attname = 'gl_entry_id' and a.attnum > 0 and not a.attisdropped
     and c.relname <> 'bank_transactions';

  if v_missing is not null then
    raise exception
      'FAIL: % carries gl_entry_id and nothing stops the link being '
      'cleared. `0403` builds its triggers from the catalogue, so a '
      'table here means a table created without one -- add the trigger '
      'in a new migration.', v_missing;
  end if;
  if v_n < 15 then
    raise exception
      'FAIL: only % tables carry gl_entry_id, which is not the schema '
      'this file was written against', v_n;
  end if;
  raise notice
    'ok   all % tables that record a posting have the link frozen', v_n;
end $$;

-- ---------------------------------------------------------------------
-- And the one that is deliberately not covered
-- ---------------------------------------------------------------------
-- On `bank_transactions` the column means "which journal this statement
-- line was matched to", not "the journal I posted as", and
-- `unmatch_bank_transaction` clears it as an ordinary correction. The
-- exclusion is asserted so it stays a decision rather than an accident,
-- and it is asserted by unmatching rather than by reading the trigger
-- list -- a list of trigger names measures the list.
do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user();
  v_bank uuid; v_txn uuid; v_entry uuid; v_cat uuid; v_exp uuid;
begin
  v_org := pg_temp.test_org('Padanan Bank Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  select id into v_cat from public.accounts
   where org_id = v_org and not is_group and is_active
     and account_type = 'expense' order by code limit 1;
  insert into public.expenses
    (org_id, expense_no, expense_date, description, amount, tax_amount,
     total_amount, currency, exchange_rate, account_id)
  values (v_org, 'EXP-B', current_date, 'Yuran', 50, 0, 50, 'MYR', 1, v_cat)
  returning id into v_exp;
  v_entry := public.post_expense(v_exp);

  select id into v_bank from public.bank_accounts where org_id = v_org limit 1;
  if v_bank is null then
    insert into public.bank_accounts
      (org_id, account_id, name, bank_name, account_number, account_type,
       currency)
    values (v_org,
            (select id from public.accounts where org_id = v_org
              and not is_group and is_active and account_type = 'asset'
             order by code limit 1),
            'Maybank Semasa', 'Maybank', '512345678901', 'current', 'MYR')
    returning id into v_bank;
  end if;

  insert into public.bank_transactions
    (org_id, bank_account_id, transaction_date, description, amount,
     transaction_type, gl_entry_id)
  values (v_org, v_bank, current_date, 'Yuran bank', -50, 'charge', v_entry)
  returning id into v_txn;

  update public.bank_transactions set gl_entry_id = null where id = v_txn;
  perform pg_temp.check_true(
    'a bank line matched to the wrong journal can still be unmatched',
    (select gl_entry_id is null from public.bank_transactions where id = v_txn));
end $$;

rollback;
