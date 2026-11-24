-- =====================================================================
-- iAkauntan :: 0926 every account fits where it is used
--
-- `0912` refuses a heading, a bank, a till, a receivable or a payable
-- where a contact, an item or a document line names an account. Ten
-- other columns name the account a posting goes to, and asked nothing:
-- an expense's account and each line of its split, a claim type's
-- expense account, a payment method's charge account, a fixed asset's
-- three accounts, a stock adjustment's account, and a landed cost
-- charge's account.
--
-- Measured on 23 and 24 November 2026, locally, as the owner with the
-- role `authenticated`:
--
--   * an expense coded to receivables: posted 1210 100 / 1121 -100 --
--     a receivable with no customer behind it;
--   * an expense coded to the bank it was paid from: 1121 100 and
--     1121 -100, an expense that never reached the profit and loss;
--   * a fixed asset depreciating to the bank: the month's run raised
--     the bank by 40;
--   * a claim type on receivables, a payment method charging the bank,
--     a fixed asset on receivables with a heading for its accumulated
--     depreciation, a stock adjustment on receivables: each accepted;
--   * a landed cost run, each with one charge of 50, credited whatever
--     its charge named -- the bank, receivables, payables, an account
--     closed beforehand with `retire_account`, and 1310 itself. The
--     last posted 1310 50 and 1310 -50 while the stock moved: stock at
--     1,300 against 1,250 in the ledger.
--
-- `upsert_landed_cost_run` asks only that a charge's account is the
-- company's and not a heading. The others ask nothing.
--
-- Production on 24 November: one expense, on an operating expense
-- account; seven fixed assets, each on a fixed asset, an accumulated
-- depreciation and a depreciation expense account; no landed cost
-- charge at all; nothing of these kinds on a wrong kind of account.
--
-- Answered "every remaining door", for every writer:
--
--   * `0912`'s rule on all ten: not a heading, a bank, a till, a
--     receivable or a payable. Its own function, its own words;
--   * a landed cost charge also takes no closed account -- `0923`'s
--     trigger, which it was missed by -- and neither a charge nor a
--     stock adjustment may be the company's 1310. Both post the stock
--     to 1310 and take the other side from this account; `0915` keeps
--     every item's stock in 1310, so 1310 on the other side cancels the
--     posting to nothing while the stock itself moves. 1320 Goods in
--     Transit is still a charge's account: freight held there and
--     brought onto the stock is what a landed cost run is for.
--
-- The stock adjustment was put to the question as a refusal at
-- posting. With every item's stock in 1310 by `0915`, the account its
-- lines move is always 1310, so it is refused when it is written
-- instead, where the person who chose it is still looking at it; no
-- adjustment in production names an account to be caught at posting.
--
-- Asked when the account is set or changed, as `0912` and `0923` are:
-- a row that already names one is still saved whole.
--
-- Not in this: closing an account a draft landed cost run names
-- (`retire_account` does not ask, `0922`), and a run already drafted
-- before its charge's account closed, which `post_landed_cost_run`
-- would still credit.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0912's rule on the ten
-- ---------------------------------------------------------------------
create trigger an_account_fits_where_it_is_used
  before insert or update of account_id on public.expenses
  for each row execute function app.an_account_fits_where_it_is_used(
    'account_id:posting:An expense''s account');

create trigger an_account_fits_where_it_is_used
  before insert or update of account_id on public.expense_lines
  for each row execute function app.an_account_fits_where_it_is_used(
    'account_id:posting:A line of an expense''s split');

create trigger an_account_fits_where_it_is_used
  before insert or update of expense_account_id on public.claim_types
  for each row execute function app.an_account_fits_where_it_is_used(
    'expense_account_id:posting:A claim type''s expense account');

create trigger an_account_fits_where_it_is_used
  before insert or update of charge_account_id on public.payment_methods
  for each row execute function app.an_account_fits_where_it_is_used(
    'charge_account_id:posting:A payment method''s charge account');

create trigger an_account_fits_where_it_is_used
  before insert or update of asset_account_id, accumulated_account_id, expense_account_id
  on public.fixed_assets
  for each row execute function app.an_account_fits_where_it_is_used(
    'asset_account_id:posting:A fixed asset''s asset account',
    'accumulated_account_id:posting:A fixed asset''s accumulated depreciation account',
    'expense_account_id:posting:A fixed asset''s depreciation expense account');

create trigger an_account_fits_where_it_is_used
  before insert or update of account_id on public.stock_adjustments
  for each row execute function app.an_account_fits_where_it_is_used(
    'account_id:posting:A stock adjustment''s account');

create trigger an_account_fits_where_it_is_used
  before insert or update of account_id on public.landed_cost_charges
  for each row execute function app.an_account_fits_where_it_is_used(
    'account_id:posting:A landed cost charge''s account');

-- ---------------------------------------------------------------------
-- 0923's rule on the one it missed
-- ---------------------------------------------------------------------
create trigger a_closed_account_takes_no_new_name
  before insert or update of account_id on public.landed_cost_charges
  for each row execute function app.a_closed_account_takes_no_new_name(
    'account_id:A landed cost charge''s account');

-- ---------------------------------------------------------------------
-- The other side of the stock is not the stock
-- ---------------------------------------------------------------------
create or replace function app.the_stock_is_not_its_own_other_side()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_arg   text;
  v_col   text;
  v_label text;
  v_id    uuid;
  v_acct  public.accounts;
  v_new   jsonb := to_jsonb(new);
  v_old   jsonb;
begin
  -- SECURITY DEFINER because it reads the account, and a writer who may
  -- not read the chart must not be waved through by reading nothing.
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
  end if;

  -- Each argument is `column:what it is called`.
  foreach v_arg in array tg_argv loop
    v_col   := split_part(v_arg, ':', 1);
    v_label := split_part(v_arg, ':', 2);
    v_id    := (v_new ->> v_col)::uuid;
    continue when v_id is null;
    continue when tg_op = 'UPDATE'
                  and (v_new -> v_col) is not distinct from (v_old -> v_col);

    -- The company's own stock account, as the posting finds it: by its
    -- number. Another company's account is the tenant key's.
    select * into v_acct
      from public.accounts a
     where a.id = v_id and a.org_id = new.org_id
       and a.code = '1310' and not a.is_group;
    continue when v_acct.id is null;

    raise exception
      '% may not be % %, the account the stock is kept in: the stock is '
      'posted there and this account takes the other side, so the two '
      'would cancel and the stock would move with nothing in the ledger '
      'to show it. Choose the account the difference belongs to.',
      v_label, v_acct.code, v_acct.name
      using errcode = '23514';
  end loop;
  return new;
end;
$$;

revoke all on function app.the_stock_is_not_its_own_other_side() from public, anon, authenticated;

comment on function app.the_stock_is_not_its_own_other_side() is
  'Refuses, for every writer, the company''s 1310 where a column named '
  'in its arguments is set or changed: a stock adjustment and a landed '
  'cost run post the stock to 1310 and take the other side from that '
  'column. 0926.';

create trigger the_stock_is_not_its_own_other_side
  before insert or update of account_id on public.stock_adjustments
  for each row execute function app.the_stock_is_not_its_own_other_side(
    'account_id:A stock adjustment''s account');

create trigger the_stock_is_not_its_own_other_side
  before insert or update of account_id on public.landed_cost_charges
  for each row execute function app.the_stock_is_not_its_own_other_side(
    'account_id:A landed cost charge''s account');
