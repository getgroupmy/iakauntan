-- Take back the write access `0168` handed out by accident.
--
-- `0168` gated the fixed asset register behind an entitlement by looping
-- over its three tables and rewriting their policies. The loop was the
-- mistake: `fixed_assets` is edited by hand and wants insert, update and
-- delete policies, and the other two are not.
--
-- `0084` said so explicitly, and the comment is still there:
--
--     -- The runs are written by the posting function and read by
--     -- everyone who can see the ledger. Nothing writes them from
--     -- the API.
--
-- `depreciation_runs` and `depreciation_entries` had a select policy and
-- nothing else. `run_depreciation` is SECURITY DEFINER and writes them
-- past row level security; the API was never meant to reach them at all.
-- The loop gave them `_insert`, `_update` and `_delete` policies anyway,
-- which on the hosted project — where Supabase's default privileges
-- already grant `authenticated` every table privilege — meant a member
-- with `can_write` could have inserted fabricated depreciation entries
-- straight through PostgREST, or deleted a run out from under the
-- journal it posted.
--
-- `supabase/tests/table_grants.sql` caught it, and it is worth saying
-- how, because the mechanism is the interesting part. That test does not
-- know what these tables are for. It asserts something duller and much
-- harder to fool: **every policy naming `authenticated` must have the
-- table privilege that lets the policy run at all.** A stack built from
-- these migrations alone never granted insert on the two tables, so the
-- new policies had no privilege behind them and the assertion tripped.
--
-- The hosted project would never have shown it. Its default privileges
-- supply the missing grants, so there the policies were not decorative —
-- they were live, and the hole was open. A test that only ran against
-- production would have called this fine.

do $$
declare
  v_table text;
  v_policy text;
begin
  foreach v_table in array array['depreciation_runs', 'depreciation_entries']
  loop
    -- The permissive write policies `0168` created.
    foreach v_policy in array array['_insert', '_update', '_delete', '_write']
    loop
      execute format('drop policy if exists %I on public.%I',
                     v_table || v_policy, v_table);
    end loop;

    -- And the restrictive halves. A restrictive policy with no permissive
    -- counterpart denies everything anyway, so these were harmless — but
    -- they are still policies naming `authenticated` on a command with no
    -- grant behind it, which is exactly the shape the test refuses, and
    -- leaving them would say the API has a write path here when it does
    -- not.
    foreach v_policy in array array['module_gate_insert', 'module_gate_update',
                                    'module_gate_delete']
    loop
      execute format('drop policy if exists %I on public.%I',
                     v_policy, v_table);
    end loop;
  end loop;
end $$;

-- What is left on both tables, and what was always meant to be there:
--
--   * `<table>_select`      — permissive, any member of the company
--   * `module_gate_select`  — restrictive, the access type from 0127
--
-- Reading a depreciation schedule is how an auditor checks the charge;
-- writing one is `run_depreciation`'s job alone. `fixed_assets` keeps the
-- full set of gated write policies `0168` gave it, because an asset
-- register is a thing people type into.
