-- =====================================================================
-- iAkauntan :: 0844 an account's balance is its ledger's
--
-- `accounts.current_balance` is a running total: `app.apply_account_
-- balance`, a trigger on `gl_lines` since `0009`, adds every posted line
-- to it and takes every removed one off. The chart-of-accounts export
-- prints it and `unregistered_bank_accounts` lists it; the statements
-- sum the lines themselves. `0643` took the opening balance beside it
-- off the client surface -- `authenticated` holds insert and update on
-- the table, and the policies ask only `app.can_post` -- and left this
-- one where it was.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: an asset account's balance set to RM1,000,000 by a
-- direct update was accepted, with no line in the ledger behind it, and
-- the export would have printed it. The app writes no balance.
--
-- Answered "guard it with opening_balance": `0643`'s guard is restated
-- with two more refusals -- a client's own statement that changes
-- `current_balance`, and an account inserted with one other than
-- nothing. Both are asked at the top trigger depth only, because
-- `apply_account_balance` is not a definer: when a definer posts, it
-- runs as the owner, but the depth is what holds for every road a line
-- can take. NOT security definer.
--
-- Production held 1,333 accounts on 12 October, 104 with a balance, and
-- none disagreeing with the lines posted to it.
-- =====================================================================

create or replace function app.accounts_opening_balance_is_not_writable()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $function$
begin
  -- THE CLIENT SURFACE, and not every writer.
  --
  -- `current_user` is `authenticated` for a write PostgREST makes
  -- against the table directly, and the OWNER inside a SECURITY
  -- DEFINER function -- so this refuses the PATCH and leaves internal
  -- SQL alone. That is the boundary the hazard actually has: a write
  -- from a function is a decision somebody made in a migration and a
  -- reviewer read, while a write from the API is a request anybody who
  -- may post a journal can make, against a column no screen exposes.
  --
  -- It also has to be this way round, which the tests found: `0459`'s
  -- `retire_account` refuses to DELETE an account carrying an opening
  -- balance -- `v_a.opening_balance <> 0` -- because `gl_lines` has no
  -- row to restrict on, and `chart_of_accounts.sql` sets the column to
  -- prove it. A guard that refused every writer would have broken that
  -- assertion, and the rule it is protecting.
  --
  -- `session_user` would be wrong here: inside a definer function it is
  -- still the caller, so every internal write would be refused too.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- Insert as well as update: a row created with the figure already on
  -- it was never an update anybody could audit.
  if tg_op = 'INSERT' then
    if coalesce(new.opening_balance, 0) <> 0
       or new.opening_balance_date is not null then
      raise exception
        'An opening balance belongs in a dated journal. Use '
        'import_opening_balances, which posts one and leaves the '
        'trial balance balanced.'
        using errcode = '42501';
    end if;
    -- 0844: nor with a balance on it. At the top only: a balance is
    -- moved by `app.apply_account_balance`, a trigger on `gl_lines`
    -- that is NOT a definer, so its own write arrives one level down.
    if coalesce(new.current_balance, 0) <> 0
       and pg_trigger_depth() = 1 then
      raise exception
        'A new account starts with nothing on it. Its balance is what '
        'is posted to it.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  -- `is distinct from`, not `<>`: a null on either side of `<>` is
  -- null, which is not true, so the guard would let a change to or
  -- from null through -- and `opening_balance_date` is null on every
  -- row there is.
  if new.opening_balance is distinct from old.opening_balance
     or new.opening_balance_date is distinct from old.opening_balance_date
  then
    raise exception
      'An opening balance belongs in a dated journal. Use '
      'import_opening_balances, which posts one and leaves the '
      'trial balance balanced.'
      using errcode = '42501';
  end if;

  -- 0844: the running total. `app.apply_account_balance` keeps it in
  -- step with the posted lines, from a trigger and so one level down;
  -- a client's own statement at the top is the PATCH this refuses.
  if new.current_balance is distinct from old.current_balance
     and pg_trigger_depth() = 1 then
    raise exception
      'The balance of account % is what has been posted to it, and moves '
      'when a journal does. A balance to correct is a journal to post.',
      new.code
      using errcode = '42501';
  end if;

  return new;
end;
$function$;

