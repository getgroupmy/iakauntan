-- =====================================================================
-- iAkauntan :: a minute says what could have happened (0820)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/corp_resolution_checks.sql
--
-- The resolution screen refused four things the table took -- a written
-- resolution passed at a meeting, an effect before the passing, a
-- signature with no date, more votes than people present -- and the
-- table took negative votes as well. `0820` puts the five on the table.
-- Asked as the owner, with the role `authenticated`, which is how the
-- screen writes the minute book.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cr (org uuid, e uuid, a uuid, b uuid, c uuid);
grant select on t_cr to authenticated;

do $$
declare
  r t_cr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Minit Betul Sdn Bhd', array['secretarial']);
  insert into public.corp_entities
    (org_id, name, registration_no, entity_type, incorporated_on,
     financial_year_end_day, financial_year_end_month, registered_office)
  values (r.org, 'Minit Sdn Bhd', '202401022222', 'sdn_bhd',
          date '2024-03-12', 31, 12, 'Level 8, Menara ABC, KL')
  returning id into r.e;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Director One', '900101011111') returning id into r.a;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Director Two', '900202022222') returning id into r.b;
  insert into public.corp_persons (org_id, kind, full_name, nric)
  values (r.org, 'individual', 'Director Three', '900303033333') returning id into r.c;
  insert into t_cr select r.*;
end $$;

create or replace function pg_temp.cr_insert(p_set text)
returns text language sql as $$
  select format(
    $q$insert into public.corp_resolutions (org_id, entity_id, title, kind,
         passed_on, effective_on, meeting_held, present_person_ids,
         in_favour, against, abstained, is_signed, signed_on)
       select org, e, 'Resolution', %s from t_cr$q$, p_set);
$$;
grant execute on function pg_temp.cr_insert(text) to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_cr;
begin
  select * into d from t_cr;
  perform pg_temp.check_eq('the owner writes the minute book as a client',
    current_user, 'authenticated');

  -- What the screen refused, and the table took.
  perform pg_temp.check_refused('a written resolution is not passed at a meeting',
    pg_temp.cr_insert($s$'written', date '2026-03-01', null, true, null, null, null, null, false, null$s$),
    '%corp_resolutions_written_not_at_meeting_ck%', '23514');
  perform pg_temp.check_refused('nor takes effect before it was passed',
    pg_temp.cr_insert($s$'board', date '2026-03-10', date '2026-03-09', true, null, null, null, null, false, null$s$),
    '%corp_resolutions_effective_after_passed_ck%', '23514');
  perform pg_temp.check_refused('a signed minute says when',
    pg_temp.cr_insert($s$'board', date '2026-03-10', null, true, null, null, null, null, true, null$s$),
    '%corp_resolutions_signed_is_dated_ck%', '23514');
  perform pg_temp.check_refused('three votes do not come from two people present',
    pg_temp.cr_insert(format($s$'board', date '2026-03-10', null, true, array[%L, %L]::uuid[], 2, 1, null, false, null$s$, d.a, d.b)),
    '%corp_resolutions_votes_fit_the_present_ck%', '23514');
  perform pg_temp.check_refused('nor do abstentions push past them',
    pg_temp.cr_insert(format($s$'board', date '2026-03-10', null, true, array[%L, %L]::uuid[], 1, 1, 1, false, null$s$, d.a, d.b)),
    '%corp_resolutions_votes_fit_the_present_ck%', '23514');
  perform pg_temp.check_refused('and nobody casts fewer than no votes',
    pg_temp.cr_insert(format($s$'board', date '2026-03-10', null, true, array[%L, %L, %L]::uuid[], 3, -1, null, false, null$s$, d.a, d.b, d.c)),
    '%corp_resolutions_votes_not_negative_ck%', '23514');
  perform pg_temp.check_refused('nor abstains fewer than none',
    pg_temp.cr_insert($s$'board', date '2026-03-10', null, false, null, null, null, -2, false, null$s$),
    '%corp_resolutions_votes_not_negative_ck%', '23514');
  perform pg_temp.check_eq('so none of them is in the minute book',
    (select count(*)::integer from public.corp_resolutions where org_id = d.org), 0);

  -- What could have happened is still written.
  execute pg_temp.cr_insert(format($s$'members_special', date '2026-03-10', date '2026-03-10', true, array[%L, %L, %L]::uuid[], 2, 1, null, true, date '2026-03-11'$s$, d.a, d.b, d.c));
  execute pg_temp.cr_insert($s$'written', date '2026-03-12', date '2026-03-15', false, null, null, null, null, false, null$s$);
  execute pg_temp.cr_insert($s$'board', date '2026-03-13', null, true, null, 5, 0, null, false, null$s$);
  -- The list of those present sent empty rather than left out: a count
  -- with nobody listed either way is not a count that exceeds them.
  execute pg_temp.cr_insert($s$'board', date '2026-03-14', null, true, '{}'::uuid[], 4, 1, null, false, null$s$);
  execute pg_temp.cr_insert($s$'board', null, null, false, null, null, null, null, false, null$s$);
  perform pg_temp.check_eq(
    'a counted meeting, a circulated one, a count with nobody listed -- left out or sent empty -- and a bare draft are all minuted',
    (select count(*)::integer from public.corp_resolutions where org_id = d.org), 5);

  -- And an existing minute is held to it on the way through, too.
  perform pg_temp.check_refused('a minute is not edited into one that could not have happened',
    format($q$update public.corp_resolutions set against = 2
               where org_id = %L and kind = 'members_special'$q$, d.org),
    '%corp_resolutions_votes_fit_the_present_ck%', '23514');
end $$;

reset role;

rollback;
