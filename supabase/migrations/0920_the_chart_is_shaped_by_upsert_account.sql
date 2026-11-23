-- =====================================================================
-- iAkauntan :: 0920 the chart is shaped by upsert_account
--
-- `upsert_account` is what the chart screen calls, and it holds the
-- chart's rules: an account the ledger finds by number keeps its
-- number, one with postings keeps its kind and does not become a
-- heading, a heading with accounts under it stays one, a kind and its
-- subtype agree, a parent is a heading of the same company. `0459`'s
-- policies let anybody who may post insert an account and update any
-- column of one, so every rule could be stepped round by the person it
-- was written for. `0829` closed that door for closing an account;
-- this is the rest of it.
--
-- Measured on 23 November 2026, locally, as the owner with the role
-- `authenticated`, each beside `upsert_account` refusing the same:
--
--   * one update renumbered 4100 Sales to 4199;
--   * one turned 4150, holding RM100 of revenue, into a liability: the
--     profit and loss then showed nothing, the balance sheet a
--     liability of RM100;
--   * one made it a heading, and it left the trial balance;
--   * one gave Rental, an expense, the subtype `sales`;
--   * one filed Rental under 4100, which is not a heading, and one
--     under itself; one made the heading 4000 postable with its
--     accounts still under it;
--   * a direct insert opened an asset with the subtype `sales`, an
--     account under one that is not a heading, and one with no number.
--
-- The app writes only `tax_treatment` to the row itself. Production on
-- 23 November: 1,566 accounts in eighteen companies; no heading with
-- postings, no kind at odds with its subtype, no account its own
-- parent or without a number.
--
-- Answered "refuse the direct write". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon` -- that inserts an
-- account, or that changes one's number, kind, subtype, heading flag
-- or parent. Its name, description and tax treatment are written as
-- before, and a row saved whole with those five sent back unchanged is
-- still written. The functions run as their owner and pass. NOT
-- security definer.
--
-- Measured and not in this: `is_system`, `currency`, `sort_order` and
-- `tax_code_id` can still be written directly. The balance and the
-- opening balance already have rules of their own (`0844`, `0643`).
-- =====================================================================

create or replace function app.the_chart_is_shaped_by_upsert_account()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_what text[] := '{}';
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    raise exception
      'An account is opened with upsert_account, which checks its number, '
      'its kind and where it is filed -- not by a direct write.'
      using errcode = '42501';
  end if;

  if new.code is distinct from old.code then
    v_what := v_what || 'its number'::text;
  end if;
  if new.account_type is distinct from old.account_type then
    v_what := v_what || 'what kind of account it is'::text;
  end if;
  if new.account_subtype is distinct from old.account_subtype then
    v_what := v_what || 'its subtype'::text;
  end if;
  if new.is_group is distinct from old.is_group then
    v_what := v_what || 'whether it is a heading'::text;
  end if;
  if new.parent_id is distinct from old.parent_id then
    v_what := v_what || 'what it is filed under'::text;
  end if;

  if cardinality(v_what) > 0 then
    raise exception
      'Account %: a direct write does not change %. upsert_account does, '
      'and checks what the change does to the books.',
      old.code, array_to_string(v_what, ' or ')
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.the_chart_is_shaped_by_upsert_account() from public, anon, authenticated;

comment on function app.the_chart_is_shaped_by_upsert_account() is
  'On accounts: refuses a client''s own statement that inserts an '
  'account or changes one''s code, account_type, account_subtype, '
  'is_group or parent_id. upsert_account, add_sub_account and the '
  'other functions run as their owner and pass. 0920.';

create trigger the_chart_is_shaped_by_upsert_account
  before insert or update of code, account_type, account_subtype, is_group, parent_id
  on public.accounts
  for each row execute function app.the_chart_is_shaped_by_upsert_account();
