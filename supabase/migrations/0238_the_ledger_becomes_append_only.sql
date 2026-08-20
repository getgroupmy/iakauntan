-- ---------------------------------------------------------------------
-- 0238  The ledger becomes append-only
-- ---------------------------------------------------------------------
--
-- `gl_entries` and `gl_lines` carried `for update` and `for delete`
-- policies whose entire condition was `app.can_post(org_id)`. Anybody
-- who may post could also edit or delete a journal that had already been
-- posted, straight through the API -- change an amount, move a line to a
-- different account, or make an entry disappear, leaving books that do
-- not add up and no way to say why.
--
-- No screen offered it: the Flutter client only ever selects from those
-- two tables, and `gl_lines` it never touches at all. But the policy is
-- what decides, not the screen. 0236 made the tampering visible by
-- auditing update and delete on both tables. This removes it.
--
-- The supported way to undo a posting is `reverse_gl_entry`, which is
-- what double-entry expects: the original stands and a reversing entry
-- says so. That is why this is a removal rather than a tightening --
-- there is no version of "edit a posted journal" that belongs in a set
-- of books.
--
-- ## The part that would have broken everything
--
-- Dropping the four policies on its own breaks *every* posting, and not
-- in a way that shows up in an ordinary rolled-back test.
--
-- `assert_balanced` on `gl_lines` is a DEFERRABLE INITIALLY DEFERRED
-- constraint trigger, so it runs at COMMIT -- and a deferred trigger
-- fires under the session's role, not under the SECURITY DEFINER
-- function that queued it. `app.assert_gl_balanced` maintains the
-- entry's totals:
--
--     update public.gl_entries set total_debit = ..., total_credit = ...
--
-- and it was SECURITY INVOKER. So at commit, as `authenticated`, with
-- the update policy gone, that statement fails:
--
--     ERROR: permission denied for table gl_entries
--
-- Measured, not reasoned about. A rolled-back probe never reaches
-- commit, so the deferred trigger never fires and the totals sit at
-- zero -- which looks identical to the bug. `SET CONSTRAINTS ALL
-- IMMEDIATE` forces it, and then the three cases separate cleanly:
--
--   * as it is today                 -> totals 100.00 / 100.00
--   * policies dropped, invoker      -> permission denied for gl_entries
--   * policies dropped, definer      -> totals 100.00 / 100.00
--
-- So the trigger function becomes SECURITY DEFINER. That is the right
-- shape independently of this migration: the entry's totals are the
-- database's own bookkeeping about its own rows, derived from the lines
-- it already accepted. They were never the writer's to authorise.

alter function app.assert_gl_balanced() security definer;

revoke all on function app.assert_gl_balanced()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- No hand may reach a posted journal
-- ---------------------------------------------------------------------
drop policy if exists gl_entries_update on public.gl_entries;
drop policy if exists gl_entries_delete on public.gl_entries;
drop policy if exists gl_lines_update   on public.gl_lines;
drop policy if exists gl_lines_delete   on public.gl_lines;

-- The grant as well as the policy. A grant without a policy is not a
-- way in, but leaving it says the door is only bolted rather than
-- bricked up -- and it turns the refusal into a silent no-op instead of
-- `permission denied`, which is the difference between somebody finding
-- out and somebody not.
revoke update, delete on public.gl_entries from authenticated;
revoke update, delete on public.gl_lines   from authenticated;

-- ---------------------------------------------------------------------
-- What is left, and the proof it is what was intended
-- ---------------------------------------------------------------------
do $do$
declare
  v_left text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ' order by policyname)
    into v_left
    from pg_policies
   where schemaname = 'public'
     and tablename in ('gl_entries', 'gl_lines')
     and cmd in ('UPDATE', 'DELETE', 'ALL');

  if v_left is not null then
    raise exception 'FAIL 0238: the ledger can still be changed through %', v_left;
  end if;

  -- The positive control. A migration that dropped every policy on both
  -- tables would satisfy the assertion above and leave the ledger
  -- unreadable and unpostable.
  if (select count(*) from pg_policies
       where schemaname = 'public'
         and tablename in ('gl_entries', 'gl_lines')
         and cmd in ('SELECT', 'INSERT')) <> 4
  then
    raise exception 'FAIL 0238: reading and posting must both survive';
  end if;
end
$do$;
