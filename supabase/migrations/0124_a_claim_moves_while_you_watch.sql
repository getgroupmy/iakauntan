-- =====================================================================
-- iAkauntan :: a claim moves while you are looking at it
--
-- 0117 published the tables a colleague can change under you, and left
-- claims out because at the time a claim was decided once, by whoever
-- pressed the button. 0119 made it a chain of up to four, and 0123 gave
-- an approver a queue of the ones waiting on them — a screen whose whole
-- content is "what other people have not done yet". That is exactly the
-- screen that must not need reloading.
--
-- ---------------------------------------------------------------------
-- Why both tables, and why `claim_approvals` is the important one
--
-- The obvious table is the wrong one on its own. Clearing an
-- intermediate step writes to `claim_approvals` and leaves
-- `expense_claims` exactly as it was — still `submitted`, same row,
-- nothing for a subscriber to notice. `expense_claims` only changes when
-- the last stage clears or somebody rejects it. So publishing the claim
-- and not the chain would deliver the ending and none of the middle,
-- which is the half the queue is made of: a manager clears stage one and
-- it should leave their list and arrive on HR's, with no reload at
-- either end.
--
-- ---------------------------------------------------------------------
-- What is safe about it
--
-- Realtime applies row level security when it decides who is sent a
-- row, and both tables are already narrower than org membership:
--
--   expense_claims  HR, anyone who can post, the claimant themselves,
--                   or the manager of the employee it belongs to
--   claim_approvals whoever may read that claim's paperwork
--
-- So no new exposure. Worth stating plainly because a claim *is* one
-- person's private business in the way 0117 was careful about with
-- payslips — the difference is that these policies already say so, and
-- Realtime honours them rather than broadcasting the table.
-- =====================================================================

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'expense_claims',
    'claim_approvals'
  ]
  loop
    -- A delete carries only the primary key by default, which is not
    -- enough for Realtime to tell whether the row was yours, so the
    -- event is dropped rather than delivered. Same reasoning as 0117.
    execute format('alter table public.%I replica identity full', v_table);

    if not exists (
      select 1
        from pg_publication_rel pr
        join pg_publication p on p.oid = pr.prpubid
        join pg_class c on c.oid = pr.prrelid
        join pg_namespace n on n.oid = c.relnamespace
       where p.pubname = 'supabase_realtime'
         and n.nspname = 'public'
         and c.relname = v_table
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end $$;
