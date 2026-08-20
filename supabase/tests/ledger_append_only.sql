-- =====================================================================
-- iAkauntan :: a posted journal cannot be changed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ledger_append_only.sql
--
-- Two things have to hold at once, and it is easy to get one by losing
-- the other. A ledger nobody can edit is worthless if nobody can post to
-- it either, so every refusal below is paired with the posting that must
-- still work.
--
-- **`set constraints all immediate` is load-bearing.** `assert_balanced`
-- on `gl_lines` is DEFERRABLE INITIALLY DEFERRED, so it fires at COMMIT
-- -- which this file never reaches, because it rolls back. Without
-- forcing it, the entry's totals sit at zero and every assertion about
-- them passes or fails for the wrong reason. It is also the only way to
-- see the failure 0238 was written to avoid: a deferred trigger runs
-- under the session's role, not under the SECURITY DEFINER function that
-- queued it, so with the update policy gone and the trigger left
-- SECURITY INVOKER, every posting fails at commit with `permission
-- denied for table gl_entries`.
--
-- Everything is done as `authenticated` rather than as the superuser
-- psql connects with. RLS and table privileges do not apply to the
-- owner, so a refusal asserted as `postgres` is not a refusal at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temp table pg_temp_ledger(step text, entry uuid);
grant all on pg_temp_ledger to authenticated;

-- The fixture, built while still the superuser.
do $$
declare
  v_org uuid;
  v_a   uuid;
  v_b   uuid;
begin
  v_org := pg_temp.test_org('Lejar Kekal Sdn Bhd');

  -- `test_org` seeds the chart of accounts but not a fiscal year, and
  -- nothing posts outside one: "No fiscal period covers ...". Derived
  -- from today rather than pinned to 2026, so this file does not quietly
  -- stop testing anything when the year turns.
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  select id into v_a from public.accounts
   where org_id = v_org and not is_group and is_active and deleted_at is null
     and account_type = 'asset' order by code limit 1;
  select id into v_b from public.accounts
   where org_id = v_org and not is_group and is_active and deleted_at is null
     and account_type = 'revenue' order by code limit 1;

  perform pg_temp.check_true('the fixture has two postable accounts',
    v_a is not null and v_b is not null);

  insert into pg_temp_ledger (step, entry)
  values ('org', v_org),
         ('entry', public.post_manual_journal(v_org, current_date,
            jsonb_build_array(
              jsonb_build_object('account_id', v_a, 'debit',  100, 'credit', 0),
              jsonb_build_object('account_id', v_b, 'debit',    0, 'credit', 100)),
            'A journal that stands', 'KEKAL'));
end;
$$;

-- Fire the deferred constraint triggers. Everything about the totals
-- below is meaningless without this.
set constraints all immediate;

do $$
begin
  perform pg_temp.check_eq('posting maintains the entry total',
    (select total_debit from public.gl_entries
      where id = (select entry from pg_temp_ledger where step = 'entry')), 100);
  perform pg_temp.check_eq('on both sides',
    (select total_credit from public.gl_entries
      where id = (select entry from pg_temp_ledger where step = 'entry')), 100);
  perform pg_temp.check_eq('and it has its lines',
    (select count(*)::int from public.gl_lines
      where entry_id = (select entry from pg_temp_ledger where step = 'entry')), 2);
end;
$$;

-- ---------------------------------------------------------------------
-- Now as somebody who may post, which is the strongest ordinary hand
-- ---------------------------------------------------------------------
set local role authenticated;

do $$
declare
  v_entry uuid := (select entry from pg_temp_ledger where step = 'entry');
  v_failed boolean;
begin
  perform pg_temp.check_true('this person may post',
    app.can_post((select entry from pg_temp_ledger where step = 'org')));

  v_failed := false;
  begin
    update public.gl_entries set total_debit = 1 where id = v_entry;
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('a posted journal cannot be edited', v_failed);

  v_failed := false;
  begin
    update public.gl_lines set debit = 1 where entry_id = v_entry;
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('nor can its lines', v_failed);

  v_failed := false;
  begin
    delete from public.gl_lines where entry_id = v_entry;
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('its lines cannot be deleted', v_failed);

  v_failed := false;
  begin
    delete from public.gl_entries where id = v_entry;
  exception when others then
    v_failed := true;
  end;
  perform pg_temp.check_true('and neither can the journal', v_failed);

  -- The half that stops all of the above being satisfied by a ledger
  -- nobody can reach at all.
  perform pg_temp.check_true('but it can still be read',
    (select count(*) from public.gl_entries where id = v_entry) = 1);
  perform pg_temp.check_eq('and it is exactly as it was posted',
    (select total_debit from public.gl_entries where id = v_entry), 100);

  -- And the supported way to undo one still works, from the same hand.
  perform public.reverse_gl_entry(v_entry, current_date);
  perform pg_temp.check_eq('reversal writes a second entry rather than editing the first',
    (select count(*)::int from public.gl_entries
      where org_id = (select entry from pg_temp_ledger where step = 'org')), 2);
end;
$$;

-- The reversal's own lines have to survive commit too -- this is the
-- statement that failed before the trigger became SECURITY DEFINER.
set constraints all immediate;

reset role;

rollback;
