-- =====================================================================
-- iAkauntan :: the filing itself — opened, lodged, and dated
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/corp_filing_shapes.sql
--
-- `corp_deadlines.sql` covers WHO IS ON THE LIST and `secretarial.sql`
-- pins the two dates the Act gives. A sweep of 69 one-line mutants over
-- the seven functions behind the statutory calendar — `app.corp_fye`,
-- `corp_open_filing`, `corp_mark_lodged`, `corp_upcoming_filings`,
-- `fs_deadlines`, `app.fs_lodge_by` and `report_fs_deadlines` — killed
-- 50. What lived was of three kinds.
--
-- THE FINANCIAL YEAR END ITSELF. `app.corp_fye` is four nested date
-- functions turning "our year ends on the 31st of February" into a date
-- that exists, and it had never been called directly by anything. Every
-- test reaches it through `corp_upcoming_filings` with a year end of 31
-- December, where `least(31, days-in-month)` and `greatest(31,
-- days-in-month)` give the same answer and a missing day defaults to a
-- month end that is also the 31st. A company whose year ends in
-- February is the case that tells them apart.
--
-- WHAT A REFUSAL SAYS. Four guards on `corp_open_filing` and five on
-- `corp_mark_lodged` are each followed by another guard that raises for
-- a different reason, so deleting the first one still refused and the
-- assertion still passed. A filing that does not exist was refused with
-- "not permitted", which sends a secretary to ask for permission she
-- already has. Every refusal here is asserted on its MESSAGE.
--
-- AND WHAT HAPPENS TO A FILING THAT IS ALREADY DONE. Opening a filing
-- twice is ordinary — the same event gets noticed again — and the
-- second call must not put a lodged return back into preparation. That
-- was never asserted, and nor was the scope of the lodgement: marking
-- one filing lodged and marking every filing in the practice lodged
-- read identically to a fixture holding one filing.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cf_org(p_name text)
returns uuid language sql as $$
  select pg_temp.test_org(p_name, array['secretarial', 'mbrs']);
$$;

create or replace function pg_temp.cf_entity(
  p_org uuid, p_name text, p_type text, p_inc date,
  p_fye_month integer default null, p_fye_day integer default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.corp_entities
    (org_id, name, entity_type, status, incorporated_on,
     financial_year_end_month, financial_year_end_day)
  values (p_org, p_name, p_type::app.corp_entity_type, 'incorporated',
          p_inc, p_fye_month, p_fye_day)
  returning id into v;
  return v;
end $$;

create or replace function pg_temp.kl_now() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Kuala_Lumpur')::date;
$$;

-- =====================================================================
-- 1. The financial year end, asked directly
-- =====================================================================
--
-- Nothing had ever called this. It is reached through
-- `corp_upcoming_filings`, where every fixture uses 31 December — the
-- one date on which `least(day, days-in-month)` and `greatest(...)`
-- agree, and on which a missing day and a day of 31 are the same day.
do $$
declare
  v_org uuid := pg_temp.cf_org('Tahun Kewangan Sdn Bhd');
  v_none uuid; v_feb uuid; v_noday uuid; v_jun uuid;
  v_e public.corp_entities;
begin
  v_none  := pg_temp.cf_entity(v_org, 'No Year End Sdn Bhd', 'sdn_bhd',
                               date '2020-01-01', null, null);
  v_feb   := pg_temp.cf_entity(v_org, 'February Sdn Bhd', 'sdn_bhd',
                               date '2020-01-01', 2, 31);
  v_noday := pg_temp.cf_entity(v_org, 'Month Only Sdn Bhd', 'sdn_bhd',
                               date '2020-01-01', 6, null);
  v_jun   := pg_temp.cf_entity(v_org, 'June Sdn Bhd', 'sdn_bhd',
                               date '2020-01-01', 6, 30);

  select * into v_e from public.corp_entities where id = v_none;
  perform pg_temp.check_true(
    'a company that has not told us its year end has no year end -- '
    'guessing one puts a statutory deadline in front of somebody for a '
    'date they never gave',
    app.corp_fye(v_e, 2026) is null);

  -- The thirty-first of February. Somebody types 31 because most months
  -- have one, and the register has to hold a date that exists.
  select * into v_e from public.corp_entities where id = v_feb;
  perform pg_temp.check_eq('a year end of 31 February is the 28th',
    app.corp_fye(v_e, 2026)::text, '2026-02-28');
  perform pg_temp.check_eq('and the 29th in a leap year',
    app.corp_fye(v_e, 2024)::text, '2024-02-29');

  -- A month with no day is the END of that month, not the start of it.
  -- Half a year out, on the deadline that follows it.
  select * into v_e from public.corp_entities where id = v_noday;
  perform pg_temp.check_eq('a month with no day named ends on its last day',
    app.corp_fye(v_e, 2026)::text, '2026-06-30');

  select * into v_e from public.corp_entities where id = v_jun;
  perform pg_temp.check_eq('and a day that exists is left alone',
    app.corp_fye(v_e, 2026)::text, '2026-06-30');
end $$;

-- =====================================================================
-- 2. Opening a filing, and opening it again
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.cf_org('Buka Failkan Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid;
  v_e uuid; v_f uuid; v_again uuid;
  v_today date := pg_temp.kl_now();
begin
  v_e := pg_temp.cf_entity(v_org, 'Buka Sdn Bhd', 'sdn_bhd',
                           date '2020-01-15', 12, 31);

  -- WHAT EACH REFUSAL SAYS. Three guards, one after another, and each
  -- of the first two is hidden by the next: an entity that is not there
  -- has a null `org_id`, so `can_write(null)` is false and the caller
  -- was told they lacked permission for a company that does not exist.
  perform pg_temp.check_refused('an entity that is not there says so',
    format('select public.corp_open_filing(%L, %L, %L)',
           gen_random_uuid(), 'annual_return', v_today),
    '%Entity not found%');

  perform pg_temp.check_refused('and a filing type that is not there',
    format('select public.corp_open_filing(%L, %L, %L)',
           v_e, 'form_49', v_today),
    '%Unknown filing type%');

  -- A form the Act does not require of this kind of company.
  perform pg_temp.check_refused(
    'an AGM is not something a private company holds',
    format('select public.corp_open_filing(%L, %L, %L)', v_e, 'agm', v_today),
    '%does not apply to a%');

  -- And somebody who may read the practice's files but not act for it.
  v_clerk := pg_temp.another_user('kerani@filing.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now())
  on conflict (org_id, user_id) do update
    set role = 'viewer', status = 'active';
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused(
    'opening a filing is not a reading decision',
    format('select public.corp_open_filing(%L, %L, %L)',
           v_e, 'change_registered_office', v_today),
    '%Not permitted to open a filing%');
  perform pg_temp.sign_in_as(v_owner);

  -- THE FALLBACK NOBODY HAS EVER REACHED. Every filing type in the
  -- catalogue names its days, so `coalesce(days_allowed, 30)` has never
  -- had a null to fall back from. A form added to the catalogue without
  -- one gets a month, not the day it was triggered.
  insert into public.corp_filing_types
    (code, name, statute_ref, trigger_kind, days_allowed, applies_to)
  values ('unnamed_form', 'A form with no period named', 'CA 2016',
          'event', null, array['sdn_bhd']::app.corp_entity_type[]);

  v_f := public.corp_open_filing(v_e, 'unnamed_form', v_today - 3);
  perform pg_temp.check_eq(
    'a form whose period nobody has filled in is due in thirty days, '
    'not on the day it was triggered',
    (select f.due_date::text from public.corp_filings f where f.id = v_f),
    (v_today + 27)::text);

  -- OPENING IT AGAIN. The same event gets noticed twice — a document
  -- arrives, somebody re-runs the routine — and the second call must
  -- not undo the first one's outcome.
  v_f := public.corp_open_filing(v_e, 'change_registered_office',
                                 v_today - 5);
  perform public.corp_mark_lodged(v_f, v_today - 1, 'SSM-OPEN-1', 60);
  v_again := public.corp_open_filing(v_e, 'change_registered_office',
                                     v_today - 5);
  perform pg_temp.check_eq('reopening finds the same filing', v_again, v_f);
  perform pg_temp.check_eq(
    'and a filing already lodged stays lodged -- putting it back in '
    'preparation is how a practice files the same return twice',
    (select f.status::text from public.corp_filings f where f.id = v_f),
    'lodged');

  -- The same for a filing the client has approved but nobody has sent.
  v_f := public.corp_open_filing(v_e, 'change_of_officers', v_today - 5);
  update public.corp_filings set status = 'approved' where id = v_f;
  v_again := public.corp_open_filing(v_e, 'change_of_officers', v_today - 5);
  perform pg_temp.check_eq('an approved filing stays approved',
    (select f.status::text from public.corp_filings f where f.id = v_f),
    'approved');

  -- The control: one that is genuinely still in hand goes back into
  -- preparation, which is what the `else` arm is for.
  v_f := public.corp_open_filing(v_e, 'beneficial_ownership', v_today - 5);
  update public.corp_filings set status = 'awaiting_signature' where id = v_f;
  v_again := public.corp_open_filing(v_e, 'beneficial_ownership',
                                     v_today - 5);
  perform pg_temp.check_eq('while one still in hand goes back to the start',
    (select f.status::text from public.corp_filings f where f.id = v_f),
    'in_preparation');
end $$;

-- =====================================================================
-- 3. Recording a lodgement
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.cf_org('Rekod Failkan Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid;
  v_e uuid; v_one uuid; v_two uuid;
  v_today date := pg_temp.kl_now();
begin
  v_e := pg_temp.cf_entity(v_org, 'Rekod Sdn Bhd', 'sdn_bhd',
                           date '2020-01-15', 12, 31);
  v_one := public.corp_open_filing(v_e, 'change_registered_office',
                                   v_today - 5);
  v_two := public.corp_open_filing(v_e, 'change_of_officers', v_today - 5);

  -- Again, what the refusal says rather than that there was one. A
  -- filing that is not there has a null `org_id`, and the permission
  -- guard behind it answers for a company that does not exist.
  perform pg_temp.check_refused('a filing that is not there says so',
    format('select public.corp_mark_lodged(%L, %L)', gen_random_uuid(),
           v_today),
    '%No such filing%');

  v_clerk := pg_temp.another_user('kerani@lodge.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now())
  on conflict (org_id, user_id) do update
    set role = 'viewer', status = 'active';
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused(
    'recording a lodgement is not a reading decision',
    format('select public.corp_mark_lodged(%L, %L)', v_one, v_today),
    '%not permitted to record a lodgement%');
  perform pg_temp.sign_in_as(v_owner);

  -- NO DATE MEANS TODAY, and today is Malaysia's. A secretary who
  -- presses the button without typing a date has lodged it now.
  perform public.corp_mark_lodged(v_one);
  perform pg_temp.check_eq('a lodgement with no date given is dated today',
    (select f.lodged_on::text from public.corp_filings f where f.id = v_one),
    v_today::text);

  -- AND ONLY THAT ONE. The other filing on the same entity, opened on
  -- the same day, is untouched: a practice that marks one return lodged
  -- has not lodged the rest of them.
  perform pg_temp.check_eq('the other filing is still in preparation',
    (select f.status::text from public.corp_filings f where f.id = v_two),
    'in_preparation');
  perform pg_temp.check_true('and has no lodgement date',
    (select f.lodged_on is null from public.corp_filings f where f.id = v_two));

  -- A filing the client has APPROVED is refused for the same reason a
  -- lodged one is, and `decline_and_lodge.sql` only ever tries the
  -- lodged one.
  update public.corp_filings set status = 'approved' where id = v_two;
  perform pg_temp.check_refused(
    'an approved filing is not lodged over either',
    format('select public.corp_mark_lodged(%L, %L)', v_two, v_today),
    '%write over the reference%');
end $$;

-- =====================================================================
-- 4. What stays on the list, and what falls off it
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.cf_org('Senarai Sdn Bhd');
  v_new uuid; v_pub uuid; v_old uuid; v_same uuid;
  v_today date := pg_temp.kl_now();
  v_year integer := extract(year from pg_temp.kl_now())::integer;
  v_f uuid; v_n integer;
begin
  -- ------------------------------------------------------------------
  -- A year end before the company existed
  -- ------------------------------------------------------------------
  -- Incorporated this January, year end 31 December. The generator
  -- offers last year's 31 December as well, and the company did not
  -- exist for it.
  v_new := pg_temp.cf_entity(v_org, 'Baru Sdn Bhd', 'sdn_bhd',
                             make_date(v_year, 1, 30), 12, 31);

  perform pg_temp.check_eq(
    'a financial year that ended before the company was incorporated is '
    'not a filing it owes',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_new and u.filing_type = 'financial_statements'
        and u.trigger_date = make_date(v_year - 1, 12, 31)), 0);
  perform pg_temp.check_eq('while the one it did live through is',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_new and u.filing_type = 'financial_statements'
        and u.trigger_date = make_date(v_year, 12, 31)), 1);

  -- THE BOUNDARY, AND A MASKING PAIR. Two guards say this: `year_ends`
  -- keeps `trigger_date >= incorporated_on`, and the outer `where`
  -- keeps `trigger_date > incorporated_on`. The second is strictly the
  -- stronger, so deleting the first changes no answer -- see
  -- docs/unreachable.md. What separates them is a company whose year
  -- end falls ON the day it was incorporated, and only the outer guard
  -- decides that one: a company incorporated on 30 June with a 30 June
  -- year end did not trade for a year that lasted no days.
  v_same := pg_temp.cf_entity(v_org, 'Sama Hari Sdn Bhd', 'sdn_bhd',
                              make_date(v_year - 1, 6, 30), 6, 30);
  perform pg_temp.check_eq(
    'a year end falling on the day of incorporation is not a year',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_same and u.filing_type = 'financial_statements'
        and u.trigger_date = make_date(v_year - 1, 6, 30)), 0);
  perform pg_temp.check_eq('while the year after it is',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_same and u.filing_type = 'financial_statements'
        and u.trigger_date = make_date(v_year, 6, 30)), 1);

  -- ------------------------------------------------------------------
  -- Two forms falling due on one date
  -- ------------------------------------------------------------------
  -- A public company owes both an AGM and its financial statements off
  -- the SAME year end, so the two filings share a trigger date and are
  -- told apart only by their code. Lodging one must not take the other
  -- off the list.
  v_pub := pg_temp.cf_entity(v_org, 'Awam Berhad', 'berhad',
                             date '2015-06-01', 12, 31);

  perform pg_temp.check_eq('a public company owes an AGM',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_pub and u.filing_type = 'agm'
        and u.trigger_date = make_date(v_year - 1, 12, 31)), 1);
  perform pg_temp.check_eq('and financial statements off the same year end',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_pub
        and u.filing_type = 'financial_statements_public'
        and u.trigger_date = make_date(v_year - 1, 12, 31)), 1);

  v_f := public.corp_open_filing(v_pub, 'agm', make_date(v_year - 1, 12, 31));
  perform public.corp_mark_lodged(v_f, v_today - 1, 'SSM-AGM', 100);

  perform pg_temp.check_eq('lodging the AGM takes the AGM off the list',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_pub and u.filing_type = 'agm'
        and u.trigger_date = make_date(v_year - 1, 12, 31)), 0);
  perform pg_temp.check_eq(
    'and leaves the accounts on it -- two forms, one date, and only the '
    'code tells them apart',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_pub
        and u.filing_type = 'financial_statements_public'
        and u.trigger_date = make_date(v_year - 1, 12, 31)), 1);

  -- ------------------------------------------------------------------
  -- A year end whose deadline has been past for over a year
  -- ------------------------------------------------------------------
  -- The rule is that an anniversary filing NEVER falls off — something
  -- two years overdue is not less overdue for being old — while the
  -- year-end kinds keep a twelve-month window, because a financial
  -- statement from four years ago is history rather than a task.
  --
  -- The Act's own 180 and 210 days cannot construct that: the generator
  -- only offers last year's year end and this year's, and with a
  -- deadline that far out last year's lands INSIDE the window on most
  -- days of the year. So the fixture adds a form whose deadline
  -- precedes its own year end by a day, on a company whose year ends on
  -- 1 January. It is not a real form; what is being asserted is the
  -- report's floor.
  --
  -- Those two together are what make this hold on EVERY day of the
  -- year rather than on the days the calendar happens to allow. Last
  -- year's deadline is 31 December of the year before that, which is
  -- always more than a year ago; this year's is 31 December of last
  -- year, which is the last day of the twelve-month window and so
  -- always inside it.
  insert into public.corp_filing_types
    (code, name, statute_ref, trigger_kind, days_allowed, applies_to)
  values ('backdated_form', 'A form due before its own year end', 'CA 2016',
          'fye', -1, array['sdn_bhd']::app.corp_entity_type[]);

  v_old := pg_temp.cf_entity(v_org, 'Lama Sdn Bhd', 'sdn_bhd',
                             date '2015-03-01', 1, 1);

  perform pg_temp.check_eq(
    'a year-end filing whose deadline passed more than a year ago is off '
    'the list: it is history, not a task',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_old and u.filing_type = 'backdated_form'
        and u.trigger_date = make_date(v_year - 1, 1, 1)), 0);
  perform pg_temp.check_eq('while this year''s is still on it',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_old and u.filing_type = 'backdated_form'
        and u.trigger_date = make_date(v_year, 1, 1)), 1);

  -- And the other half of the same clause, which `corp_deadlines.sql`
  -- states in prose: the annual return has no floor at all.
  perform pg_temp.check_true(
    'an annual return from years back is still owed, however old',
    (select count(*) from public.corp_upcoming_filings(v_org, 3000) u
      where u.entity_id = v_old and u.filing_type = 'annual_return'
        and u.due_date < v_today - 365) > 0);
end $$;

-- =====================================================================
-- 5. Two rules these lean on rather than enforce
-- =====================================================================
do $$
begin
  -- `fs_deadlines` wraps its `entity_type = 'bhd'` test in
  -- `coalesce(..., false)`. The coalesce can never fire: the column is
  -- NOT NULL and `fs_filings.org_id` is a foreign key to it, so the
  -- lookup always finds a row and always answers true or false. The
  -- rule is asserted instead of the coalesce.
  perform pg_temp.check_eq('a company always has a kind',
    (select is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'organizations'
        and column_name = 'entity_type'), 'NO');
  perform pg_temp.check_true('and a filing always has a company',
    exists (select 1 from pg_constraint
             where conrelid = 'public.fs_filings'::regclass
               and contype = 'f'
               and confrelid = 'public.organizations'::regclass));

  -- `corp_upcoming_filings` gathers `trigger_kind in ('fye', 'agm')`.
  -- No filing type in the catalogue has kind 'agm' — the annual general
  -- meeting is filed under 'fye', because it is the year end that
  -- triggers it. The 'agm' arm is dead, and saying so here is cheaper
  -- than a reader working it out from the catalogue.
  perform pg_temp.check_eq(
    'no filing type is triggered by an AGM -- the AGM is triggered by '
    'the year end, and is filed under it',
    (select count(*) from public.corp_filing_types
      where trigger_kind = 'agm'), 0);
  perform pg_temp.check_true('while the year end triggers several',
    (select count(*) from public.corp_filing_types
      where trigger_kind = 'fye') > 1);
end $$;

rollback;
