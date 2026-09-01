-- =====================================================================
-- iAkauntan :: 0399 the ledger had a door beside the door
--
-- `post_manual_journal` fixes the journal's source, checks the accounts,
-- checks that debits equal credits, and checks the period. Its own
-- comment in the client says why: "the client has no business asserting
-- where a ledger entry came from … so nothing here is trusted."
--
-- `gl_entries` and `gl_lines` were `INSERT`able by `authenticated`, with
-- a policy that checks one thing:
--
--     gl_entries_insert | a | with check (app.can_post(org_id))
--
-- No period. No balance. No accounts. Every guard is in the function,
-- and the table sits open beside it. PostgREST publishes every table the
-- grants allow, so the second door is not hypothetical — it is an HTTP
-- request away.
--
-- ---------------------------------------------------------------------
-- Measured, as `authenticated`, by an accountant
--
-- Not by a superuser: `pg_temp.sign_in_as` sets `request.jwt.claims` and
-- does not `set role`, so a test that only signs in still runs as the
-- table owner and RLS never applies to it. The first measurement of this
-- was made that way and proved nothing. `access_types.sql` has the right
-- idiom — `set local role authenticated` — and under it, with a period
-- closed and a member whose role is `accountant`:
--
--   * an entry dated inside the closed period, inserted straight into
--     `gl_entries`  — accepted;
--   * a single line of 1,000,000 debit and no credit, inserted straight
--     into `gl_lines` — accepted;
--   * so the header says debit 100 credit 100 while its own lines sum to
--     1,000,000, and the trial balance and the entry disagree about the
--     same journal;
--   * `post_manual_journal`, given exactly the same closed period —
--     refused, "Fiscal period for 2026-01-01 is closed".
--
-- The front door works. That is the point: the guard was never wrong,
-- it was only avoidable.
--
-- ---------------------------------------------------------------------
-- `0239` kept this grant on purpose, and the reason was wrong
--
-- `0239` revoked `update`, `delete` and `truncate` from the ledger and
-- asserted what was left:
--
--     if not has_table_privilege('authenticated', 'public.gl_entries',
--                                'INSERT') …
--       raise exception 'FAIL 0239: posting and reading must both survive';
--
-- It calls that "the positive control", and it is a good instinct —
-- revoking everything would satisfy a "no excess privilege" check by
-- leaving nothing at all. But the belief underneath it is false.
-- `app.create_gl_entry_internal`, `public.create_gl_entry` and
-- `public.post_manual_journal` are all SECURITY DEFINER and all owned by
-- the role that owns `gl_entries`, so posting runs as the owner and does
-- not consult the `authenticated` grant at any point.
--
-- Measured rather than argued: with `insert` revoked and both policies
-- dropped, `post_manual_journal` called as `authenticated` still posts
-- and still writes both lines, and the direct insert comes back `42501`,
-- permission denied. The grant costs the whole of period control and
-- buys nothing.
--
-- `0239`'s own assertion still passes, because it runs at `0239` and
-- this migration is `0399`. That is not a trick — a migration records
-- what was true when it ran, and this one records what is true now.
--
-- ---------------------------------------------------------------------
-- What the hosted project actually held
--
-- The assertion at the foot of this migration refused the first time it
-- ran against the hosted project, which is the whole reason it is there
-- and not only in a test:
--
--     FAIL 0399: a client role holds DELETE, SELECT, UPDATE on the
--     ledger, expected SELECT
--
-- Asked precisely, the hosted project held:
--
--     authenticated  gl_entries  INSERT, SELECT
--     authenticated  gl_lines    INSERT, SELECT
--     anon           gl_entries  DELETE, INSERT, SELECT, UPDATE
--     anon           gl_lines    DELETE, INSERT, SELECT, UPDATE
--
-- `0238` revoked update and delete **from `authenticated`** and did not
-- name `anon`; `0239` revoked truncate, references and trigger from
-- both. So `anon`'s three write privileges were never taken away there.
-- A freshly migrated local stack does not have them — Supabase's
-- default privileges differ between a new project and a `supabase
-- start` — so every CI run has been green and every local suite has
-- passed while the real project carried them.
--
-- **This was excess privilege and not an open door, and the difference
-- matters.** RLS is enabled on both tables on the hosted project, and
-- the only policies on either are `insert` and `select`: there is no
-- update policy and no delete policy, so those two are denied to every
-- non-owner role whatever the grant says. The insert policy demands
-- `app.can_post(org_id)`, which is false for a caller with no
-- `auth.uid()`. Checked against the project rather than assumed.
--
-- What it did mean is that the ledger's protection rested on RLS alone
-- where it was meant to rest on RLS *and* the absence of a grant, and
-- that nothing in the repository could see the difference. Which is the
-- argument for putting the assertion in the migration: the local stack
-- is built from these files and therefore cannot disagree with them.
-- Only something that runs against the real project can.
--
-- ---------------------------------------------------------------------
-- What is not changed here, and why
--
-- An accountant can also flip a period from `closed` back to `open`,
-- because `fiscal_periods_update` is `using (app.can_post(org_id))` on
-- the whole row. That is left alone deliberately. Reopening a period to
-- book an adjustment before the accounts are finalised is ordinary
-- practice, and *who* in a company may do it is a decision for that
-- company rather than one to be made on its behalf inside a migration
-- that is about something else. It is written down in
-- `docs/unreachable.md` so the decision is available to be taken rather
-- than merely missing.
--
-- The related worry does not arise: `gl_entries_fiscal_period_id_fkey`
-- is `no action`, so a period with entries in it cannot be deleted out
-- from under them. Checked, not assumed.
-- =====================================================================

-- The ledger is written by SECURITY DEFINER functions and read by
-- everybody who may read it. There is no third thing.
--
-- `update` and `delete` are named here as well, and they are the half
-- that only the hosted project needed. See "What the hosted project
-- actually held" above: `0238` revoked those two from `authenticated`
-- and did not name `anon`, so on the hosted project `anon` still held
-- `DELETE, INSERT, SELECT, UPDATE` on both tables. A fresh local stack
-- shows none of it, which is exactly why no test could have found it.
--
-- Revoking a privilege that is already absent is a no-op, so naming all
-- four on both roles converges the two environments rather than
-- describing either.
revoke insert, update, delete on public.gl_entries from authenticated, anon;
revoke insert, update, delete on public.gl_lines   from authenticated, anon;

drop policy if exists gl_entries_insert on public.gl_entries;
drop policy if exists gl_lines_insert   on public.gl_lines;

-- `0165`'s event trigger strips PUBLIC and anon from newly created
-- functions; nothing does the equivalent for a grant handed back by a
-- later `grant all`, so the state is asserted here as well as set.
do $$
declare v_left text;
begin
  select string_agg(distinct privilege_type, ', ' order by privilege_type)
    into v_left
    from information_schema.role_table_grants
   where grantee in ('authenticated', 'anon')
     and table_schema = 'public'
     and table_name in ('gl_entries', 'gl_lines');

  if v_left is distinct from 'SELECT' then
    raise exception
      'FAIL 0399: a client role holds % on the ledger, expected SELECT. '
      'The revokes above name insert, update and delete on both tables '
      'for both roles, so anything left is a privilege granted after '
      'this migration ran.',
      coalesce(v_left, 'nothing');
  end if;

  -- The positive control `0239` meant to write. Reading has to survive,
  -- and posting has to go on working — but posting is proved by
  -- `ledger_is_written_only_by_functions.sql` actually posting as
  -- `authenticated`, not by the presence of a grant it never used.
  if not has_table_privilege('authenticated', 'public.gl_entries', 'SELECT')
     or not has_table_privilege('authenticated', 'public.gl_lines', 'SELECT')
  then
    raise exception 'FAIL 0399: the ledger must still be readable';
  end if;
end $$;

comment on table public.gl_entries is
  'The general ledger. Written only by SECURITY DEFINER functions — '
  '`0399` revoked INSERT from the client roles after measuring that an '
  'accountant could insert an entry into a closed period, and lines that '
  'did not balance, by writing to the table instead of calling '
  'post_manual_journal. Every guard was in the function and the table '
  'sat open beside it.';
