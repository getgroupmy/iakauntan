-- =====================================================================
-- iAkauntan :: a bank account on the chart, and nowhere else
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/unregistered_bank_accounts.sql
--
-- `0689`, from a report: a firm added a sub-account under Bank on the
-- chart of accounts and went looking for it in the bank dropdown on a
-- customer collection. It was not there, and nothing was broken -- a
-- bank account in this product is TWO records, and the chart screen
-- makes one of them.
--
-- What has to be true of the list that offers them:
--
--   * IT FINDS THE ONE THAT WAS ADDED. The whole report.
--   * IT DOES NOT OFFER ONE THAT IS ALREADY REGISTERED, including a
--     bank account somebody SWITCHED OFF. That is the assertion worth
--     having: registering it a second time makes two bank accounts
--     against one ledger account -- the same money in two pickers, and
--     a reconciliation that can be run twice.
--   * IT DOES NOT OFFER WHAT MONEY CANNOT SIT IN. A group heading, a
--     receivables control, and -- since `0730` -- the 1120 bank
--     heading, which is the one the group test misses because it is
--     seeded `is_group = false`. `upsert_bank_account` and the trigger
--     refuse those, so offering them is offering a refusal.
--   * AND IT ANSWERS NOBODY WHO COULD NOT ACT ON IT.
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
  v_sub   uuid;
  v_cash  uuid;
  v_group uuid;
  v_recv  uuid;
  v_bank  uuid;
  v_n     integer;
  v_row   record;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Geswant & Co Sdn Bhd');

  -- The sub-account the report is about: added on the chart, under the
  -- bank heading, and pointed at by nothing.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group)
  values (v_org, '1131', 'Maybank Client Account', 'asset', 'bank', false)
  returning id into v_sub;

  select count(*) into v_n
    from public.unregistered_bank_accounts(v_org)
   where account_id = v_sub;
  perform pg_temp.check_eq(
    'the sub-account somebody added on the chart is offered', v_n, 1);

  select * into v_row from public.unregistered_bank_accounts(v_org)
   where account_id = v_sub;
  perform pg_temp.check_true(
    'named by code and name, which is how somebody recognises it',
    v_row.code = '1131' and v_row.name = 'Maybank Client Account');

  -- A cash account is offered too: a petty cash tin is money that sits
  -- somewhere, and `upsert_bank_account` accepts `cash`.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group)
  values (v_org, '1132', 'Petty cash', 'asset', 'cash', false)
  returning id into v_cash;
  perform pg_temp.check_true(
    'and so is a cash account, which is what upsert accepts',
    exists (select 1 from public.unregistered_bank_accounts(v_org)
             where account_id = v_cash));

  -- -------------------------------------------------------------------
  -- What money cannot sit in
  -- -------------------------------------------------------------------
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group)
  values (v_org, '1133', 'Bank accounts', 'asset', 'bank', true)
  returning id into v_group;
  perform pg_temp.check_true(
    'a group heading is not offered; upsert refuses one',
    not exists (select 1 from public.unregistered_bank_accounts(v_org)
                 where account_id = v_group));

  -- And the 1120 heading, which is the case the group test MISSES: it
  -- is seeded `is_group = false` with subtype `bank`, so it satisfies
  -- every condition above and was offered in any company that had not
  -- registered it. `0730` refuses a bank account on it, so offering it
  -- would be offering a refusal -- which is this list's whole reason
  -- for excluding the other two.
  perform pg_temp.check_true(
    'nor the bank heading, which is not a group and is still a heading',
    not exists (select 1 from public.unregistered_bank_accounts(v_org)
                 where code = '1120'));

  -- The control for all three. A list that offered nothing would
  -- satisfy every assertion above, and the report this function exists
  -- for was that the account somebody added was NOT in it.
  perform pg_temp.check_true(
    'and the account that was added is still offered',
    exists (select 1 from public.unregistered_bank_accounts(v_org)
             where account_id = v_sub));

  select id into v_recv from public.accounts
   where org_id = v_org and account_subtype = 'accounts_receivable' limit 1;
  if v_recv is not null then
    perform pg_temp.check_true(
      'and neither is the receivables control',
      not exists (select 1 from public.unregistered_bank_accounts(v_org)
                   where account_id = v_recv));
  end if;

  -- -------------------------------------------------------------------
  -- Registered is registered, switched off or not
  --
  -- THE ASSERTION THAT MATTERS. Testing `is_active` here instead of
  -- existence would offer a deactivated account back, and registering
  -- it again puts two bank accounts against one ledger account.
  -- -------------------------------------------------------------------
  v_bank := public.upsert_bank_account(
    p_name => 'Maybank Client Account',
    p_bank_name => 'Maybank',
    p_account_number => '514011223344',
    p_account_id => v_sub,
    p_org_id => v_org);

  perform pg_temp.check_true(
    'once registered it stops being offered',
    not exists (select 1 from public.unregistered_bank_accounts(v_org)
                 where account_id = v_sub));

  update public.bank_accounts set is_active = false where id = v_bank;
  perform pg_temp.check_true(
    'and a bank account that was switched OFF is still registered',
    not exists (select 1 from public.unregistered_bank_accounts(v_org)
                 where account_id = v_sub));

  -- -------------------------------------------------------------------
  -- One company's chart
  -- -------------------------------------------------------------------
  perform pg_temp.allow_many_companies();
  declare v_other uuid;
  begin
    v_other := pg_temp.test_org('Somebody Else Sdn Bhd');
    perform pg_temp.check_true(
      'and another company''s accounts are not on this list',
      not exists (select 1 from public.unregistered_bank_accounts(v_other)
                   where account_id = v_cash));
  end;
end $$;

-- ---------------------------------------------------------------------
-- Nobody who could not act on it
-- ---------------------------------------------------------------------
do $$
declare
  v_other uuid := pg_temp.another_user('reader@example.com');
  v_org   uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Read Only Sdn Bhd');
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group)
  values (v_org, '1141', 'A bank account', 'asset', 'bank', false);

  perform pg_temp.sign_in_as(v_other);
  select count(*) into v_n from public.unregistered_bank_accounts(v_org);
  perform pg_temp.check_eq(
    'somebody who may not post the books is offered nothing', v_n, 0);
end $$;

rollback;
