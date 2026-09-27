-- =====================================================================
-- iAkauntan :: 0689 a bank account on the chart, and nowhere else
--
-- Reported by GESWANT & CO on 23/09/2026, as "BANK ACCOUNT NOT SHOWING":
--
--   UNDER COLLECTION FROM CUSTOMER DROPLIST FOR BANK ACCOUNT THE ADDED
--   BANK ACCOUNT (SUB ACCOUNT)
--
-- They added a sub-account under Bank in the chart of accounts and went
-- looking for it in the bank dropdown on a customer collection. It was
-- not there.
--
-- ---------------------------------------------------------------------
-- Nothing was broken, which is the problem
--
-- `bankAccounts()` filters on `is_active` and nothing else, and
-- `bankPickerOptions` filters nothing at all -- it lists every row it is
-- handed. So no filter hid it. It was never a bank account.
--
-- A bank account in this product is TWO records: a row in `accounts`,
-- which is where the money sits in the ledger, and a row in
-- `bank_accounts`, which is what a picker lists and what a reconciliation
-- runs against. `upsert_bank_account` creates both, which is why adding
-- one the supported way works.
--
-- Going the other way creates only the first. The chart of accounts is a
-- perfectly ordinary screen with an Add button, a sub-account under
-- 1120 Bank is a perfectly ordinary thing to add, and the result is a
-- ledger account that money can be posted to and a bank dropdown that
-- will never mention it.
--
-- ---------------------------------------------------------------------
-- The fix is not a rule, it is an offer
--
-- The tempting fix is to make the bank picker list chart accounts too,
-- or to create a `bank_accounts` row automatically whenever somebody
-- adds an account under 1120. Both are wrong.
--
-- A `bank_accounts` row carries things a chart account has no idea
-- about: the bank's name, the account number, whether it is a current
-- account or a credit card, whether it is a CLIENT account -- which for
-- a law firm is a statutory distinction and not a label. Inventing one
-- means inventing those, and an account silently created as an ordinary
-- current account in a solicitor's chart is exactly the mistake the
-- Solicitors' Accounts Rules exist to prevent.
--
-- And not every account under the bank heading is a bank account. A
-- cash float, a petty cash tin, an e-wallet: all of them sit there,
-- none of them reconciles against a statement.
--
-- So this function does not decide anything. It answers ONE question --
-- which accounts money can sit in that no bank account points at -- and
-- the screen offers them, with the same form anybody would otherwise
-- have filled in from scratch. `upsert_bank_account` has taken
-- `p_account_id` since `0529` and already refuses an account that is a
-- group or is not bank or cash; nothing new is permitted here.
--
-- ---------------------------------------------------------------------
-- Registered, not active
--
-- The test is whether ANY `bank_accounts` row points at the account,
-- including a deactivated one. An account somebody switched off is
-- registered and switched off, and offering to register it again would
-- make a second bank account against one ledger account -- two pickers'
-- worth of the same money, and a reconciliation that could be run twice.
-- =====================================================================

create or replace function public.unregistered_bank_accounts(
  p_org_id uuid)
returns table (
  account_id      uuid,
  code            text,
  name            text,
  account_subtype app.account_subtype,
  balance         numeric)
language sql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
  select a.id, a.code, a.name, a.account_subtype,
         round(coalesce(a.current_balance, 0), 2)
    from public.accounts a
   where a.org_id = p_org_id
     -- Only somebody who may post the books. Registering one is a
     -- change to how money is recorded, and `upsert_bank_account`
     -- refuses anybody else anyway -- so offering the list to a reader
     -- would be offering a button that cannot be pressed.
     and app.can_post(p_org_id)
     and a.deleted_at is null
     -- Money can sit in it. A group heading cannot hold a balance and
     -- `upsert_bank_account` refuses one anyway.
     and not a.is_group
     and a.account_subtype in ('bank', 'cash')
     -- And nothing already points at it, active or not.
     and not exists (
       select 1 from public.bank_accounts b where b.account_id = a.id)
   order by a.code;
$$;

comment on function public.unregistered_bank_accounts(uuid) is
  'Chart accounts money can sit in that no bank account points at -- '
  'the ones somebody added under Bank on the chart and then went '
  'looking for in a bank dropdown. Answers the question; decides '
  'nothing. Registering one is `upsert_bank_account` with its '
  '`p_account_id`, which has accepted an existing account since 0529. '
  'A deactivated bank account still counts as registered, because '
  'offering it again would make a second bank account against one '
  'ledger account. 0689.';

revoke all on function public.unregistered_bank_accounts(uuid)
  from public, anon;
grant execute on function public.unregistered_bank_accounts(uuid)
  to authenticated;
