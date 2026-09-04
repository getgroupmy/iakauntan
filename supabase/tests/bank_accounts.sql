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
  v_second := public.upsert_bank_account(
    p_name       => 'Shares the heading',
    p_account_id => (select id from public.accounts
                      where org_id = v_org and code = '1120'),
    p_org_id     => v_org);
  perform pg_temp.check_eq('a caller may name the GL account itself',
    (select a.code from public.accounts a
      join public.bank_accounts b on b.account_id = a.id
     where b.id = v_second), '1120');

  -- ---------------------------------------------------------------
  -- What it refuses
  -- ---------------------------------------------------------------
  select id into v_ar from public.accounts
   where org_id = v_org and code = '1210';   -- Accounts Receivable

  begin
    perform public.upsert_bank_account(
      p_name => 'Wrong', p_account_id => v_ar, p_org_id => v_org);
    v_ok := true;
  exception when others then
    v_ok := false; v_txt := sqlerrm;
  end;
  perform pg_temp.check_true(
    'money cannot be banked into the receivables control', not v_ok);
  perform pg_temp.check_true('and it says why',
    v_txt like '%not a bank or cash account%');

  begin
    perform public.upsert_bank_account(p_name => '   ', p_org_id => v_org);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  perform pg_temp.check_true('a blank name is refused', not v_ok);

  begin
    perform public.upsert_bank_account(
      p_name => 'Bad currency', p_currency => 'RINGGIT', p_org_id => v_org);
    v_ok := true;
  exception when others then v_ok := false;
  end;
  perform pg_temp.check_true('a currency that is not three letters is refused',
    not v_ok);

  begin
    perform public.upsert_bank_account(p_name => 'Nowhere');
    v_ok := true;
  exception when others then v_ok := false;
  end;
  perform pg_temp.check_true('an account belonging to no company is refused',
    not v_ok);

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
