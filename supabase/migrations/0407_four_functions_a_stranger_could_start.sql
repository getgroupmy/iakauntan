-- =====================================================================
-- iAkauntan :: 0407 four functions a stranger could start
--
-- `0095` found this exact shape and fixed two instances of it, and
-- wrote down what it had learned:
--
--     EXECUTE goes to PUBLIC on every new function, so `grant execute to
--     authenticated` narrows nothing [...]
--
--       app.issue_share_token       mints a live share link for ANY
--                                   document id with no permission
--                                   check, because the nightly run has
--                                   no signed-in user to check.
--       app.queue_overdue_reminders would let anybody start a mailing
--                                   run.
--
--     `supabase/tests/statutory.sql` asserts that no SECURITY DEFINER
--     function outside a three-name allowlist is executable by `anon`.
--     It caught both of these, which is the entire reason it exists.
--
-- That assertion names `anon`, and only `anon`. Nothing has ever asked
-- the same question of `authenticated` — and `authenticated` is the role
-- anybody gets by signing up.
--
-- ---------------------------------------------------------------------
-- Measured, as a member of one company who is not a member of the other
--
-- Under `set local role authenticated`, with `app.is_org_member(theirs)`
-- returning false:
--
--     select app.roll_leave_year(<the other company>, 2026)
--         -- accepted. Their leave year, rolled by a stranger.
--     select app.run_recurring_journals(current_date)
--         -- accepted. Recurring journals posted for EVERY tenant on
--         -- the platform, on a date the caller chose.
--
-- Asked of the catalogue rather than of those two: every SECURITY
-- DEFINER function in `app` that writes and is executable by a client
-- role. There are four, and not one of them carries a guard:
--
--     roll_leave_year(p_org_id, p_year)     leave balances
--     run_recurring_journals(p_on)          no organization at all
--     seed_chart_of_accounts(p_org_id)      accounts
--     seed_org_modules(p_org_id)            module entitlements
--
-- The last is the one to look at twice. `0127` and `0129` built module
-- entitlements so a company is only in the modules it has paid for;
-- `seed_org_modules` writes that table for whatever organization id it
-- is handed.
--
-- ---------------------------------------------------------------------
-- Excess privilege, not an open door — and the difference matters
--
-- Said plainly, because `0399` had to correct itself on exactly this
-- point: **none of the four is reachable through the API.** PostgREST
-- publishes `public` and does not publish `app`, and there is no
-- `public` wrapper for any of them — checked against the catalogue, not
-- assumed. A caller holding a session and speaking to PostgREST cannot
-- name them.
--
-- What is left is `0240`'s argument, quoted here because it is the
-- whole reason to bother: "anything holding a connection string gets
-- the privilege, not the API's opinion of it." Supabase hands out a
-- connection string, and the grant is not a leftover default — the ACL
-- reads `authenticated=X/postgres`, which is somebody having written
-- `grant execute ... to authenticated`.
--
-- ---------------------------------------------------------------------
-- Nothing loses anything
--
-- All four are called from `app.run_daily_jobs` and from org creation,
-- and a SECURITY DEFINER function calling another runs as the definer,
-- so the inner grant is never consulted on those paths. The suite is
-- what proves that rather than this paragraph.
-- =====================================================================

revoke execute on function app.roll_leave_year(uuid, integer)
  from public, anon, authenticated;
revoke execute on function app.run_recurring_journals(date)
  from public, anon, authenticated;
revoke execute on function app.seed_chart_of_accounts(uuid)
  from public, anon, authenticated;
revoke execute on function app.seed_org_modules(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- And the rule, asked of the catalogue
-- ---------------------------------------------------------------------
-- Mechanical on purpose. An earlier version of this asked "does it
-- carry a guard", which means matching the *names* of guards — and a
-- sweep written as a list of guard names measures the list, not the
-- code. `0395` learned that the hard way.
--
-- So the rule takes no view on guards: a function in `app` that writes
-- and runs as its definer is not something a client role executes,
-- guarded or not. The exemption list is empty and is the whole of the
-- judgement here; adding a name to it is a sentence somebody has to
-- write.
do $do$
declare v_open text; v_n int;
begin
  select count(*), string_agg(p.proname, ', ' order by p.proname)
    into v_n, v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.prosecdef
     and (has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute'))
     and p.prosrc ~* '(insert into|update +public\.|delete +from)'
     -- Deliberately executable by a client role despite writing. Empty,
     -- and each name added needs the reason beside it.
     and p.proname <> all (array[]::text[]);

  if v_n > 0 then
    raise exception
      'FAIL 0407: % writes and runs as its definer, and a client role '
      'can execute it. PostgREST does not publish `app`, so this is '
      'excess privilege rather than an open door -- but a connection '
      'string is not PostgREST. Revoke it, or add it to the exemption '
      'list in this migration with the reason.', v_open;
  end if;
  raise notice
    '0407: nothing in app that writes is executable by a client role';
end
$do$;
