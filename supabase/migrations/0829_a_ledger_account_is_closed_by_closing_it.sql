-- =====================================================================
-- iAkauntan :: 0829 a ledger account is closed by closing it
--
-- `retire_account` closes a ledger account: it refuses a posting code,
-- one with open accounts under it, and (`0828`) one that still carries
-- a balance or that an active bank account posts to, and it writes the
-- closure the platform console reopens it from. `0619` took out the
-- outright delete -- "nothing in this product deletes an account any
-- more". The chart screen closes one through it and writes only
-- `tax_treatment` on the row itself. But `0459`'s policies let anybody
-- who may post update any column of an account, and delete one.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: `retire_account` refused to close 1210 Accounts
-- Receivable -- "one the ledger posts to by number" -- and a direct
-- update closed it. An RM100 invoice then posted to the closed account,
-- and the trial balance came out RM100 short of debits. And 1210,
-- before anything had posted to it, could be deleted outright; the next
-- invoice then failed to post at all.
--
-- Answered "reports and refuse", the client's door half of it (`0828`
-- is the other). A trigger refuses a client's own statement -- role
-- `authenticated` or `anon`, at the top trigger depth -- that closes or
-- reopens an account (`deleted_at`, `is_active`), or that makes one
-- already closed. Delete is revoked from clients and its policy
-- dropped. The functions run as their owner and pass. NOT security
-- definer. Everything else on the row is as before.
--
-- Production held 1,566 accounts across eighteen companies on 12
-- October, three of them closed, every one through `retire_account`.
-- =====================================================================

revoke delete on public.accounts from authenticated, anon;
drop policy if exists accounts_delete on public.accounts;

create or replace function app.a_ledger_account_is_closed_by_closing_it()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.deleted_at is not null or not new.is_active then
      raise exception
        'A new account is open. One is closed with retire_account, which '
        'checks what it holds and keeps a record of it.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.deleted_at is distinct from old.deleted_at
     or new.is_active is distinct from old.is_active then
    raise exception
      'Account % is closed with retire_account, which checks what it '
      'holds and keeps a record of it, and reopened from the platform '
      'console -- not by hand.', old.code
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.a_ledger_account_is_closed_by_closing_it() from public, anon, authenticated;

comment on function app.a_ledger_account_is_closed_by_closing_it() is
  'On accounts: refuses a client''s own statement that closes or '
  'reopens an account (deleted_at, is_active) or makes one already '
  'closed. retire_account, the console and the posting helpers that '
  'revive an account pass. 0829.';

create trigger a_ledger_account_is_closed_by_closing_it
  before insert or update on public.accounts
  for each row execute function app.a_ledger_account_is_closed_by_closing_it();
