-- =====================================================================
-- iAkauntan :: the chart is the company's
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/chart_of_accounts.sql
--
-- The database has allowed a company to change its own chart since the
-- schema was laid down. What 0459 adds is the part that has to be
-- refused, and the refusals are the interesting half:
--
--   * posting resolves accounts **by number**, so a number the ledger
--     names cannot change;
--   * changing what kind of account something is flips its sign in
--     every report ever run against it;
--   * an account with postings is deactivated, never deleted.
--
-- 0619 took the deletion out of the third one entirely: nothing in this
-- product deletes an account any more, posted to or not, because "keep
-- the records and let only the console see them" is not a rule that can
-- hold with one branch that removes the row. So the three assertions
-- that used to read `deleted` now read `closed`, and each is paired
-- with one that the row is still there -- which is the half that would
-- otherwise have been lost with the word.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.coa_org(p_name text)
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

-- ---------------------------------------------------------------------
-- The set that is protected, and how it is arrived at
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*)::integer into v_n from app.posting_account_codes();

  -- Not the whole chart: a protected set that covered every account
  -- would leave the company with an editor that edits nothing. Not a
  -- handful either: fifty-odd posting functions name a code.
  perform pg_temp.check_true(
    'the protected set is a part of the chart, not all of it',
    v_n between 20 and 90);

  perform pg_temp.check_true('the receivables control account is in it',
    exists (select 1 from app.posting_account_codes() where code = '1200'));
  perform pg_temp.check_true('and the payables one',
    exists (select 1 from app.posting_account_codes() where code = '2100'));

  -- Derived from the posting functions rather than declared, so a
  -- posting path added next year protects its own account without
  -- anybody remembering. This is the assertion that says so.
  perform pg_temp.check_true(
    'the set is read out of the posting functions themselves',
    position('regexp_matches' in pg_get_functiondef(
      to_regprocedure('app.posting_account_codes()'))) > 0);
end $$;

-- ---------------------------------------------------------------------
-- Opening an account
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_id  uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.coa_org('Carta Sdn Bhd');

  v_id := public.upsert_account(
    '6350', 'Drone hire', 'expense', 'operating_expense',
    p_org_id => v_org);
  perform pg_temp.check_true('a company can open an account', v_id is not null);
  perform pg_temp.check_eq('with the name it chose',
    (select name from public.accounts where id = v_id), 'Drone hire');

  -- And it is a real account: the ledger will take a posting to it.
  perform public.post_manual_journal(v_org, date '2026-05-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_id, 'debit', 400, 'credit', 0,
                         'description', 'Survey'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 0, 'credit', 400, 'description', 'Survey')),
    'Drone survey');
  perform pg_temp.check_eq('and the ledger posts to it',
    (select closing_balance from public.report_trial_balance(
       v_org, null, date '2026-12-31') where code = '6350'), 400);

  -- Renaming it is fine. It is not one the ledger looks up by number.
  perform public.upsert_account(
    '6350', 'Aerial survey', 'expense', 'operating_expense', p_id => v_id);
  perform pg_temp.check_eq('an account can be renamed',
    (select name from public.accounts where id = v_id), 'Aerial survey');

  -- Renumbering it is fine too, for the same reason.
  perform public.upsert_account(
    '6355', 'Aerial survey', 'expense', 'operating_expense', p_id => v_id);
  perform pg_temp.check_eq('and renumbered',
    (select code from public.accounts where id = v_id), '6355');

  -- But not made into a different kind of account once it has been
  -- posted to: that flips its sign in every report ever run.
  begin
    perform public.upsert_account(
      '6355', 'Aerial survey', 'revenue', 'other_income', p_id => v_id);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true(
    'an account with postings cannot change what it is', not v_took);

  -- Nor left with no number or no name.
  begin
    perform public.upsert_account('', 'Nameless', 'expense',
      'operating_expense', p_org_id => v_org);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('an account needs a number', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- The numbers the ledger holds
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_id   uuid;
  v_leaf uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.coa_org('Carta Kunci Sdn Bhd');
  v_id  := pg_temp.acct(v_org, '1200');

  -- The receivables control account. Posting finds it by number, so
  -- renumbering it detaches the path silently -- the next invoice posts
  -- its receivable somewhere else or fails at the ledger.
  begin
    perform public.upsert_account(
      '1201', 'Trade receivables', 'asset', 'current_asset', p_id => v_id);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true(
    'an account the ledger posts to by number cannot be renumbered',
    not v_took);

  perform pg_temp.check_eq('so its number is where it was',
    (select code from public.accounts where id = v_id), '1200');

  -- Renaming it is allowed. The name is not what the machinery holds.
  perform public.upsert_account(
    '1200', 'Debtors', 'asset', 'current_asset', p_id => v_id);
  perform pg_temp.check_eq('but it can still be renamed',
    (select name from public.accounts where id = v_id), 'Debtors');

  -- And it cannot be removed at all.
  --
  -- Asked of 1310 rather than 1200: 1200 is a heading with accounts
  -- under it, so retiring it is refused by the *children* guard with
  -- the same SQLSTATE, and the assertion would pass whether the
  -- protection existed or not. A protected leaf is the only account
  -- that tests the protection.
  v_leaf := pg_temp.acct(v_org, '1310');
  perform pg_temp.check_true('1310 is a leaf, so nothing else refuses it',
    not (select is_group from public.accounts where id = v_leaf)
    and not exists (select 1 from public.accounts
                     where parent_id = v_leaf));

  begin
    perform public.retire_account(v_leaf);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('nor removed', not v_took);
  perform pg_temp.check_true('and it is still in the chart',
    exists (select 1 from public.accounts
             where id = v_leaf and deleted_at is null));
end $$;

-- ---------------------------------------------------------------------
-- Taking one out of use
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_fresh uuid;
  v_used  uuid;
  v_head  uuid;
  v_kid   uuid;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.coa_org('Carta Bersara Sdn Bhd');

  -- Never touched: closed, and kept. 0619.
  v_fresh := public.upsert_account(
    '6360', 'Opened by mistake', 'expense', 'operating_expense',
    p_org_id => v_org);
  perform pg_temp.check_eq('an account nothing has touched is closed',
    public.retire_account(v_fresh), 'closed');
  perform pg_temp.check_true('and the row is still there',
    exists (select 1 from public.accounts where id = v_fresh));
  perform pg_temp.check_true('hidden rather than removed',
    (select deleted_at is not null and not is_active
       from public.accounts where id = v_fresh));

  -- Posted to: kept, switched off. Deleting it would take a balance
  -- out of the trial balance, which is how a set of books stops
  -- balancing.
  v_used := public.upsert_account(
    '6370', 'Used once', 'expense', 'operating_expense', p_org_id => v_org);
  perform public.post_manual_journal(v_org, date '2026-05-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_used, 'debit', 90, 'credit', 0,
                         'description', 'A cost'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1120'),
                         'debit', 0, 'credit', 90, 'description', 'A cost')),
    'One cost');

  perform pg_temp.check_eq('an account with history is closed',
    public.retire_account(v_used), 'closed');
  perform pg_temp.check_true('and keeps its postings',
    exists (select 1 from public.gl_lines where account_id = v_used));
  perform pg_temp.check_true('while being switched off',
    not (select is_active from public.accounts where id = v_used));

  -- An account with an opening balance and no postings. Nothing in the
  -- database refuses deleting this one -- `gl_lines` has no row to
  -- restrict on -- so the guard is the only thing standing between a
  -- company and a trial balance that stops balancing.
  declare v_opened uuid;
  begin
    v_opened := public.upsert_account(
      '6375', 'Brought over', 'expense', 'operating_expense',
      p_org_id => v_org);
    update public.accounts set opening_balance = 250 where id = v_opened;

    perform pg_temp.check_eq(
      'an account carrying an opening balance is closed too',
      public.retire_account(v_opened), 'closed');
    perform pg_temp.check_true('and keeps the balance it carried',
      (select opening_balance from public.accounts where id = v_opened) = 250);
  end;

  -- A heading with accounts under it stays until they are dealt with.
  v_head := public.upsert_account(
    '6380', 'A heading', 'expense', 'operating_expense',
    p_is_group => true, p_org_id => v_org);
  v_kid := public.upsert_account(
    '6381', 'Under it', 'expense', 'operating_expense',
    p_parent_id => v_head, p_org_id => v_org);

  begin
    perform public.retire_account(v_head);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true(
    'a heading with accounts under it stays', not v_took);

  perform pg_temp.check_eq('until they are closed',
    public.retire_account(v_kid), 'closed');
  perform pg_temp.check_eq('and then it goes too',
    public.retire_account(v_head), 'closed');
end $$;

-- ---------------------------------------------------------------------
-- Whose chart it is
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_clerk uuid;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.coa_org('Carta Kebenaran Sdn Bhd');

  -- A viewer may read the chart and may not change it.
  v_clerk := pg_temp.another_user('viewer-0459@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_clerk);

  begin
    perform public.upsert_account('6390', 'Theirs', 'expense',
      'operating_expense', p_org_id => v_org);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('a viewer cannot open an account', not v_took);

  begin
    perform public.retire_account(pg_temp.acct(v_org, '6100'));
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('nor retire one', not v_took);

  -- And somebody at another company entirely cannot either.
  perform pg_temp.sign_in_as(pg_temp.another_user('outside-0459@iakauntan.test'));
  begin
    perform public.upsert_account('6395', 'Not theirs', 'expense',
      'operating_expense', p_org_id => v_org);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and an outsider cannot touch another company''s chart', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- 0643: an opening balance is a journal, not a figure on an account
--
-- `accounts.opening_balance` is added into the opening figure of six
-- statutory reports -- trial balance, general ledger, balance sheet,
-- cash flow, changes in equity, group trial balance -- signed by the
-- account's type and read WITHOUT A DATE, whatever period was asked
-- for. `accounts.opening_balance_date` sits on the next line of `0003`
-- and nothing has ever read it.
--
-- Nothing writes the figure either. What made it worth a guard is that
-- ANYBODY COULD: `authenticated` holds UPDATE on the table and the
-- policy asks only `app.can_post`, so a PATCH straight at PostgREST
-- was accepted from whoever may post a journal -- and then the amount
-- is in the opening figure of every period including ones before the
-- company converted, it is in no journal, and the trial balance no
-- longer balances with no entry to point at.
--
-- The proof is here rather than in the migration because it needs an
-- organization, an account and a signed-in caller. `0643` tried to
-- create one and tripped `app.add_creator_as_owner`: there is no
-- `auth.uid()` at migration time. Its own self-check reads the trigger
-- definition instead -- before, both statements, per row.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Imbangan Pembukaan Sdn Bhd');
  v_id   uuid;
  v_took boolean;
  v_said text;
  v_import integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());

  select id into v_id from public.accounts
   where org_id = v_org and code = '1000' and not is_group
   limit 1;
  if v_id is null then
    select id into v_id from public.accounts
     where org_id = v_org and not is_group limit 1;
  end if;
  perform pg_temp.check_true('the company has a chart to edit',
    v_id is not null);

  -- The premise: this caller MAY edit the chart. Without it every
  -- refusal below could be somebody with no permissions at all.
  perform pg_temp.check_true('and this caller may post', app.can_post(v_org));

  -- ------------------------------------------------------------------
  -- The write that used to be accepted
  -- ------------------------------------------------------------------
  begin
    set local role authenticated;
    update public.accounts set opening_balance = 50000 where id = v_id;
    v_took := true;
  exception when insufficient_privilege then
    v_took := false;
    v_said := sqlerrm;
  end;
  reset role;
  perform pg_temp.check_true(
    'an opening balance cannot be written onto an account', not v_took);

  -- And the refusal says where it belongs. A bare "permission denied"
  -- sends somebody looking for a role they already have.
  perform pg_temp.check_true('and says where it belongs instead',
    v_said like '%dated journal%'
      and v_said like '%import_opening_balances%');

  -- The date beside it, which nothing reads and which would be the
  -- half somebody sets while trying to make the figure legitimate.
  begin
    set local role authenticated;
    update public.accounts
       set opening_balance_date = current_date where id = v_id;
    v_took := true;
  exception when insufficient_privilege then
    v_took := false;
  end;
  reset role;
  perform pg_temp.check_true('nor the date beside it', not v_took);

  -- An INSERT carrying the figure, which a guard on updates alone
  -- would miss -- and it is the easier of the two to do by accident,
  -- because a new account is a whole row.
  begin
    set local role authenticated;
    insert into public.accounts
      (org_id, code, name, account_type, account_subtype, opening_balance)
    values (v_org, '1099', 'Kas Pembukaan', 'asset', 'current_asset', 1);
    v_took := true;
  exception when insufficient_privilege then
    v_took := false;
    v_said := sqlerrm;
  end;
  reset role;
  perform pg_temp.check_true(
    'nor an account created with one already on it', not v_took);

  -- The INSERT path's own message, which is a second `raise` in the
  -- guard and was asserted by nothing: a mutant that gutted it
  -- survived while the update path's identical sentence kept the
  -- sweep green. Two messages, two assertions.
  perform pg_temp.check_true('and that refusal says it too',
    v_said like '%dated journal%'
      and v_said like '%import_opening_balances%');

  -- ------------------------------------------------------------------
  -- The controls, and the reason any of the above means anything
  -- ------------------------------------------------------------------
  -- A guard that refused every write would pass all four assertions
  -- and stop the chart of accounts working.
  -- No handler on any of the three: they are expected to SUCCEED, so
  -- a throw should come out as itself rather than as `expected true`.
  -- `check_blind_catches.py` refuses a `when others` for the same
  -- reason -- and caught these three when they were written that way.
  set local role authenticated;
  update public.accounts set name = 'Kas Kecil' where id = v_id;
  reset role;
  perform pg_temp.check_eq('an ordinary edit still goes through',
    (select name from public.accounts where id = v_id), 'Kas Kecil');

  set local role authenticated;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1098', 'Kas Baru', 'asset', 'current_asset');
  reset role;
  perform pg_temp.check_true('and an account can still be created',
    exists (select 1 from public.accounts
             where org_id = v_org and code = '1098'));

  -- Writing the value it already holds is not a change. The guard is
  -- on the CHANGE and not on the column, because the upsert path sends
  -- a whole row -- a guard on the column would refuse every save.
  set local role authenticated;
  update public.accounts set opening_balance = 0 where id = v_id;
  reset role;
  perform pg_temp.check_eq(
    'and a row that sends the same zero back is not a change',
    (select opening_balance from public.accounts where id = v_id), 0);

  -- ------------------------------------------------------------------
  -- And the mechanism that is right still works
  -- ------------------------------------------------------------------
  -- `import_opening_balances` posts a GL entry dated `p_as_at` with
  -- `source = 'opening_balance'`, so the date is on the journal, the
  -- figure is in the ledger, and it balances because it is a double
  -- entry like everything else. The guard must not have closed this.
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- The call gets its own statement, and the assertion reads the
  -- VARIABLE. Written inline inside `check_true(...)` it ran TWICE --
  -- the label printed twice and the import happened twice, because a
  -- volatile function in a plpgsql simple expression can be
  -- re-evaluated when the statement it is posting invalidates a
  -- cached plan. An assertion that silently does its own setup twice
  -- is an assertion about a state nobody wrote down.
  --
  -- `account_code`, not `code`: the first version used the wrong key
  -- and the importer answered "1 of 1 rows have a problem", which is
  -- the right answer and says nothing about the guard.
  -- It returns a TABLE of per-row outcomes, not a scalar, so the
  -- rows are counted rather than assigned.
  select count(*)::int into v_import
    from public.import_opening_balances(
      v_org,
      jsonb_build_array(
        jsonb_build_object('account_code', '1210', 'debit', '500'),
        jsonb_build_object('account_code', '3100', 'credit', '500')),
      date '2026-01-01',
      true)
   where status <> 'error';
  perform pg_temp.check_eq('the dated route is still open', v_import, 2);
  perform pg_temp.check_eq('and it ran once, not twice',
    (select count(*)::int from public.gl_entries
      where org_id = v_org and source = 'opening_balance'), 1);

  perform pg_temp.check_true(
    'and it puts the figure in a dated journal, not on the account',
    exists (select 1 from public.gl_entries e
             where e.org_id = v_org
               and e.source = 'opening_balance'
               and e.entry_date = date '2026-01-01'));
  perform pg_temp.check_eq(
    'leaving the account''s own column at zero',
    (select opening_balance from public.accounts where id = v_id), 0);

  perform pg_temp.sign_out();
end $$;

rollback;
