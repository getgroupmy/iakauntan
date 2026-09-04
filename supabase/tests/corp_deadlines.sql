-- =====================================================================
-- iAkauntan :: what SSM is still owed, and by whom
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/corp_deadlines.sql
--
-- `public.corp_upcoming_filings` is the one list a company secretary
-- works from. It is also the only place in the product where a silent
-- wrong answer costs money to somebody who did nothing wrong: a filing
-- that drops off this list is a filing nobody makes, and s.68 of the
-- Companies Act 2016 carries a fine and a daily default penalty on top.
--
-- A mutation sweep of it killed 9 of 29 one-line mutants. `secretarial.
-- sql` pins the two DATES the Act gives -- thirty days from the
-- anniversary, two hundred and ten from the year end -- and pins that a
-- Sdn Bhd holds no AGM. What nothing pinned was WHO IS ON THE LIST AT
-- ALL: a company struck off the register, a client the practice has
-- resigned from, a company with no incorporation date on file, a
-- financial year that ended before the company existed, or a filing
-- somebody has already marked approved or not applicable.
--
-- Every block below names the mutant it kills.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.sec_org(p_name text default 'Sec Deadlines Firm')
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_org, 'secretarial', true) on conflict do nothing;
  return v_org;
end;
$$;

-- Today as the Act reads it. Every expectation in this file is anchored
-- on the same day the function is, so nothing here depends on when CI
-- happens to run.
create or replace function pg_temp.kl_today() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Kuala_Lumpur')::date;
$$;

-- =====================================================================
-- 1. Who is on the list at all
-- =====================================================================
do $$
declare
  v_org      uuid;
  v_live     uuid;
  v_struck   uuid;
  v_resigned uuid;
  v_nodate   uuid;
  v_nofye    uuid;
  v_llp      uuid;
begin
  v_org := pg_temp.sec_org();

  -- The control. Incorporated four years ago, so there are anniversaries
  -- outstanding and a year end behind us.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Hidup Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '4 years')::date, 31, 12)
  returning id into v_live;

  perform pg_temp.check_true('a live company owes filings',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_live) > 0);

  -- MUTANT: dropping `e.status in ('incorporated', 'dormant')`. A company
  -- struck off the register under s.549 has no annual return to make,
  -- and a list that says otherwise is asking a secretary to lodge
  -- something SSM will reject.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    status, financial_year_end_day, financial_year_end_month)
  values (v_org, 'Dipotong Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '4 years')::date, 'struck_off', 31, 12)
  returning id into v_struck;

  perform pg_temp.check_eq('a struck-off company owes nothing',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_struck), 0);

  -- MUTANT: dropping `e.disengaged_on is null`. This is the practice's
  -- own record, not SSM's: the company still exists and still owes the
  -- return, but this firm is no longer its secretary and cannot lodge
  -- anything for it. Leaving it on the list is how a firm bills for
  -- work it has no authority to do.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    disengaged_on, financial_year_end_day, financial_year_end_month)
  values (v_org, 'Bekas Klien Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '4 years')::date,
          (pg_temp.kl_today() - interval '3 months')::date, 31, 12)
  returning id into v_resigned;

  perform pg_temp.check_eq('a client the firm has resigned from owes nothing here',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_resigned), 0);

  -- MUTANT: dropping `e.incorporated_on is not null`. A company being
  -- set up has no incorporation date yet. The anniversary series counts
  -- years from it, so with a null the whole series is null and the row
  -- is a filing with no date on it.
  insert into public.corp_entities (org_id, name, entity_type,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Belum Diperbadankan Sdn Bhd', 'sdn_bhd', 31, 12)
  returning id into v_nodate;

  perform pg_temp.check_eq('a company not yet incorporated owes no annual return',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_nodate and f.filing_type = 'annual_return'), 0);

  -- MUTANT: dropping `e.financial_year_end_month is not null`. Same
  -- shape on the other series: `app.corp_fye` returns null without a
  -- month, and a financial statement filing with a null year end is a
  -- deadline nobody can meet.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Tiada Tahun Kewangan Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '4 years')::date)
  returning id into v_nofye;

  perform pg_temp.check_eq('a company with no year end owes no financial statements',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_nofye
        and f.filing_type in ('financial_statements',
                              'financial_statements_public', 'agm')), 0);
  perform pg_temp.check_true('but it still owes its annual return',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_nofye and f.filing_type = 'annual_return') > 0);

  -- MUTANT: dropping `e.entity_type = any (t.applies_to)` on the
  -- ANNIVERSARY join. `secretarial.sql` covers the year-end join, by way
  -- of the AGM a Sdn Bhd does not hold; nothing covered this one. An LLP
  -- files an annual declaration with SSM under the LLP Act 2012, not a
  -- s.68 annual return under the Companies Act, and telling a firm
  -- otherwise is teaching the wrong statute.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Perkongsian Liabiliti Terhad PLT', 'llp',
          (pg_temp.kl_today() - interval '4 years')::date, 31, 12)
  returning id into v_llp;

  perform pg_temp.check_eq('an LLP owes no Companies Act annual return',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_llp and f.filing_type = 'annual_return'), 0);

  raise notice 'ok   who is on the list at all';
end $$;

-- =====================================================================
-- 2. The anniversary series: every year still owed, and no others
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_e     uuid;
  v_born  date;
  v_years integer;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.sec_org('Sec Anniversaries Firm');

  -- Incorporated four years and a day ago, so four anniversaries have
  -- passed, the fifth is a year away, and none of them has been lodged.
  v_born := (pg_temp.kl_today() - interval '4 years' - interval '1 day')::date;
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Empat Tahun Sdn Bhd', 'sdn_bhd', v_born)
  returning id into v_e;

  -- MUTANTS: starting the series at the current year rather than at 1
  -- (a company two years behind is shown one filing and told nothing
  -- about the other), and stopping it a year short (this year's
  -- anniversary, the one actually in hand, missing).
  --
  -- The ordinary window, because the point is the SERIES and not the
  -- window: the fifth anniversary is a year off and outside it, and the
  -- four that have passed have no lower bound to fall off.
  select count(*) into v_years
    from public.corp_upcoming_filings(v_org, 120) f
   where f.entity_id = v_e and f.filing_type = 'annual_return';
  perform pg_temp.check_eq('every anniversary still owed is listed', v_years, 4);

  perform pg_temp.check_eq('the oldest is the first anniversary',
    (select min(f.trigger_date)::text
       from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_e and f.filing_type = 'annual_return'),
    (v_born + interval '1 year')::date::text);
  perform pg_temp.check_eq('and the newest is the one just past',
    (select max(f.trigger_date)::text
       from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_e and f.filing_type = 'annual_return'),
    (v_born + interval '4 years')::date::text);

  -- MUTANT: dropping `c.trigger_date > e.incorporated_on`. The day a
  -- company is incorporated is not an anniversary of anything, and a
  -- return is not owed on it.
  perform pg_temp.check_eq('the incorporation date is not itself a filing',
    (select count(*) from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_e and f.trigger_date <= v_born), 0);

  -- MUTANT: `order by c.name` alone. The list is a work queue; the
  -- oldest deadline is the one that matters, and sorting by company
  -- name buries a return two years overdue underneath a form due in
  -- November.
  --
  -- Two more companies, named so that alphabetical order is the exact
  -- reverse of deadline order. With one company on the books the two
  -- orderings agree by accident, which is how this mutant survived the
  -- first pass of this file.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Zulu Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '2 days' - interval '30 days'
                - interval '1 year')::date);
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Alfa Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() + interval '60 days' - interval '30 days'
                - interval '1 year')::date);

  perform pg_temp.check_true('the list comes back oldest deadline first',
    (select bool_and(ok) from (
       select f.due_date >= lag(f.due_date) over (order by f.ordinality) as ok
         from public.corp_upcoming_filings(v_org, 400)
              with ordinality f
     ) s where ok is not null));
  perform pg_temp.check_true('and not alphabetically',
    (select f.entity_name from public.corp_upcoming_filings(v_org, 400) f
      limit 1) <> 'Alfa Sdn Bhd');

  raise notice 'ok   every anniversary still owed, and no others';
end $$;

-- =====================================================================
-- 3. The year-end series, and the year before this one
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_old  uuid;
  v_new  uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.sec_org('Sec Year Ends Firm');

  -- A company with a 31 December year end, incorporated long ago. Last
  -- year's financial statements are 210 days after last 31 December,
  -- which is in July of this year -- past for most of the year and
  -- ahead of us in the first half.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Disember Sdn Bhd', 'sdn_bhd', date '2010-06-01', 31, 12)
  returning id into v_old;

  -- MUTANT: starting the year-end series at the current year rather
  -- than the one before. The financial statements a secretary is
  -- actually working on in any given January to July are LAST year's.
  perform pg_temp.check_true('last year''s financial statements are on the list',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_old and f.filing_type = 'financial_statements'
        and f.trigger_date
            = make_date(extract(year from pg_temp.kl_today())::int - 1, 12, 31)
    ) = 1);

  -- MUTANT: dropping `d.trigger_date >= e.incorporated_on`. A company
  -- incorporated this year has no year end behind it, and a financial
  -- statement filing for a year it did not exist in is a deadline
  -- against nothing.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Baharu Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '20 days')::date, 31, 12)
  returning id into v_new;

  perform pg_temp.check_eq('a company incorporated this month owes nothing yet',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_new
        and f.trigger_date < (pg_temp.kl_today() - interval '20 days')::date), 0);

  -- MUTANT: dropping the status filter on the YEAR-END branch. It is a
  -- separate copy of the same condition, and the sweep killed only the
  -- anniversary one.
  update public.corp_entities set status = 'dissolved' where id = v_old;
  perform pg_temp.check_eq('a dissolved company owes no financial statements',
    (select count(*) from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_old), 0);
  update public.corp_entities set status = 'incorporated' where id = v_old;

  -- MUTANT: `and c.due_date >= v_today - 365` applied to everything, or
  -- to nothing.
  --
  -- The two kinds are treated differently ON PURPOSE and each half of
  -- that needs a case. An annual return two years overdue is not less
  -- overdue for being old; a financial statement from four years ago is
  -- history, and putting it on this week's list is how a real deadline
  -- gets lost among dead ones.
  perform pg_temp.check_eq('financial statements from long ago are not a task',
    (select count(*) from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_old and f.filing_type = 'financial_statements'
        and f.trigger_date < make_date(
              extract(year from pg_temp.kl_today())::int - 2, 1, 1)), 0);

  raise notice 'ok   the year-end series and the year before this one';
end $$;

-- =====================================================================
-- 4. A filing already dealt with, and one that is not
-- =====================================================================
do $$
declare
  v_org    uuid;
  v_a      uuid;
  v_b      uuid;
  v_trig   date;
  v_filing uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.sec_org('Sec Lodged Firm');

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Satu Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '3 years' - interval '1 day')::date)
  returning id into v_a;
  -- A second company incorporated on the very same day, so its filings
  -- carry the same trigger dates.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Dua Sdn Bhd', 'sdn_bhd',
          (pg_temp.kl_today() - interval '3 years' - interval '1 day')::date)
  returning id into v_b;

  select min(f.trigger_date) into v_trig
    from public.corp_upcoming_filings(v_org, 120) f
   where f.entity_id = v_a and f.filing_type = 'annual_return';

  perform pg_temp.check_eq('both companies owe three returns each',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.filing_type = 'annual_return'), 6);

  -- MUTANT: matching an open filing on `f.filing_type = c.code` without
  -- `f.entity_id = c.id`. Two companies on the same firm's books with
  -- the same incorporation date is not a contrivance -- a batch of
  -- shelf companies is incorporated on one day -- and one of them being
  -- lodged must not sign off the other.
  --
  -- MUTANT: matching without `f.trigger_date = c.trigger_date`. Lodging
  -- the 2024 return would sign off 2023 and 2025 with it.
  v_filing := public.corp_open_filing(v_a, 'annual_return', v_trig);
  perform public.corp_mark_lodged(v_filing, pg_temp.kl_today(), 'AR/1', 150);

  perform pg_temp.check_eq('the lodged return comes off this company''s list',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_a and f.filing_type = 'annual_return'), 2);
  perform pg_temp.check_eq('and the other company still owes all three',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_b and f.filing_type = 'annual_return'), 3);
  perform pg_temp.check_eq('and only the year lodged came off',
    (select count(*) from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_a and f.filing_type = 'annual_return'
        and f.trigger_date = v_trig), 0);

  -- MUTANTS: `not in ('lodged')` alone, and `not in ('lodged',
  -- 'approved')`. Three statuses take a filing off the list and only
  -- one of them was pinned.
  --
  -- `approved` is the practice's own sign-off before lodgement; a
  -- filing sitting in that state is somebody else's job now, not this
  -- list's. `not_applicable` is the secretary saying the Act does not
  -- require this one -- a dormant company exempted from audit, say --
  -- and a list that keeps arguing is a list people stop reading.
  select min(f.trigger_date) into v_trig
    from public.corp_upcoming_filings(v_org, 120) f
   where f.entity_id = v_b and f.filing_type = 'annual_return';
  v_filing := public.corp_open_filing(v_b, 'annual_return', v_trig);
  update public.corp_filings set status = 'approved' where id = v_filing;

  perform pg_temp.check_eq('an approved filing is off the list',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_b and f.filing_type = 'annual_return'), 2);

  update public.corp_filings set status = 'not_applicable' where id = v_filing;
  perform pg_temp.check_eq('so is one the secretary says does not apply',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_b and f.filing_type = 'annual_return'), 2);

  -- And a filing that has merely been STARTED is still owed, which is
  -- the positive control: a rule that takes everything off the list is
  -- no better than one that takes nothing off it.
  update public.corp_filings set status = 'in_preparation' where id = v_filing;
  perform pg_temp.check_eq('but one merely started is still owed',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_b and f.filing_type = 'annual_return'), 3);

  -- MUTANT: `coalesce(f.status, 'due')` -- the status of a filing that
  -- HAS been opened replaced by the date-derived one, and vice versa.
  perform pg_temp.check_eq('an opened filing reports its own status',
    (select f.status::text from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_b and f.filing_type = 'annual_return'
        and f.trigger_date = v_trig), 'in_preparation');
  perform pg_temp.check_true('and carries the filing''s id',
    (select f.filing_id from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_b and f.filing_type = 'annual_return'
        and f.trigger_date = v_trig) = v_filing);

  raise notice 'ok   a filing already dealt with, and one that is not';
end $$;

-- =====================================================================
-- 5. Due, not due, and the window
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_over  uuid;
  v_today uuid;
  v_soon  uuid;
  v_far   uuid;
  v_hundred uuid;
  v_kl    date := pg_temp.kl_today();
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.sec_org('Sec Window Firm');

  -- Four companies whose FIRST annual return falls due on four chosen
  -- days. The return is due thirty days after the first anniversary, so
  -- an incorporation date of (target - 30 days - 1 year) lands it.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Lewat Sdn Bhd', 'sdn_bhd',
          (v_kl - interval '1 day' - interval '30 days'
                - interval '1 year')::date)
  returning id into v_over;

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Hari Ini Sdn Bhd', 'sdn_bhd',
          (v_kl - interval '30 days' - interval '1 year')::date)
  returning id into v_today;

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Sepuluh Hari Sdn Bhd', 'sdn_bhd',
          (v_kl + interval '10 days' - interval '30 days'
                - interval '1 year')::date)
  returning id into v_soon;

  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Tahun Depan Sdn Bhd', 'sdn_bhd',
          (v_kl + interval '200 days' - interval '30 days'
                - interval '1 year')::date)
  returning id into v_far;

  -- MUTANT: `case when c.due_date <= v_today then 'due'`. A filing due
  -- TODAY is not late. Told it is, a secretary lodging on the last
  -- lawful day is told they have already defaulted.
  perform pg_temp.check_eq('a return due today is not yet overdue',
    (select f.status::text from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_today and f.filing_type = 'annual_return'
      order by f.due_date limit 1), 'not_due');
  perform pg_temp.check_eq('one due yesterday is',
    (select f.status::text from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_over and f.filing_type = 'annual_return'
      order by f.due_date limit 1), 'due');
  perform pg_temp.check_eq('and one due in ten days is not',
    (select f.status::text from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_soon and f.filing_type = 'annual_return'
      order by f.due_date limit 1), 'not_due');

  -- MUTANT: dropping the window, and shrinking its default. The list is
  -- what a secretary looks at this quarter; a hundred and twenty days
  -- is the four months the screen is written around, and a fortnight
  -- would hide everything that needs starting now.
  perform pg_temp.check_eq('a filing two hundred days out is outside the window',
    (select count(*) from public.corp_upcoming_filings(v_org, 120) f
      where f.entity_id = v_far and f.filing_type = 'annual_return'), 0);
  perform pg_temp.check_eq('and outside the default window too',
    (select count(*) from public.corp_upcoming_filings(v_org) f
      where f.entity_id = v_far and f.filing_type = 'annual_return'), 0);
  perform pg_temp.check_eq('but inside a wider one that is asked for',
    (select count(*) from public.corp_upcoming_filings(v_org, 300) f
      where f.entity_id = v_far and f.filing_type = 'annual_return'), 1);
  -- MUTANT: `coalesce(p_within_days, 14)`. The default has to be
  -- pinned at something a fortnight does NOT reach, or shrinking it
  -- changes nothing -- which is how that mutant survived a first pass
  -- that only asked about a filing ten days out.
  --
  -- A hundred days is the shape the screen is written around: an annual
  -- return needs the accounts, the accounts need the directors, and
  -- three months is what a secretary actually works to.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Seratus Hari Sdn Bhd', 'sdn_bhd',
          (v_kl + interval '100 days' - interval '30 days'
                - interval '1 year')::date)
  returning id into v_hundred;

  perform pg_temp.check_eq('the default window reaches a hundred days out',
    (select count(*) from public.corp_upcoming_filings(v_org) f
      where f.entity_id = v_hundred and f.filing_type = 'annual_return'), 1);

  -- And the same when the window is passed as null rather than omitted.
  -- The parameter's SQL DEFAULT and the `coalesce` inside the function
  -- are two different guards against two different callers: omitting
  -- the argument takes the default, and PostgREST passing a JSON null
  -- takes the coalesce. Only the first was reachable from the Flutter
  -- client, whose `withinDays` is a non-nullable int -- so the second
  -- had nothing asserting it, and a mutant shrinking it to a fortnight
  -- lived.
  perform pg_temp.check_eq('and so does an explicitly null one',
    (select count(*) from public.corp_upcoming_filings(v_org, null) f
      where f.entity_id = v_hundred and f.filing_type = 'annual_return'), 1);
  perform pg_temp.check_eq('which is still a window, not everything',
    (select count(*) from public.corp_upcoming_filings(v_org, null) f
      where f.entity_id = v_far and f.filing_type = 'annual_return'), 0);
  perform pg_temp.check_eq('and something ten days out too',
    (select count(*) from public.corp_upcoming_filings(v_org) f
      where f.entity_id = v_soon and f.filing_type = 'annual_return'), 1);

  raise notice 'ok   due, not due, and the window';
end $$;

-- =====================================================================
-- 6. Today is a Malaysian day
-- =====================================================================
--
-- MUTANT: `v_today := current_date`. `current_date` follows the SESSION
-- time zone; the Act follows Malaysia. Between midnight and eight in
-- the morning in Kuala Lumpur a server left on UTC is still on
-- yesterday, and a return due yesterday is reported as due today --
-- which is the difference between "you have defaulted" and "you have
-- until close of business".
--
-- Asserting that needs a session time zone whose date differs from
-- Malaysia's, and which one does depends on the hour. Kuala Lumpur is
-- UTC+8. Etc/GMT+12 is twenty hours behind it and differs except in the
-- last four hours of a Malaysian day; Pacific/Kiritimati is six hours
-- ahead and differs in the last six. Between them one always differs,
-- whatever the hour CI runs at, so this is a real assertion at every
-- hour rather than one that quietly passes for most of the day.
-- =====================================================================
do $$
declare
  v_org   uuid;
  v_e     uuid;
  v_kl    date := pg_temp.kl_today();
  v_tz    text;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.sec_org('Sec Timezone Firm');

  v_tz := case
    when (now() at time zone 'Etc/GMT+12')::date <> v_kl then 'Etc/GMT+12'
    else 'Pacific/Kiritimati' end;
  perform pg_temp.check_true('one of the two really does differ from Malaysia',
    (now() at time zone v_tz)::date <> v_kl);

  -- Due yesterday in Malaysia, and so overdue in Malaysia.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on)
  values (v_org, 'Zon Waktu Sdn Bhd', 'sdn_bhd',
          (v_kl - interval '1 day' - interval '30 days'
                - interval '1 year')::date)
  returning id into v_e;

  execute format('set local timezone = %L', v_tz);
  perform pg_temp.check_true('the session really is somewhere else',
    current_date <> v_kl);

  perform pg_temp.check_eq(
    'the deadline is read on Malaysian time, not the server''s',
    (select f.status::text from public.corp_upcoming_filings(v_org, 400) f
      where f.entity_id = v_e and f.filing_type = 'annual_return'
      order by f.due_date limit 1), 'due');

  reset timezone;
  raise notice 'ok   today is a Malaysian day';
end $$;

-- =====================================================================
-- 7. The two edges of the series
-- =====================================================================
do $$
declare
  v_org  uuid;
  v_same uuid;
  v_dec  uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.sec_org('Sec Series Edges Firm');

  -- MUTANT: dropping `c.trigger_date > e.incorporated_on`.
  --
  -- A company incorporated on the last day of last year, whose first
  -- financial year end is recorded as that same day. The anniversary
  -- series can never reach the incorporation date -- it starts a year
  -- after it -- so this outer condition bites on ONE shape only: a year
  -- end equal to the day the company came into existence. A financial
  -- year of zero days is a data-entry artefact, not a filing, and a
  -- deadline computed from it is a deadline for a set of accounts that
  -- cannot exist.
  --
  -- The inner year-end guard is `>=` and would keep it. This one is
  -- `>` and does not, which is the whole difference between the two and
  -- the only place it shows.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Hari Sama Sdn Bhd', 'sdn_bhd',
          make_date(extract(year from pg_temp.kl_today())::int - 1, 12, 31),
          31, 12)
  returning id into v_same;

  perform pg_temp.check_eq('a year end on the day of incorporation is not a filing',
    (select count(*) from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_same
        and f.trigger_date = make_date(
              extract(year from pg_temp.kl_today())::int - 1, 12, 31)), 0);
  perform pg_temp.check_true('though the company is otherwise on the list',
    (select count(*) from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_same) > 0);

  -- THE RULE THAT MAKES ONE SURVIVING MUTANT EQUIVALENT.
  --
  -- `and (c.kind = 'anniversary' or c.due_date >= v_today - 365)` has
  -- two halves. The first is asserted above: an annual return two years
  -- overdue stays on the list. The second cannot be reached at all
  -- while the year-end series runs over only the current year and the
  -- one before it -- the oldest year end it can produce is 31 December
  -- of last year, and 210 days after that is inside the 365-day window
  -- for all but a few weeks at the very end of a year.
  --
  -- So a mutant deleting the 365-day half survives, and it survives
  -- BECAUSE OF THE SERIES rather than because the clause is doing
  -- nothing. Widen the series and it becomes live again. What is
  -- asserted here is therefore the series bound itself, so that a
  -- future widening has to come past this file.
  insert into public.corp_entities (org_id, name, entity_type, incorporated_on,
    financial_year_end_day, financial_year_end_month)
  values (v_org, 'Lama Sdn Bhd', 'sdn_bhd', date '2005-01-01', 31, 12)
  returning id into v_dec;

  perform pg_temp.check_eq(
    'the year-end series reaches back exactly one calendar year',
    (select min(f.trigger_date)::text
       from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_dec
        and f.filing_type in ('financial_statements',
                              'financial_statements_public', 'agm')),
    make_date(extract(year from pg_temp.kl_today())::int - 1, 12, 31)::text);
  perform pg_temp.check_eq('and no further',
    (select count(*) from public.corp_upcoming_filings(v_org, 3650) f
      where f.entity_id = v_dec
        and f.filing_type in ('financial_statements',
                              'financial_statements_public', 'agm')
        and f.trigger_date < make_date(
              extract(year from pg_temp.kl_today())::int - 1, 1, 1)), 0);

  raise notice 'ok   the two edges of the series';
end $$;

rollback;
