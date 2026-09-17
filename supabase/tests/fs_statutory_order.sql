-- =====================================================================
-- iAkauntan :: the statutory order of the accounts
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/fs_statutory_order.sql
--
-- Three dates on `fs_filings` describe one sequence the Companies Act
-- 2016 lays down — approved (s.251), circulated (s.258), lodged (s.259)
-- — and nothing enforced that each happens before the next.
--
-- The cost is in `fs_deadlines`, whose own comment says the s.259 clock
-- "runs from the act, not from the entitlement". Given a circulation
-- date that precedes the approval it is supposed to be of, or a
-- lodgement with no circulation at all, it computes a deadline from
-- something that did not happen and reports the filing compliant.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.so_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end $$;

create or replace function pg_temp.so_filing(p_org uuid, p_fy_end date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status)
  -- Unaudited, because `fs_freeze` demands the auditor, the opinion and
  -- the report date of audited accounts and none of that is the rule
  -- under test here. The one block that is about the audit report date
  -- sets it explicitly.
  values (p_org, (p_fy_end - interval '1 year' + interval '1 day')::date,
          p_fy_end, 'mpers', 'unaudited')
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- The order the Act lays down
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.so_org('Susunan Akaun Sdn Bhd');
  v_f     uuid;
  v_said  text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_fye   date := (now() at time zone 'Asia/Kuala_Lumpur')::date - 90;
begin
  v_f := pg_temp.so_filing(v_org, v_fye);

  -- Circulating what the board has not approved is circulating a draft.
  begin
    update public.fs_filings set circulated_on = v_today - 10
     where id = v_f;
    raise exception 'FAIL: accounts were circulated before being approved';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('what goes to the members is the approved '
    'accounts', v_said like '%before the circulation%');

  -- And approval after circulation is the same fault the other way up.
  update public.fs_filings set directors_approval_date = v_today - 5
   where id = v_f;
  begin
    update public.fs_filings set circulated_on = v_today - 10
     where id = v_f;
    raise exception 'FAIL: the accounts were circulated before approval';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and the two dates are named when they '
    'disagree', v_said like '%wrong way round%');

  -- Same day is in order: a board that approves and circulates on the
  -- same afternoon has done both in the right sequence.
  update public.fs_filings set circulated_on = v_today - 5 where id = v_f;
  perform pg_temp.check_eq('approved and circulated the same day is fine',
    (select circulated_on from public.fs_filings where id = v_f)::text,
    (v_today - 5)::text);

  -- None of the three is a plan.
  begin
    update public.fs_filings set directors_approval_date = v_today + 1
     where id = v_f;
    raise exception 'FAIL: the directors approved the accounts in the future';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('s.251 is a record of a meeting',
    v_said like '%has not happened%');

  begin
    update public.fs_filings set circulated_on = v_today + 1 where id = v_f;
    raise exception 'FAIL: the accounts were circulated in the future';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and neither is the circulation',
    v_said like '%circulated on a day that has not happened%');

  -- The audit report cannot predate the year it reports on.
  begin
    update public.fs_filings set audit_report_date = v_fye - 1
     where id = v_f;
    raise exception 'FAIL: the audit report predated the year end';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor can the audit report predate the year',
    v_said like '%before the year end it reports on%');

  -- The year end itself is the boundary and it is allowed: an auditor
  -- who signs on the last day of the year has reported on the year.
  update public.fs_filings set audit_report_date = v_fye where id = v_f;
  perform pg_temp.check_eq('a report dated on the year end is in time',
    (select audit_report_date from public.fs_filings where id = v_f)::text,
    v_fye::text);

  -- On or after the year end is ordinary, and allowed.
  update public.fs_filings set audit_report_date = v_fye + 30 where id = v_f;
  perform pg_temp.check_eq('an audit report after the year end is fine',
    (select audit_report_date from public.fs_filings where id = v_f)::text,
    (v_fye + 30)::text);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Lodging what was circulated
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.so_org('Serah Akaun Sdn Bhd');
  v_f     uuid;
  v_said  text;
  v_row   record;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_fye   date := (now() at time zone 'Asia/Kuala_Lumpur')::date - 100;
begin
  v_f := pg_temp.so_filing(v_org, v_fye);
  perform public.fs_freeze(v_f);

  -- Thirty days from nothing is not a deadline anybody met.
  begin
    perform public.fs_lodge(v_f, 'MBRS-2026-1');
    raise exception 'FAIL: accounts were lodged with no circulation behind them';
  exception when sqlstate '22023' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('s.259 lodges what was circulated',
    v_said like '%went to the members first%');

  -- Circulate it properly, and it lodges.
  perform public.fs_unfreeze(v_f);
  update public.fs_filings
     set directors_approval_date = v_today - 20, circulated_on = v_today - 18
   where id = v_f;
  perform public.fs_freeze(v_f);
  perform public.fs_lodge(v_f, 'MBRS-2026-1', v_today - 2);
  perform pg_temp.check_eq('and then it lodges',
    (select status::text from public.fs_filings where id = v_f), 'lodged');

  -- Lodged before it was circulated is the same fault as circulated
  -- before it was approved, one step along. `fs_lodge` cannot produce
  -- it — it takes the date from the caller and the filing is already
  -- circulated by then — but a correction to either date afterwards
  -- can, and a lodgement that predates its own circulation makes
  -- `fs_deadlines` measure a negative thirty days.
  begin
    update public.fs_filings set lodged_on = v_today - 30 where id = v_f;
    raise exception 'FAIL: the accounts were lodged before being circulated';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('s.259 lodges what was circulated, after it '
    'was circulated', v_said like '%lodges what was circulated%');

  -- Nor is the lodgement a plan. `fs_lodge` takes the date from the
  -- caller, so a fat finger puts a filing on the record as lodged next
  -- month — and it leaves the deadline board looking settled.
  begin
    update public.fs_filings set lodged_on = v_today + 1 where id = v_f;
    raise exception 'FAIL: the accounts were lodged in the future';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a lodgement is not a plan either',
    v_said like '%lodged on a day that has not happened%');

  -- The clock ran from the act. Eighteen days back plus thirty is the
  -- deadline, not six months after the year end plus thirty — which is
  -- the whole reason the sequence has to hold.
  select * into v_row from public.fs_deadlines(v_f);
  perform pg_temp.check_eq('the s.259 clock runs from the circulation',
    v_row.lodge_by::text, (v_today - 18 + 30)::text);
  perform pg_temp.check_true('and the filing is not late',
    not v_row.is_late);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Which company the accounts are for
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.so_org('Setiausaha Akaun Sdn Bhd');
  v_other uuid := pg_temp.so_org('Firma Lain Sdn Bhd');
  v_e1    uuid;
  v_e2    uuid;
  v_alien uuid;
  v_f     uuid;
  v_said  text;
  v_row   record;
  v_n     integer;
  v_out   uuid := pg_temp.another_user('outsider@so.test');
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_fye   date := (now() at time zone 'Asia/Kuala_Lumpur')::date - 150;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.corp_entities (org_id, name, registration_no)
  values (v_org, 'Klien Pertama Sdn Bhd', '202301000001')
  returning id into v_e1;
  insert into public.corp_entities (org_id, name, registration_no)
  values (v_org, 'Klien Kedua Sdn Bhd', '202301000002')
  returning id into v_e2;
  insert into public.corp_entities (org_id, name, registration_no)
  values (v_other, 'Bukan Klien Sdn Bhd', '202301000003')
  returning id into v_alien;

  v_f := pg_temp.so_filing(v_org, v_fye);

  -- Unnamed, the accounts are still the organization's own.
  select * into v_row from public.report_fs_deadlines(v_org, 400)
   where filing_id = v_f;
  perform pg_temp.check_eq('a filing with no entity is the company''s own',
    v_row.company, 'Setiausaha Akaun Sdn Bhd');

  perform public.fs_set_entity(v_f, v_e1);
  select * into v_row from public.report_fs_deadlines(v_org, 400)
   where filing_id = v_f;
  perform pg_temp.check_eq('and once named, it is the client''s',
    v_row.company, 'Klien Pertama Sdn Bhd');
  perform pg_temp.check_eq('with the number SSM knows them by',
    v_row.registration_no, '202301000001');

  -- Moved to the other client, because picking the wrong one is the
  -- mistake this is for.
  perform public.fs_set_entity(v_f, v_e2);
  perform pg_temp.check_eq('and it can be corrected',
    (select name from public.corp_entities c
      join public.fs_filings f on f.corp_entity_id = c.id
     where f.id = v_f), 'Klien Kedua Sdn Bhd');

  -- Another firm's company is not this firm's client.
  begin
    perform public.fs_set_entity(v_f, v_alien);
    raise exception 'FAIL: accounts were tied to another firm''s company';
  exception when sqlstate 'P0002' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and only to a company of this firm',
    v_said like '%No such company%');

  -- The deadline board is the practice's question, not the filing's.
  perform pg_temp.check_true('the filing is on the board',
    (select count(*)::integer from public.report_fs_deadlines(v_org, 400))
      >= 1);
  -- Lodged accounts leave it: the board is what is still owed.
  update public.fs_filings
     set directors_approval_date = v_today - 30, circulated_on = v_today - 25
   where id = v_f;
  perform public.fs_freeze(v_f);
  perform public.fs_lodge(v_f, 'MBRS-2026-9', v_today - 1);
  select count(*)::integer into v_n
    from public.report_fs_deadlines(v_org, 400) where filing_id = v_f;
  perform pg_temp.check_eq('and leaves it once lodged', v_n, 0);

  -- Lodged accounts are evidence: what they were filed for is closed.
  begin
    perform public.fs_set_entity(v_f, v_e1);
    raise exception 'FAIL: a lodged filing was re-pointed at another company';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a lodged filing does not change company',
    v_said like '%cannot change afterwards%');

  -- An outsider reads none of it and sets none of it.
  perform pg_temp.sign_in_as(v_out);
  begin
    perform count(*) from public.report_fs_deadlines(v_org, 400);
    raise exception 'FAIL: an outsider read the deadline board';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('not your company',
    v_said like '%Not your company%');

  begin
    perform public.fs_set_entity(pg_temp.so_filing(v_org, v_fye - 400), v_e1);
    raise exception 'FAIL: an outsider set the company on a filing';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor amend the accounts',
    v_said like '%not permitted to amend these accounts%');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform pg_temp.sign_out();
end $$;

-- =====================================================================
-- Six months from a year end that is the end of a month
-- =====================================================================
-- `fs_deadlines` computes the s.258 circulation deadline as
-- `fy_end + interval '6 months'`, and the rest of this file never looks
-- at it: its dates are all `v_today - N`, which is almost never the end
-- of a month. So the one piece of arithmetic in the function that can
-- move silently had no assertion on it, and `CLAUDE.md` is explicit
-- that an SSM deadline needs a test that would fail if the number
-- moved.
--
-- Nothing is wrong. Postgres clamps a month-add that overshoots, and
-- every answer below is either exact or one day early, which is the
-- safe direction for a filing deadline. What is pinned is that
-- behaviour, against a future rewrite as `+ 180 days` or a
-- `date_trunc`, either of which would move real deadlines for real
-- companies without failing anything.
--
-- The four year ends are the ones Malaysian companies actually use.
do $$
declare
  v_org uuid;
  v_f   uuid;
  r     record;
begin
  v_org := pg_temp.test_org('Tarikh Akhir Bulan Sdn Bhd');

  -- 31 December: the common case, and no clamping -- June has 30 days
  -- and the 31st does not exist, so this lands on the 30th.
  v_f := pg_temp.so_filing(v_org, date '2026-12-31');
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_eq('a 31 December year end circulates by 30 June',
    r.circulate_by::text, '2027-06-30');

  -- 31 August into February, which is short. Clamped to the 28th.
  v_f := pg_temp.so_filing(v_org, date '2026-08-31');
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_eq('a 31 August year end clamps to 28 February',
    r.circulate_by::text, '2027-02-28');

  -- And the same year end in a leap year, which is the assertion that
  -- would catch a hand-rolled month-add that hard-codes 28.
  v_f := pg_temp.so_filing(v_org, date '2027-08-31');
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_eq('and to 29 February in a leap year',
    r.circulate_by::text, '2028-02-29');

  -- 30 June into December, which is long. No clamping happens, so the
  -- answer is the 30th and not the month end -- correct, and the one
  -- most likely to be "corrected" by somebody who assumes a month-end
  -- year end must give a month-end deadline.
  v_f := pg_temp.so_filing(v_org, date '2026-06-30');
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_eq(
    'a 30 June year end circulates by 30 December, not the 31st',
    r.circulate_by::text, '2026-12-30');

  -- 31 March, the other common one.
  v_f := pg_temp.so_filing(v_org, date '2026-03-31');
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_eq('and a 31 March year end by 30 September',
    r.circulate_by::text, '2026-09-30');

  -- Deliberately five stated dates and no "and in general" clause. The
  -- mechanical version of this assertion would have to express the rule
  -- as `fy_end + interval '6 months'`, which is the function's own
  -- expression -- it would agree with any rewrite of it, including a
  -- wrong one, and pass by restating the implementation. Dates worked
  -- out by hand from the Act are the only thing that does not.
end $$;

rollback;
