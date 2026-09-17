-- =====================================================================
-- iAkauntan :: why a deal closed
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/win_loss.sql
--
-- `opportunities.won_reason`, `lost_reason` and `competitor` have been
-- columns since `0008` and none was ever written. Dragging a card to
-- Closed Lost is one update of `stage_id`; the trigger sets the status
-- and the close date, and nothing asks why.
--
-- Three claims:
--
--   1. A lost or abandoned deal cannot be closed without a reason. This
--      is the whole point — an optional field on a form nobody has time
--      for is a field that stays empty, and the report built on it stays
--      empty with it. A won deal is not asked, because no decision is
--      waiting on why somebody said yes.
--   2. `abandoned` is reachable. `opportunities.status` has allowed it
--      since `0008` and `pipeline_stages.stage_type` has not, so no
--      stage could produce it. Lost is a customer buying elsewhere;
--      abandoned is a deal that went quiet, and a pipeline calling those
--      the same thing reports a loss rate that is not true.
--   3. The stage trigger still does its work. Closing goes through the
--      stage first so the probability, the close date and the stage
--      history are written exactly as a drag would write them — and then
--      the status is set, because the trigger would overwrite it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A pipeline with the three stages every board has.
create or replace function pg_temp.wl_pipeline(
  p_org uuid, out pipeline uuid, out qualify uuid, out proposal uuid,
  out won uuid, out lost uuid)
language plpgsql as $$
begin
  insert into public.pipelines (org_id, name) values (p_org, 'Sales')
  returning id into pipeline;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, stage_type, sort_order)
  values (p_org, pipeline, 'Qualify', 20, 'open', 1) returning id into qualify;
  -- A second open stage, so that "the stage that was named" and "the
  -- first open one" are different answers and the assertions below can
  -- tell them apart.
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, stage_type, sort_order)
  values (p_org, pipeline, 'Proposal', 60, 'open', 2) returning id into proposal;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, stage_type, sort_order)
  values (p_org, pipeline, 'Closed Won', 100, 'won', 5) returning id into won;
  insert into public.pipeline_stages
    (org_id, pipeline_id, name, probability, stage_type, sort_order)
  values (p_org, pipeline, 'Closed Lost', 0, 'lost', 6) returning id into lost;
end $$;

create or replace function pg_temp.wl_deal(
  p_org uuid, p_pipeline uuid, p_stage uuid, p_no text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.opportunities
    (org_id, opportunity_no, name, pipeline_id, stage_id, amount)
  values (p_org, p_no, 'Deal ' || p_no, p_pipeline, p_stage, p_amount)
  returning id into v_id;
  return v_id;
end $$;

do $$
declare
  v_org   uuid;
  p       record;
  v_a     uuid;
  v_b     uuid;
  v_c     uuid;
  v_d     uuid;
  v_said  text;
  r       record;
begin
  v_org := pg_temp.test_org('Kenapa Kalah Sdn Bhd');
  select * into p from pg_temp.wl_pipeline(v_org);

  v_a := pg_temp.wl_deal(v_org, p.pipeline, p.qualify, 'OPP-1', 50000);
  v_b := pg_temp.wl_deal(v_org, p.pipeline, p.qualify, 'OPP-2', 30000);
  v_c := pg_temp.wl_deal(v_org, p.pipeline, p.qualify, 'OPP-3', 20000);
  v_d := pg_temp.wl_deal(v_org, p.pipeline, p.qualify, 'OPP-4', 10000);

  -- ------------------------------------------------------------------
  -- The refusal that is the whole migration
  -- ------------------------------------------------------------------
  begin
    perform public.close_opportunity(v_a, 'lost');
    raise exception 'FAIL: a deal was lost with no reason';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a lost deal must say why',
    v_said like '%Say why%');
  perform pg_temp.check_true('and the message says what the field is for',
    v_said like '%only question it is for%');
  perform pg_temp.check_eq('the deal is untouched',
    (select status from public.opportunities where id = v_a), 'open');

  -- Whitespace is not a reason.
  begin
    perform public.close_opportunity(v_a, 'lost', '   ');
    raise exception 'FAIL: whitespace was accepted as a reason';
  exception when sqlstate '23514' then
    null;
  end;

  -- ------------------------------------------------------------------
  -- Won, lost and abandoned
  -- ------------------------------------------------------------------
  perform public.close_opportunity(
    v_a, 'lost', 'Price', 'Sistem Awan', date '2026-05-20');
  perform pg_temp.check_eq('a lost deal closes',
    (select status from public.opportunities where id = v_a), 'lost');
  perform pg_temp.check_eq('with the reason',
    (select lost_reason from public.opportunities where id = v_a), 'Price');
  perform pg_temp.check_eq('and the competitor named',
    (select competitor from public.opportunities where id = v_a),
    'Sistem Awan');
  perform pg_temp.check_true('and no won reason',
    (select won_reason is null from public.opportunities where id = v_a));
  perform pg_temp.check_eq('on the day given',
    (select actual_close_date from public.opportunities where id = v_a)::text,
    '2026-05-20');

  -- The stage trigger still did its work: the card is in the Closed Lost
  -- column, at that column's probability, with a history row.
  perform pg_temp.check_eq('the card lands in the lost column',
    (select stage_id from public.opportunities where id = v_a), p.lost);
  perform pg_temp.check_eq('at that column''s probability',
    (select probability from public.opportunities where id = v_a), 0);
  perform pg_temp.check_eq('and the move is in the stage history',
    (select count(*) from public.opportunity_stage_history h
      where h.opportunity_id = v_a and h.to_stage_id = p.lost), 1);

  -- Won, where the reason is offered rather than demanded.
  perform public.close_opportunity(v_b, 'won', null, 'Sistem Awan',
    date '2026-05-21');
  perform pg_temp.check_eq('a won deal closes without one',
    (select status from public.opportunities where id = v_b), 'won');
  perform pg_temp.check_true('with no reason recorded',
    (select won_reason is null from public.opportunities where id = v_b));
  perform pg_temp.check_eq('the competitor is kept on a win too',
    (select competitor from public.opportunities where id = v_b),
    'Sistem Awan');
  perform pg_temp.check_eq('and it lands in the won column',
    (select stage_id from public.opportunities where id = v_b), p.won);

  -- Abandoned, which no stage could produce.
  perform public.close_opportunity(
    v_c, 'abandoned', 'Went quiet after the demo', null, date '2026-05-22');
  perform pg_temp.check_eq('an abandoned deal is abandoned, not lost',
    (select status from public.opportunities where id = v_c), 'abandoned');
  perform pg_temp.check_eq('and the reason is on the lost side',
    (select lost_reason from public.opportunities where id = v_c),
    'Went quiet after the demo');
  -- The card still goes in the Closed Lost column: a board with no
  -- column for it would have nowhere to put the card. The difference
  -- lives in the status, which is what the report groups by.
  perform pg_temp.check_eq('while the card sits in the lost column',
    (select stage_id from public.opportunities where id = v_c), p.lost);

  -- Closing twice.
  begin
    perform public.close_opportunity(v_c, 'lost', 'Changed my mind');
    raise exception 'FAIL: a closed deal was closed again';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a closed deal cannot be closed again',
    v_said like '%already closed as abandoned%');

  -- Not an outcome at all.
  begin
    perform public.close_opportunity(v_d, 'maybe', 'Who knows');
    raise exception 'FAIL: an invented outcome was accepted';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and only three outcomes exist',
    v_said like '%won, lost or abandoned%');

  -- ------------------------------------------------------------------
  -- The report the reasons are for
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('three closed deals in the window',
    (select sum(w.deals) from public.report_win_loss(
       v_org, date '2026-05-01', date '2026-05-31') w), 3);

  select * into r from public.report_win_loss(
    v_org, date '2026-05-01', date '2026-05-31') w
   where w.outcome = 'lost';
  perform pg_temp.check_eq('the loss is grouped under its reason',
    r.reason, 'Price');
  perform pg_temp.check_eq('with the money on it', r.amount, 50000.00);
  perform pg_temp.check_eq('and the competitor named rather than counted',
    r.competitors, 'Sistem Awan');

  select * into r from public.report_win_loss(
    v_org, date '2026-05-01', date '2026-05-31') w
   where w.outcome = 'abandoned';
  perform pg_temp.check_eq('abandoned is its own line, not part of lost',
    r.reason, 'Went quiet after the demo');

  select * into r from public.report_win_loss(
    v_org, date '2026-05-01', date '2026-05-31') w
   where w.outcome = 'won';
  perform pg_temp.check_eq('and a win with no reason says so',
    r.reason, 'Not given');

  -- Outside the window, so out of the report.
  perform pg_temp.check_eq('the window is the close date',
    (select coalesce(sum(w.deals), 0) from public.report_win_loss(
       v_org, date '2026-06-01', date '2026-06-30') w), 0);

  -- ------------------------------------------------------------------
  -- Reopening
  -- ------------------------------------------------------------------
  perform public.reopen_opportunity(v_a);
  perform pg_temp.check_eq('a reopened deal is open again',
    (select status from public.opportunities where id = v_a), 'open');
  perform pg_temp.check_eq('back in an open column, not the one it died in',
    (select stage_id from public.opportunities where id = v_a), p.qualify);
  perform pg_temp.check_true('with the reason and the close date cleared',
    (select lost_reason is null and actual_close_date is null
       from public.opportunities where id = v_a));
  -- The competitor stays. It is a fact about the deal rather than about
  -- how it ended, and it is still true.
  perform pg_temp.check_eq('and the competitor still named',
    (select competitor from public.opportunities where id = v_a),
    'Sistem Awan');

  -- Coming back to a named stage rather than the first one, because a
  -- deal that was at Proposal when it died did not go back to square one.
  perform public.reopen_opportunity(v_c, p.proposal);
  perform pg_temp.check_eq('a named open stage is where it lands',
    (select stage_id from public.opportunities where id = v_c), p.proposal);

  -- And a closed stage is not a stage to come back to. Without the
  -- filter this leaves an open deal sitting in the Closed Lost column,
  -- which is worse than refusing: the board and the status disagree.
  perform public.close_opportunity(v_c, 'lost', 'Gone again');
  perform public.reopen_opportunity(v_c, p.lost);
  perform pg_temp.check_eq('naming a closed one falls back to the first open',
    (select stage_id from public.opportunities where id = v_c), p.qualify);
  perform pg_temp.check_eq('and the deal is open, not sitting closed',
    (select status from public.opportunities where id = v_c), 'open');

  begin
    perform public.reopen_opportunity(v_a);
    raise exception 'FAIL: an open deal was reopened';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('while an open one has nothing to reopen',
    v_said like '%already open%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The lead that came to nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_lead uuid;
  v_said text;
begin
  v_org := pg_temp.test_org('Prospek Sejuk Sdn Bhd');

  insert into public.leads (org_id, lead_no, company_name, status)
  values (v_org, 'LD-1', 'Kedai Runcit Pak Din', 'contacted')
  returning id into v_lead;

  begin
    perform public.close_lead(v_lead, '');
    raise exception 'FAIL: a lead was lost with no reason';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a lost lead must say why',
    v_said like '%Say why%');

  perform public.close_lead(v_lead, 'Bought from a reseller instead');
  perform pg_temp.check_eq('and then it is lost',
    (select status::text from public.leads where id = v_lead), 'lost');
  perform pg_temp.check_eq('with the reason kept',
    (select lost_reason from public.leads where id = v_lead),
    'Bought from a reseller instead');

  -- `convert_lead` has refused a lost lead since `0093` and told the
  -- caller to reopen it first — advice about a state nothing could
  -- deliberately enter and nothing could leave.
  begin
    perform public.convert_lead(v_lead);
    raise exception 'FAIL: a lost lead was converted';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a lost lead cannot be converted',
    v_said like '%reopen it first%');

  perform public.reopen_lead(v_lead);
  -- To contacted rather than new: somebody spoke to them, and pretending
  -- otherwise loses the only thing the record knew.
  perform pg_temp.check_eq('reopening puts it back at contacted',
    (select status::text from public.leads where id = v_lead), 'contacted');
  perform pg_temp.check_true('and clears the reason',
    (select lost_reason is null from public.leads where id = v_lead));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('closing a deal is closed to anon',
    not has_function_privilege('anon',
      'public.close_opportunity(uuid, text, text, text, date)', 'execute'));
  perform pg_temp.check_true('and closing a lead',
    not has_function_privilege('anon',
      'public.close_lead(uuid, text)', 'execute'));
  perform pg_temp.check_true('and the report',
    not has_function_privilege('anon',
      'public.report_win_loss(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may read the report',
    has_function_privilege('authenticated',
      'public.report_win_loss(uuid, date, date)', 'execute'));
end $$;

rollback;
