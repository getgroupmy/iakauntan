-- =====================================================================
-- iAkauntan :: 0643 a figure no journal explains
--
-- `accounts.opening_balance` is added into the opening figure of six
-- statutory reports -- `report_trial_balance`,
-- `report_general_ledger`, `report_balance_sheet`,
-- `report_cash_flow`, `report_changes_in_equity` and
-- `report_group_trial_balance` -- signed by the account's type, and
-- read WITHOUT A DATE. Whatever period is asked for, the whole of it
-- is in that period's opening balance.
--
-- `accounts.opening_balance_date` exists, on the next line of `0003`,
-- and no function, view, index or line of Dart has ever read it. It was
-- one of the columns the orphan sweep reported.
--
-- ---------------------------------------------------------------------
-- Nothing writes it, and anybody could
--
-- Checked rather than assumed, and the first reading was wrong: the
-- `opening_balance` the demo seeds write is on `bank_accounts`, a
-- different table, where `resync_bank_balance` reads it and it is
-- correct. On `accounts`, no function writes either column, no
-- migration writes them, the client's `upsert_account` does not name
-- them, and every row in a freshly migrated database holds `0` and
-- `null`.
--
-- So the reports add a term that is always zero. What makes that worth
-- a migration rather than a note is the OTHER half: `authenticated`
-- holds `update` and `insert` on the table, including those columns,
-- and the policies ask only `app.can_post`. A PATCH straight at
-- PostgREST --
--
--     PATCH /rest/v1/accounts?id=eq.<uuid>
--     {"opening_balance": 50000}
--
-- -- is accepted from anyone who may post a journal. And then:
--
--   * the 50,000 is in the opening figure of every period, including
--     periods before the company converted, because no date is
--     consulted;
--   * it is in no journal, so nothing explains it and nothing reverses
--     it;
--   * and the TRIAL BALANCE NO LONGER BALANCES -- debits exceed
--     credits by 50,000, with no entry to point at.
--
-- That is not a latent trap. It is one request away, and the product
-- offers no screen that would ever make it.
--
-- ---------------------------------------------------------------------
-- A trigger, and not a revoke
--
-- The revoke was the first attempt and it does not work. `authenticated`
-- holds UPDATE at TABLE level, which implies every column, and a
-- column-level `revoke update (opening_balance)` on top of that removes
-- nothing -- the migration's own self-check refused it, which is the
-- only reason this is not sitting in the repository looking like a
-- fix.
--
-- Making it work would mean revoking UPDATE on the table and granting
-- back a list of every other column. That is a maintenance trap with
-- a long fuse: the next migration that adds a column to `accounts`
-- would leave it unwritable, with nothing to say why, and the symptom
-- would appear in whichever screen edits it.
--
-- So a trigger, which is the shape this repository already uses where
-- the rule is about the row rather than about who is asking -- `0171`'s
-- `fs_freeze` makes the same argument. It fires wherever the write
-- comes from, including a SECURITY DEFINER function, which is right:
-- nothing legitimate writes these columns from anywhere.
--
-- The hatch is the role. `0171` gives its own trigger a session flag
-- because the functions that must write past it exist; here the
-- boundary is simpler and needs no flag -- a SECURITY DEFINER function
-- runs as the owner and is let through, the API is not. Whatever needs
-- to write this figure from a screen some day has to do it in the same
-- migration that teaches the six reports `opening_balance_date`, which
-- is the ordering the whole problem asks for.
--
-- ---------------------------------------------------------------------
-- The privilege goes, and the reports are left alone
--
-- Column-level, so everything else about an account stays editable by
-- whoever may post: a code, a name, a parent, a tax code. Only these
-- two are taken away.
--
-- `upsert_account` is SECURITY DEFINER and runs as the owner, so the
-- chart of accounts editor is untouched -- and it does not name either
-- column anyway.
--
-- The SIX REPORTS ARE NOT CHANGED, deliberately. The term is
-- provably zero once nothing can write it, so removing it would be a
-- no-op edit to six statutory reports -- risk with nothing on the
-- other side of it. If a real opening balance is ever wanted on the
-- column rather than in a journal, the reports have to learn
-- `opening_balance_date` first, and that is the commit to write then.
--
-- ---------------------------------------------------------------------
-- The mechanism that IS right
--
-- `import_opening_balances(org, rows, as_at, commit)` -- 0150, 0177,
-- 0525. It posts a GL entry dated `p_as_at` with
-- `source = 'opening_balance'` against the suspense account
-- `app.opening_balance_account` returns, so the date of an opening
-- balance is on the journal, the figure is in the ledger, and the
-- trial balance balances because it is a double entry like everything
-- else. `report_opening_balance_suspense` is how anybody finds what is
-- left unallocated.
--
-- That is reachable from the app and asserted. This migration closes
-- the door beside it.
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

  return new;
end;
$function$;

-- `drop if exists` first, as `0064` and `0062` do: a migration that
-- cannot be re-applied cannot be verified locally either, and the
-- first run of this one left the trigger behind when its own
-- self-check failed.
drop trigger if exists opening_balance_is_not_writable on public.accounts;

create trigger opening_balance_is_not_writable
  before insert or update on public.accounts
  for each row
  execute function app.accounts_opening_balance_is_not_writable();

comment on column public.accounts.opening_balance is
  'Vestigial. An opening balance belongs in a dated journal -- see '
  'public.import_opening_balances -- and this column is read DATELESS '
  'by six statutory reports. 0643 revoked write access rather than '
  'change them: the term is provably zero while nothing can write it. '
  'Anything that needs to write it must teach those reports '
  'opening_balance_date first.';

comment on column public.accounts.opening_balance_date is
  'Never read by anything. See the comment on opening_balance: the six '
  'reports that use the figure ignore this, which is why the figure is '
  'not writable.';

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_def text;
begin
  -- The shape, and only the shape. Proving the refusal needs an
  -- organization, an account and a signed-in caller, and a migration
  -- that created one tripped `app.add_creator_as_owner`: there is no
  -- `auth.uid()` at migration time, so the owner row it writes fails
  -- `org_members_identity_ck`. A migration should not be inventing a
  -- company to test itself in.
  --
  -- `chart_of_accounts.sql` proves the behaviour, by trying it, as
  -- `authenticated`, both ways, with controls.
  select pg_get_triggerdef(oid) into v_def
    from pg_trigger
   where tgrelid = 'public.accounts'::regclass
     and tgname = 'opening_balance_is_not_writable';

  if v_def is null then
    raise exception 'the guard is not on the table';
  end if;

  -- BEFORE, or it fires after the row is written and cannot refuse it.
  if v_def !~* 'before' then
    raise exception 'the guard does not run before the write: %', v_def;
  end if;

  -- Both statements. An update-only guard misses an account created
  -- with the figure already on it, which is the easier of the two to
  -- do by accident.
  if v_def !~* 'insert' or v_def !~* 'update' then
    raise exception 'the guard does not cover both writes: %', v_def;
  end if;

  -- FOR EACH ROW: a statement-level trigger has no `new` to compare.
  if v_def !~* 'for each row' then
    raise exception 'the guard is not per row: %', v_def;
  end if;
end $do$;
