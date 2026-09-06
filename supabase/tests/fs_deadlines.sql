-- =====================================================================
-- iAkauntan :: when the accounts are due, and to whom
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fs_deadlines.sql
--
-- Three functions carry the s.258 and s.259 clock: `app.fs_lodge_by` is
-- the rule, `public.fs_deadlines` is one filing's answer, and
-- `public.report_fs_deadlines` is the list a practice works from. A
-- mutation sweep across all three killed 9 of 24 one-line mutants.
--
-- `fs_statutory_order.sql` asserts the ORDER of the three dates —
-- approved, then circulated, then lodged — and pins the thirty days
-- that run from circulation. What nothing asserted was the filing that
-- has NOT been circulated yet, which is every filing for the first six
-- months after a year end and therefore most of them: its lodgement
-- date comes from `fy_end + 6 months + 30`, and the six months in that
-- expression had no test at all. Nor did the days-left countdown, the
-- late flag, or the sentence the screen prints to say WHICH rule the
-- company is being held to -- s.258 for a private company, s.340 for a
-- public one, and a company told the wrong one is a company preparing
-- for the wrong meeting.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.fd_org(p_name text,
                                          p_type app.entity_type default 'sdn_bhd')
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  update public.organizations set entity_type = p_type where id = v_org;
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'mbrs', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end $$;

create or replace function pg_temp.fd_filing(p_org uuid, p_fy_end date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status)
  values (p_org, (p_fy_end - interval '1 year' + interval '1 day')::date,
          p_fy_end, 'mpers', 'unaudited')
  returning id into v_id;
  return v_id;
end $$;

-- =====================================================================
-- 1. The rule, on its own
-- =====================================================================
--
-- `app.fs_lodge_by` is called from two places: `fs_deadlines`, and the
-- nightly notification pass that chases a practice about the accounts
-- it has not lodged. Asserting it here rather than only through its
-- callers is deliberate -- the notification pass has no fixture of its
-- own, so the rule would otherwise be pinned only where it happens to
-- be observed.
-- =====================================================================
do $$
begin
  -- MUTANT: `interval '6 months'` -> `'3 months'`. Six months to
  -- circulate under s.258, thirty days to lodge under s.259: a filing
  -- for a 31 December year end must reach SSM by 30 July.
  perform pg_temp.check_eq('uncirculated: six months, then thirty days',
    app.fs_lodge_by(date '2026-12-31', null)::text, '2027-07-30');
  perform pg_temp.check_eq('and the same off a June year end',
    app.fs_lodge_by(date '2026-06-30', null)::text, '2027-01-29');

  -- MUTANT: `+ 30` -> `+ 14`, and the coalesce dropped in either
  -- direction. Once the accounts HAVE been circulated the clock runs
  -- from the act rather than from the entitlement, so circulating early
  -- brings the lodgement forward and does not merely permit it.
  perform pg_temp.check_eq('circulated early, the clock starts early',
    app.fs_lodge_by(date '2026-12-31', date '2027-02-01')::text,
    '2027-03-03');
  perform pg_temp.check_eq('circulated late, it starts late',
    app.fs_lodge_by(date '2026-12-31', date '2027-08-15')::text,
    '2027-09-14');

  -- February, because thirty days is thirty days and not a month.
  perform pg_temp.check_eq('thirty days is thirty days, not a calendar month',
    app.fs_lodge_by(date '2026-12-31', date '2027-01-31')::text,
    '2027-03-02');

  raise notice 'ok   the s.258 and s.259 clock';
end $$;

-- =====================================================================
-- 2. One filing's answer, and who may ask for it
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_other uuid;
  v_f     uuid;
  v_fye   date;
  r       record;
begin
  v_org := pg_temp.fd_org('Akaun Sdn Bhd');

  -- A year end six months and a fortnight back, so the filing is
  -- inside the thirty days and not yet late.
  v_fye := (app.today() - interval '6 months' - interval '14 days')::date;
  v_f := pg_temp.fd_filing(v_org, v_fye);

  select * into r from public.fs_deadlines(v_f);

  perform pg_temp.check_eq('circulate by six months after the year end',
    r.circulate_by::text, (v_fye + interval '6 months')::date::text);
  perform pg_temp.check_eq('lodge by thirty days after that',
    r.lodge_by::text, (v_fye + interval '6 months' + interval '30 days')::date::text);

  -- MUTANT: `(v_circulate + 30)` -> `+ 60`. The outside limit is the
  -- last lawful day whatever happens next: circulate on the final
  -- permitted day and thirty more is all there is.
  perform pg_temp.check_eq('and the outside limit is the two of them together',
    r.outside_limit::text, r.lodge_by::text);

  -- MUTANT: `(v_lodge - app.today())` -> `(v_circulate - app.today())`.
  -- The screen counts down to the LODGEMENT; counting down to
  -- circulation would show a filing sixteen days in hand as sixteen
  -- days overdue.
  perform pg_temp.check_eq('the countdown runs to the lodgement date',
    r.days_left::numeric, (r.lodge_by - app.today())::numeric);
  perform pg_temp.check_true('which is still ahead of us', r.days_left > 0);
  perform pg_temp.check_true('and the circulation date is behind us',
    r.circulate_by < app.today());
  perform pg_temp.check_true('so the two are not the same number',
    r.days_left <> (r.circulate_by - app.today()));

  -- MUTANT: `app.today() > v_lodge` -> `>=`. A filing lodged on its due
  -- date is lodged in time. Told otherwise, a practice reports a
  -- default that did not happen.
  --
  -- The three boundary cases below are dated from the CIRCULATION
  -- rather than from the year end, because only that arithmetic is
  -- exact: `fy_end + 6 months + 30 days` is not invertible -- subtract
  -- six months from a date in early March and add them back and you are
  -- three days out, because February is short. Circulation plus thirty
  -- days is thirty days.
  perform pg_temp.check_true('a filing inside its thirty days is not late',
    not r.is_late);

  v_f := pg_temp.fd_filing(v_org, (app.today() - interval '10 months')::date);
  update public.fs_filings set
    directors_approval_date = (app.today() - interval '40 days')::date,
    circulated_on = (app.today() - interval '30 days')::date
   where id = v_f;
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_eq('a filing due today is due today',
    r.lodge_by::text, app.today()::text);
  perform pg_temp.check_true('and is not yet late', not r.is_late);
  perform pg_temp.check_eq('with no days left, but none lost either',
    r.days_left::numeric, 0);

  update public.fs_filings set
    directors_approval_date = (app.today() - interval '41 days')::date,
    circulated_on = (app.today() - interval '31 days')::date
   where id = v_f;
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_true('one a day past its thirty is late', r.is_late);
  perform pg_temp.check_eq('and is one day past', r.days_left::numeric, -1);

  update public.fs_filings set
    directors_approval_date = (app.today() - interval '25 days')::date,
    circulated_on = (app.today() - interval '20 days')::date
   where id = v_f;
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_true('and one with ten days left is not',
    not r.is_late);
  perform pg_temp.check_eq('with ten days on the clock',
    r.days_left::numeric, 10);

  -- MUTANT: dropping `f.lodged_on is null` from the late test. Once the
  -- accounts are lodged the deadline is history; a list that keeps
  -- calling a lodged filing late is a list that never goes quiet.
  v_fye := (app.today() - interval '22 months')::date;
  v_f := pg_temp.fd_filing(v_org, v_fye);
  update public.fs_filings set
    directors_approval_date = (v_fye + interval '5 months')::date,
    circulated_on = (v_fye + interval '5 months' + interval '10 days')::date,
    lodged_on = (v_fye + interval '5 months' + interval '20 days')::date,
    status = 'lodged'
   where id = v_f;

  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_true('a filing already lodged is never late',
    not r.is_late);
  perform pg_temp.check_eq('and reports the day it was lodged',
    r.lodged_on::text,
    (v_fye + interval '5 months' + interval '20 days')::date::text);
  perform pg_temp.check_eq('with the deadline it was measured against',
    r.lodge_by::text,
    (v_fye + interval '5 months' + interval '40 days')::date::text);

  -- MUTANT: `if false then` on the not-found guard, and on the
  -- membership guard. Neither had a case.
  begin
    perform public.fs_deadlines(gen_random_uuid());
    raise exception 'FAIL: a filing that does not exist was answered';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a filing that does not exist is refused';
  end;

  perform pg_temp.allow_many_companies();
  v_other := pg_temp.fd_org('Syarikat Lain Sdn Bhd');
  perform pg_temp.sign_in_as(pg_temp.another_user('outsider@example.test'));
  begin
    perform public.fs_deadlines(v_f);
    raise exception 'FAIL: an outsider read a company''s deadlines';
  exception when sqlstate '42501' then
    raise notice 'ok   an outsider cannot read a company''s deadlines';
  end;
  perform pg_temp.sign_out();

  raise notice 'ok   one filing''s answer, and who may ask for it';
end $$;

-- =====================================================================
-- 3. Which section the company is actually held to
-- =====================================================================
--
-- The `basis` string is not decoration. It is what the screen prints to
-- tell a director WHY the date is the date, and the two sections
-- describe two different obligations: a private company CIRCULATES the
-- accounts to its members under s.258, and a public company LAYS them
-- before a general meeting under s.340. A private company told it must
-- hold an AGM is a private company convening a meeting the 2016 Act
-- abolished for it; a public company told it need only circulate is a
-- public company that misses one.
--
-- Three mutants lived here -- the branch forced each way, and the test
-- for `bhd` widened to every company -- because nothing had ever looked
-- at the sentence.
-- =====================================================================
do $$
declare
  v_priv uuid;
  v_pub  uuid;
  v_ent  uuid;
  v_f    uuid;
  r      record;
begin
  perform pg_temp.allow_many_companies();
  v_priv := pg_temp.fd_org('Persendirian Sdn Bhd', 'sdn_bhd');
  v_pub  := pg_temp.fd_org('Awam Berhad', 'bhd');
  v_ent  := pg_temp.fd_org('Perusahaan Enterprise', 'enterprise');

  v_f := pg_temp.fd_filing(v_priv, (app.today() - interval '3 months')::date);
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_true('a private company circulates under s.258',
    r.basis like '%s.258%');
  perform pg_temp.check_true('and is not told to hold a meeting',
    r.basis not like '%s.340%');
  perform pg_temp.check_true('and is told what it lodges under',
    r.basis like '%s.259%');

  v_f := pg_temp.fd_filing(v_pub, (app.today() - interval '3 months')::date);
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_true('a public company lays them at the AGM under s.340',
    r.basis like '%s.340%');
  perform pg_temp.check_true('and is not told merely to circulate',
    r.basis not like '%s.258%');
  perform pg_temp.check_true('and lodges under the same s.259',
    r.basis like '%s.259%');

  -- Everything that is not a Berhad takes the private company's rule,
  -- which is what `o.entity_type = 'bhd'` says and a widened test would
  -- not: an enterprise is not a company at all.
  v_f := pg_temp.fd_filing(v_ent, (app.today() - interval '3 months')::date);
  select * into r from public.fs_deadlines(v_f);
  perform pg_temp.check_true('anything that is not a Berhad takes s.258',
    r.basis like '%s.258%');

  -- The dates are the same either way; only the reason differs. Stated
  -- so that a future divergence has to come past this line.
  perform pg_temp.check_eq('and the deadline itself is the same either way',
    (select d.lodge_by::text from public.fs_deadlines(v_f) d),
    (select d.lodge_by::text
       from public.fs_deadlines(
         (select id from public.fs_filings where org_id = v_pub limit 1)) d));

  raise notice 'ok   which section the company is held to';
end $$;

-- =====================================================================
-- 4. The list a practice works from
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_other uuid;
  v_soon  uuid;
  v_far   uuid;
  v_done  uuid;
  v_zulu  uuid;
  v_alfa  uuid;
  v_own   uuid;
  v_tie   uuid;
  i       integer;
  n       integer;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.fd_org('Firma Akaun Sdn Bhd');

  -- Due in twenty days: inside a sixty day window and outside a seven
  -- day one, which is the pair the default has to tell apart.
  --
  -- MUTANT: `coalesce(p_within_days, 60)` -> 7, and the window dropped
  -- entirely.
  -- The six months come off FIRST, and the days after.
  --
  -- Written the other way round -- today, plus the days, minus thirty,
  -- minus six months -- two fixtures a day apart can land on the same
  -- year end, because subtracting six months from the 29th, 30th or
  -- 31st of a month clamps to the end of a shorter one. On 7 September
  -- 2026 the twenty-day fixture (28 August) and the twenty-one-day one
  -- (29 August) both became 28 February, and `fs_filings` has a unique
  -- key on (org_id, fy_end): the file died on a duplicate key, on that
  -- day only, with nothing wrong in the code it tests. Taking the
  -- months off today first leaves only exact day arithmetic between
  -- the fixtures, which cannot collide.
  v_soon := pg_temp.fd_filing(v_org,
    (app.today() - interval '6 months' - interval '30 days'
                 + interval '20 days')::date);
  -- Due in a hundred and twenty days: outside both.
  v_far := pg_temp.fd_filing(v_org,
    (app.today() - interval '6 months' - interval '30 days'
                 + interval '120 days')::date);

  perform pg_temp.check_eq('a filing due in twenty days is on the list',
    (select count(*) from public.report_fs_deadlines(v_org) f
      where f.filing_id = v_soon), 1);
  perform pg_temp.check_eq('one due in four months is not',
    (select count(*) from public.report_fs_deadlines(v_org) f
      where f.filing_id = v_far), 0);
  perform pg_temp.check_eq('unless a wider window is asked for',
    (select count(*) from public.report_fs_deadlines(v_org, 200) f
      where f.filing_id = v_far), 1);
  -- The coalesce and the parameter's own DEFAULT are two guards against
  -- two callers; an explicit null takes the second.
  perform pg_temp.check_eq('and a null window is the default, not no window',
    (select count(*) from public.report_fs_deadlines(v_org, null) f
      where f.filing_id = v_far), 0);
  perform pg_temp.check_eq('which still reaches twenty days out',
    (select count(*) from public.report_fs_deadlines(v_org, null) f
      where f.filing_id = v_soon), 1);

  -- MUTANT: `f.status <> 'lodged'` -> true.
  v_done := pg_temp.fd_filing(v_org,
    (app.today() - interval '6 months' - interval '30 days'
                 + interval '21 days')::date);
  update public.fs_filings set status = 'lodged',
    lodged_on = app.today() where id = v_done;
  perform pg_temp.check_eq('a filing already lodged is off the list',
    (select count(*) from public.report_fs_deadlines(v_org) f
      where f.filing_id = v_done), 0);

  -- MUTANT: `where f.org_id = p_org_id` -> true. Another practice's
  -- accounts on this practice's list is a disclosure, not a bug in a
  -- report.
  v_other := pg_temp.fd_org('Firma Lain Sdn Bhd');
  perform pg_temp.fd_filing(v_other,
    (app.today() - interval '6 months' - interval '30 days'
                 + interval '20 days')::date);
  perform pg_temp.check_eq('and another company''s filings are not on it',
    (select count(*) from public.report_fs_deadlines(v_org) f
      join public.fs_filings x on x.id = f.filing_id
      where x.org_id <> v_org), 0);

  -- MUTANT: `not app.has_module(p_org_id, 'mbrs')` -> false. The module
  -- guard is the only thing between this report and a company that has
  -- not bought it.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'mbrs';
  begin
    perform public.report_fs_deadlines(v_org);
    raise exception 'FAIL: a company without the module read the report';
  exception when sqlstate '42501' then
    raise notice 'ok   the report needs the module it belongs to';
  end;
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'mbrs';

  -- MUTANT: `order by coalesce(e.name, o.name)` alone, and ordering by
  -- something that is not the displayed name at all. The list is a work
  -- queue; the nearest deadline is the one that matters.
  v_zulu := pg_temp.fd_filing(v_org,
    (app.today() - interval '6 months' - interval '30 days'
                 + interval '5 days')::date);
  v_alfa := pg_temp.fd_filing(v_org,
    (app.today() - interval '6 months' - interval '30 days'
                 + interval '50 days')::date);
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Zulu Sdn Bhd', 'sdn_bhd', date '2015-01-01')
  returning id into v_own;
  update public.fs_filings set corp_entity_id = v_own where id = v_zulu;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Alfa Sdn Bhd', 'sdn_bhd', date '2015-01-01')
  returning id into v_own;
  update public.fs_filings set corp_entity_id = v_own where id = v_alfa;

  perform pg_temp.check_true('the list comes back nearest deadline first',
    (select bool_and(ok) from (
       select f.lodge_by >= lag(f.lodge_by) over (order by f.ordinality) as ok
         from public.report_fs_deadlines(v_org, 200) with ordinality f
     ) s where ok is not null));
  perform pg_temp.check_eq('and not alphabetically',
    (select f.company from public.report_fs_deadlines(v_org, 200) f
      limit 1), 'Zulu Sdn Bhd');

  -- MUTANT: the second sort key replaced by something that is not the
  -- displayed name. It is a tie-break, so it only shows where two
  -- filings share a deadline -- which is not a corner case at all: a
  -- practice's clients mostly have a 31 December year end, so most of
  -- this list is ties, and within a day it has to read alphabetically
  -- or it reads as nothing.
  --
  -- Two filings with different year ends and the same circulation date
  -- have the same deadline, which is how two of them get there while
  -- one year end per company still holds.
  -- Five of them, because the tie-break has to be pinned against an
  -- ordering that is ARBITRARY rather than merely different: sorting by
  -- the row's uuid puts two companies in the right order half the time
  -- and five in the right order once in a hundred and twenty.
  for i in 1..5 loop
    v_tie := pg_temp.fd_filing(v_org,
      (app.today() - make_interval(months => 29 + i))::date);
    update public.fs_filings set
      directors_approval_date = (app.today() - interval '25 days')::date,
      circulated_on = (app.today() - interval '20 days')::date
     where id = v_tie;
    insert into public.corp_entities
      (org_id, name, entity_type, incorporated_on)
    values (v_org,
            (array['Alfa','Bravo','Charlie','Delta','Echo'])[i]
              || ' Tied Sdn Bhd',
            'sdn_bhd', date '2015-01-01')
    returning id into v_own;
    update public.fs_filings set corp_entity_id = v_own where id = v_tie;
  end loop;

  perform pg_temp.check_eq('filings due the same day read alphabetically',
    (select string_agg(f.company, ', ' order by f.ordinality)
       from public.report_fs_deadlines(v_org, 200) with ordinality f
      where f.company like '%Tied Sdn Bhd'),
    'Alfa Tied Sdn Bhd, Bravo Tied Sdn Bhd, Charlie Tied Sdn Bhd, '
    'Delta Tied Sdn Bhd, Echo Tied Sdn Bhd');

  -- MUTANT: `coalesce(e.name, o.name)` -> `e.name`. A company keeping
  -- its own books has no `corp_entities` row and its accounts are still
  -- its accounts; a row on this list with no name on it is a row nobody
  -- can act on.
  select count(*) into n from public.report_fs_deadlines(v_org, 200) f
   where f.company is null;
  perform pg_temp.check_eq('every row on the list is named', n, 0);
  perform pg_temp.check_true('including the practice''s own books',
    (select f.company from public.report_fs_deadlines(v_org, 200) f
      where f.filing_id = v_soon) = 'Firma Akaun Sdn Bhd');

  raise notice 'ok   the list a practice works from';
end $$;

rollback;
