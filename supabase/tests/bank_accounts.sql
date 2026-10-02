-- =====================================================================
-- iAkauntan :: a bank account you can actually add
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_accounts.sql
--
-- 0529. `upsert_bank_account` writes TWO rows that must not disagree:
-- the `bank_accounts` row a screen picks from, and the GL account the
-- ledger posts to. What is asserted here is the pairing, the numbering
-- that picks the GL account's code, and every refusal -- each paired
-- with the write that must still succeed, because N REFUSALS ARE
-- SATISFIED BY A FUNCTION THAT REFUSES EVERYTHING.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_me      uuid := pg_temp.test_user();
  v_org     uuid;
  v_first   uuid;
  v_second  uuid;
  v_gl      uuid;
  v_gl2     uuid;
  v_ar      uuid;
  v_head    uuid;
  v_twelve  uuid;
  v_ok      boolean;
  v_txt     text;
  v_n       integer;
begin
  v_org := pg_temp.test_org('Kedai Bank Sdn Bhd');
  perform pg_temp.sign_in_as(v_me);

  -- The bootstrap chart is what a real company starts from, so the
  -- numbering is asserted against it rather than against a fixture.
  perform pg_temp.check_eq('1120 is the seeded bank heading',
    (select count(*)::numeric from public.accounts
      where org_id = v_org and code = '1120'), 1);

  -- ---------------------------------------------------------------
  -- The first one
  -- ---------------------------------------------------------------
  v_first := public.upsert_bank_account(
    p_name           => 'Maybank Current',
    p_bank_name      => 'Malayan Banking Berhad',
    p_account_number => '514233880011',
    p_org_id         => v_org);

  perform pg_temp.check_eq('it made a bank account',
    (select count(*)::numeric from public.bank_accounts
      where id = v_first and org_id = v_org), 1);

  select account_id into v_gl from public.bank_accounts where id = v_first;

  perform pg_temp.check_eq('with a GL account of its own',
    (select code from public.accounts where id = v_gl), '1121');
  perform pg_temp.check_eq('which is an asset',
    (select account_type::text from public.accounts where id = v_gl),
    'asset');
  perform pg_temp.check_eq('of subtype bank',
    (select account_subtype::text from public.accounts where id = v_gl),
    'bank');
  perform pg_temp.check_true('and it is a postable account, not a heading',
    (select not is_group from public.accounts where id = v_gl));

  -- Under Current Assets, so it appears where a reader looks for it
  -- rather than at the bottom of the balance sheet.
  perform pg_temp.check_eq('filed under Current Assets',
    (select a.code from public.accounts a
      join public.accounts b on b.parent_id = a.id
     where b.id = v_gl), '1100');

  -- The first account a company has is its default, because every
  -- screen that says "leave blank for the default" has to mean
  -- something.
  perform pg_temp.check_true('the first one is the default',
    (select is_default from public.bank_accounts where id = v_first));

  -- ---------------------------------------------------------------
  -- The second one
  -- ---------------------------------------------------------------
  v_second := public.upsert_bank_account(
    p_name   => 'CIMB Savings',
    p_org_id => v_org);
  select account_id into v_gl2 from public.bank_accounts where id = v_second;

  perform pg_temp.check_eq('the next one takes the next free number',
    (select code from public.accounts where id = v_gl2), '1122');
  perform pg_temp.check_true('and it is a DIFFERENT GL account',
    v_gl2 is distinct from v_gl);
  perform pg_temp.check_true('the second one is not the default',
    (select not is_default from public.bank_accounts where id = v_second));

  -- A number already taken is skipped rather than collided with.
  select id into v_head from public.accounts
   where org_id = v_org and code = '1100';
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, parent_id, is_group)
  values (v_org, '1123', 'Taken by hand', 'asset', 'bank', v_head, false);

  v_second := public.upsert_bank_account(
    p_name => 'Public Bank', p_org_id => v_org);
  perform pg_temp.check_eq('a number already on the chart is stepped over',
    (select a.code from public.accounts a
      join public.bank_accounts b on b.account_id = a.id
     where b.id = v_second), '1124');

  -- ---------------------------------------------------------------
  -- Pointing at an account that already exists
  -- ---------------------------------------------------------------
  --
  -- A caller MAY name a ledger account rather than have one made --
  -- that is what `p_account_id` is for -- and until `0730` it could
  -- name the heading. This block asserted that it could, by name:
  --
  --     check_eq('a caller may name the GL account itself', ..., '1120')
  --
  -- It was true, it was the product's own route to the twelve
  -- companies whose bank account points at 1120, and the assertion
  -- pinned it. `upsert_bank_account`'s own guard let it through because
  -- 1120 is seeded `is_group = false` with subtype `bank`, which is
  -- exactly what that guard asks for.
  --
  -- So: the account it may name is one of its own children.
  v_second := public.upsert_bank_account(
    p_name       => 'Shares an account made by hand',
    p_account_id => (select id from public.accounts
                      where org_id = v_org and code = '1123'),
    p_org_id     => v_org);
  perform pg_temp.check_eq('a caller may name a ledger account of its own',
    (select a.code from public.accounts a
      join public.bank_accounts b on b.account_id = a.id
     where b.id = v_second), '1123');

  -- ---------------------------------------------------------------
  -- And may not name the heading -- 0730
  -- ---------------------------------------------------------------
  perform pg_temp.check_refused(
    'the bank heading itself is refused',
    format($q$ select public.upsert_bank_account(
                 p_name => 'On the heading', p_account_id => %L,
                 p_org_id => %L) $q$,
           (select id from public.accounts
             where org_id = v_org and code = '1120'), v_org),
    '%hang beneath%');

  -- Through the front door AND through the table, because the rule is a
  -- trigger: a guard in the function would leave every other writer --
  -- an import, a seeder, a migration, a hand-written insert in a test
  -- -- free to do it, and four of those had.
  perform pg_temp.check_refused(
    'and refused to a direct insert as well',
    format($q$ insert into public.bank_accounts (org_id, account_id, name)
               values (%L, (select id from public.accounts
                             where org_id = %L and code = '1120'),
                       'Straight at the table') $q$, v_org, v_org),
    '%hang beneath%');

  -- A real heading, which is the general form of the same rule. 1100
  -- "Cash and Bank" is `is_group`, and a fixture in
  -- `client_money_crossing.sql` had a law firm's office account on it.
  perform pg_temp.check_refused(
    'a group account is refused too, with the reason it is wrong',
    format($q$ insert into public.bank_accounts (org_id, account_id, name)
               values (%L, (select id from public.accounts
                             where org_id = %L and code = '1100'),
                       'On the group') $q$, v_org, v_org),
    '%is a heading%');

  -- The control: the refusals above are not a trigger that refuses
  -- everything. `v_second` was just made on 1123 and is still there.
  perform pg_temp.check_eq('and an account of its own still goes in',
    (select count(*)::numeric from public.bank_accounts
      where id = v_second), 1);

  -- And the twelve. A row ALREADY on the heading must keep working:
  -- `current_balance` is written by every posting function, and a
  -- trigger that refused those updates would stop a reconciliation to
  -- make a point about a column nobody is changing. Made here the only
  -- way left -- the trigger disabled for one statement -- because the
  -- product can no longer produce one.
  alter table public.bank_accounts disable trigger
    bank_account_not_the_heading;
  insert into public.bank_accounts (org_id, account_id, name,
    current_balance, is_default)
  values (v_org, (select id from public.accounts
                   where org_id = v_org and code = '1120'),
          'One of the twelve', 0, false)
  returning id into v_twelve;
  alter table public.bank_accounts enable trigger
    bank_account_not_the_heading;

  update public.bank_accounts set current_balance = 9000 where id = v_twelve;
  perform pg_temp.check_eq('a row already on the heading can still be banked',
    (select current_balance from public.bank_accounts where id = v_twelve),
    9000.00);
  update public.bank_accounts set name = 'Renamed in place' where id = v_twelve;
  perform pg_temp.check_eq('and renamed',
    (select name from public.bank_accounts where id = v_twelve),
    'Renamed in place');

  -- What it cannot do is move to the heading, which is the other half
  -- of the door: an existing account repointed at 1120 would arrive at
  -- the same place as a new one.
  perform pg_temp.check_refused(
    'but an existing account cannot be repointed at the heading',
    format($q$ update public.bank_accounts
                  set account_id = (select id from public.accounts
                                     where org_id = %L and code = '1120')
                where id = %L $q$, v_org, v_first),
    '%hang beneath%');

  -- ---------------------------------------------------------------
  -- What it refuses
  -- ---------------------------------------------------------------
  select id into v_ar from public.accounts
   where org_id = v_org and code = '1210';   -- Accounts Receivable

  -- Each of these names the refusal it expects, rather than catching
  -- anything at all. `upsert_bank_account` has six guards in a row: a
  -- test that only asks WHETHER it refused passes when the guard it is
  -- aimed at is deleted and a later one fires instead -- and passes
  -- again when the call itself has a typo in it.
  perform pg_temp.check_refused(
    'money cannot be banked into the receivables control',
    format($q$ select public.upsert_bank_account(
                 p_name => 'Wrong', p_account_id => %L, p_org_id => %L) $q$,
           v_ar, v_org),
    '%not a bank or cash account%');

  perform pg_temp.check_refused('a blank name is refused',
    format($q$ select public.upsert_bank_account(
                 p_name => '   ', p_org_id => %L) $q$, v_org),
    '%needs a name%');

  perform pg_temp.check_refused(
    'a currency that is not three letters is refused',
    format($q$ select public.upsert_bank_account(
                 p_name => 'Bad currency', p_currency => 'RINGGIT',
                 p_org_id => %L) $q$, v_org),
    '%three letters%');

  perform pg_temp.check_refused(
    'an account belonging to no company is refused',
    $q$ select public.upsert_bank_account(p_name => 'Nowhere') $q$,
    '%Which company%');

  -- The control for all four: the same call with everything right still
  -- works, so the refusals above are not a function that refuses
  -- everything.
  perform pg_temp.check_true('and a good one still goes through',
    public.upsert_bank_account(
      p_name => 'Still fine', p_currency => 'usd', p_org_id => v_org)
    is not null);
  perform pg_temp.check_eq('with the currency upper-cased',
    (select currency::text from public.bank_accounts
      where org_id = v_org and name = 'Still fine'), 'USD');

  -- ---------------------------------------------------------------
  -- Amending one
  -- ---------------------------------------------------------------
  select count(*) into v_n from public.accounts
   where org_id = v_org and code between '1121' and '1199';

  perform public.upsert_bank_account(
    p_id             => v_first,
    p_name           => 'Maybank Current Account',
    p_bank_name      => 'Malayan Banking Berhad',
    p_account_number => '514233880011');

  perform pg_temp.check_eq('an amendment renames it',
    (select name from public.bank_accounts where id = v_first),
    'Maybank Current Account');
  perform pg_temp.check_true(
    'and leaves the GL account behind it exactly where it was',
    (select account_id from public.bank_accounts where id = v_first) = v_gl);

  -- Amending is not creating. The count is taken before and after
  -- rather than pinned to a number, because the bootstrap chart already
  -- has 1130 Petty Cash inside the range and a literal here would be
  -- asserting the seed rather than the function.
  perform pg_temp.check_eq('amending made no new account in the bank range',
    (select count(*)::numeric from public.accounts
      where org_id = v_org and code between '1121' and '1199'),
    v_n::numeric);

  -- ---------------------------------------------------------------
  -- Somebody else's company
  -- ---------------------------------------------------------------
  begin
    perform public.upsert_bank_account(
      p_name   => 'Not mine',
      p_org_id => (select id from public.organizations
                    where id <> v_org
                      and not exists (select 1 from public.org_members m
                                       where m.org_id = organizations.id
                                         and m.user_id = v_me)
                    limit 1));
    v_ok := true;
  exception when others then v_ok := false;
  end;
  -- Null org (no such company in the fixture) and a refusal both land
  -- here; either way nothing was written for anybody else.
  perform pg_temp.check_true(
    'a company I am not a member of gets nothing', not v_ok);

  raise notice 'bank_accounts.sql: all assertions passed';
end $$;

rollback;
