-- =====================================================================
-- iAkauntan :: a retry that does not post twice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/idempotency.sql
--
-- 0307 added idempotency keys to the writes that create something. The
-- first block below is the defect it fixes, kept as a live assertion
-- rather than a paragraph: without a key, two identical calls to
-- `post_manual_journal` really do leave two entries in the ledger.
--
-- Asserted:
--
--   * the unguarded double-post, so the reason for all of this stays
--     visible and nobody "simplifies" the key away;
--   * a repeated key returns the first answer and does no second work;
--   * a key reused for a *different* request is refused, because
--     silently returning the first answer would hide a client bug;
--   * a key in flight is refused rather than executed twice;
--   * no key at all behaves exactly as before, which is what every
--     existing caller does;
--   * keys are scoped to one organization;
--   * the table is unreachable from the client;
--   * the sweep drops what is older than a day and keeps what is not.
--
-- Six mutants were run. Five died at the assertion they were aimed at:
-- never replaying, skipping the fingerprint check, treating an
-- in-flight key as finished, sweeping everything, and leaving the
-- table with Supabase's default grant to `authenticated`.
--
-- The sixth could not be written, and the reason is worth keeping.
-- Removing `org_id` from the key does not silently share keys between
-- tenants — it makes `on conflict (org_id, key)` match no constraint,
-- and the very first call raises "there is no unique or exclusion
-- constraint matching the ON CONFLICT specification". The scoping is
-- structural rather than asserted: it cannot degrade quietly, only
-- fail loudly, which is the better of the two.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- Two postable accounts and an open year, which anything touching the
-- ledger needs.
create or replace function pg_temp.ledger_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  return v_org;
end $$;

create or replace function pg_temp.balanced_lines(p_org uuid)
returns jsonb language plpgsql as $$
declare v_dr uuid; v_cr uuid;
begin
  select id into v_dr from public.accounts
   where org_id = p_org and is_active and not is_group
     and account_type = 'asset' limit 1;
  select id into v_cr from public.accounts
   where org_id = p_org and is_active and not is_group
     and account_type = 'revenue' limit 1;
  return jsonb_build_array(
    jsonb_build_object('account_id', v_dr, 'debit', 100, 'credit', 0),
    jsonb_build_object('account_id', v_cr, 'debit', 0,   'credit', 100));
end $$;

-- ---------------------------------------------------------------------
-- The defect, without a key
--
-- This is what a dropped connection costs. The client cannot know
-- whether the first request landed, retries, and the ledger — which is
-- append-only by design — carries the entry twice.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; a uuid; b uuid;
begin
  v_org := pg_temp.ledger_org('Ulang Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  a := public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1');
  b := public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1');

  perform pg_temp.check_true(
    'without a key, an identical retry posts a second entry', a <> b);
  perform pg_temp.check_eq(
    'and the ledger carries both',
    (select count(*) from public.gl_entries where org_id = v_org)::numeric, 2);
end $$;

-- ---------------------------------------------------------------------
-- The same request, with a key
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; a uuid; b uuid;
begin
  v_org := pg_temp.ledger_org('Sekali Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  a := public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1', 'k-1');
  b := public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1', 'k-1');

  perform pg_temp.check_eq('a repeated key returns the first answer',
    a::text, b::text);
  -- The control that matters. Returning the same id while quietly
  -- posting again would satisfy the line above and be worse than the
  -- defect, because the duplicate would be harder to find.
  perform pg_temp.check_eq('and does no second work',
    (select count(*) from public.gl_entries where org_id = v_org)::numeric, 1);
end $$;

-- ---------------------------------------------------------------------
-- A key reused for a different request is a client bug, not a retry
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; v_id uuid;
begin
  v_org := pg_temp.ledger_org('Silap Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);
  v_id := public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1', 'k-2');

  begin
    perform public.post_manual_journal(
      v_org, current_date, v_lines, 'Something else entirely', 'R-2', 'k-2');
    raise exception 'FAIL: a key was honoured for a different request';
  exception when sqlstate '22023' then
    raise notice 'ok   a key reused for a different request is refused';
  end;

  -- And the refusal did not damage what the key already stood for.
  perform pg_temp.check_eq('the original answer still stands',
    public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1', 'k-2')::text,
    v_id::text);
end $$;

-- ---------------------------------------------------------------------
-- A key still in flight
--
-- Claimed and not yet completed: the client retried before the first
-- call finished. "Ask again" is the honest answer; executing is not.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb;
begin
  v_org := pg_temp.ledger_org('Serentak Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  -- Stand in for a request that has claimed its key and not yet
  -- returned. A second connection cannot be opened inside a test that
  -- must roll back, so the claim is made directly.
  perform app.idempotency_begin(v_org, 'k-3', 'post_manual_journal',
    jsonb_build_object('entry_date', current_date, 'lines', v_lines,
                       'description', 'Fi', 'reference', 'R-1'));

  begin
    perform public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'R-1', 'k-3');
    raise exception 'FAIL: a key in flight was executed a second time';
  exception when sqlstate '55006' then
    raise notice 'ok   a key still in progress is refused, not repeated';
  end;

  perform pg_temp.check_eq('and nothing was posted',
    (select count(*) from public.gl_entries where org_id = v_org)::numeric, 0);
end $$;

-- ---------------------------------------------------------------------
-- One key, two companies
--
-- Keys are generated by clients and clients collide. A key is only ever
-- honoured for the organization it was claimed under.
-- ---------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; a uuid; b uuid;
begin
  v_a := pg_temp.ledger_org('Satu Sdn Bhd');
  v_b := pg_temp.ledger_org('Dua Sdn Bhd');

  a := public.post_manual_journal(v_a, current_date,
         pg_temp.balanced_lines(v_a), 'Fi', 'R-1', 'shared');
  b := public.post_manual_journal(v_b, current_date,
         pg_temp.balanced_lines(v_b), 'Fi', 'R-1', 'shared');

  perform pg_temp.check_true(
    'one company''s key is not another company''s answer', a <> b);
  perform pg_temp.check_eq('and each posted its own entry',
    (select count(*) from public.gl_entries where org_id in (v_a, v_b))::numeric, 2);
end $$;

-- ---------------------------------------------------------------------
-- The table is the mechanism's, not the client's
--
-- Supabase's default privileges hand every new table to `authenticated`
-- whatever the migration asked for — 0299 exists because of exactly
-- that — so 0307 revokes them explicitly. Run as `authenticated`,
-- because a superuser bypasses all of this and would prove nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.ledger_org('Sulit Kunci Sdn Bhd');
  v_user uuid := pg_temp.another_user('nosy@kunci.test');
  v_role text; v_read boolean := false;
begin
  perform public.post_manual_journal(v_org, current_date,
    pg_temp.balanced_lines(v_org), 'Fi', 'R-1', 'k-4');

  perform pg_temp.sign_in_as(v_user);
  begin
    set local role authenticated;
    v_role := current_user;
    begin
      perform 1 from public.idempotency_keys limit 1;
      v_read := true;
    exception when insufficient_privilege then
      v_read := false;
    end;
  end;
  reset role;

  perform pg_temp.check_true('the privilege test ran as authenticated',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'the client cannot read other people''s idempotency keys', not v_read);
end $$;

-- ---------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_lines jsonb; v_dropped integer;
begin
  v_org := pg_temp.ledger_org('Sapu Sdn Bhd');
  v_lines := pg_temp.balanced_lines(v_org);

  perform public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'old', 'k-old');
  update public.idempotency_keys set created_at = now() - interval '25 hours'
   where org_id = v_org and key = 'k-old';
  perform public.post_manual_journal(v_org, current_date, v_lines, 'Fi', 'new', 'k-new');

  v_dropped := app.sweep_idempotency_keys(now() - interval '24 hours');

  perform pg_temp.check_eq('the sweep drops the key that timed out',
    v_dropped::numeric, 1);
  -- The control. A sweep that took everything would pass the line above
  -- and break every retry in flight.
  perform pg_temp.check_eq('and keeps the one still inside the window',
    (select count(*) from public.idempotency_keys where org_id = v_org)::numeric, 1);
  perform pg_temp.check_eq('the survivor is the recent one',
    (select key from public.idempotency_keys where org_id = v_org), 'k-new');
end $$;

-- ---------------------------------------------------------------------
-- A replay is still somebody asking
-- ---------------------------------------------------------------------
--
-- The wrappers are thin; the guard is inside the real function. So on
-- the first call a stranger is refused correctly, and on a replay the
-- real function is never called at all -- which is how somebody who was
-- not in the company got the stored result of a write, and how a key
-- they had merely guessed was confirmed to exist. See 0475.
-- ---------------------------------------------------------------------
do $$
declare
  v_org      uuid;
  v_a        uuid;
  v_b        uuid;
  v_stranger uuid;
  v_msg      text;
  v_took     boolean;
  v_lines    jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kunci Ulang Sdn Bhd');
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);

  select id into v_a from public.accounts
   where org_id = v_org and account_type = 'expense'
     and not is_group and is_active order by code limit 1;
  select id into v_b from public.accounts
   where org_id = v_org and account_type = 'liability'
     and not is_group and is_active order by code limit 1;
  -- Nothing below proves anything without these.
  perform pg_temp.check_true('the fixture found two postable accounts',
    v_a is not null and v_b is not null);

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_a, 'debit', 100, 'credit', 0),
    jsonb_build_object('account_id', v_b, 'debit', 0, 'credit', 100));

  -- A member does the protected write, so there is a key to replay.
  perform public.post_manual_journal(
    v_org, current_date, v_lines, 'A journal', null, 'REPLAY-1');
  perform pg_temp.check_eq('the member''s journal is there',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and description = 'A journal'), 1);

  -- Somebody who is not in this company at all.
  v_stranger := pg_temp.another_user('orang.luar@idem.test');
  perform pg_temp.sign_in_as(v_stranger);

  begin
    perform public.post_manual_journal(
      v_org, current_date, v_lines, 'A journal', null, 'REPLAY-1');
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a stranger cannot replay somebody else''s key', not v_took);

  -- Same key, arguments that do not match. Before 0475 this answered
  -- `already used for a different request`, which tells somebody who
  -- guessed a key that it is real. The refusal has to be the membership
  -- one, and it has to arrive first.
  begin
    perform public.post_manual_journal(
      v_org, current_date,
      jsonb_build_array(
        jsonb_build_object('account_id', v_a, 'debit', 999, 'credit', 0),
        jsonb_build_object('account_id', v_b, 'debit', 0, 'credit', 999)),
      'Something else', null, 'REPLAY-1');
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('and learns nothing from a key they guessed',
    not v_took and v_msg not like '%already used%');

  -- The guard that was already right, kept: a fresh key still reaches
  -- the real function and is refused there.
  begin
    perform public.post_manual_journal(
      v_org, current_date, v_lines, 'Fresh', null, 'REPLAY-NEW');
    v_took := true;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('and a fresh key is refused as it always was',
    not v_took);

  -- And a member is not caught by any of it.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('while the member replays their own key',
    public.post_manual_journal(
      v_org, current_date, v_lines, 'A journal', null, 'REPLAY-1')
    is not null);
  perform pg_temp.check_eq('without writing it twice',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and description = 'A journal'), 1);
end $$;

rollback;
