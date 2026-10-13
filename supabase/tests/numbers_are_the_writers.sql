-- =====================================================================
-- iAkauntan :: only a writer takes a number (0877)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/numbers_are_the_writers.sql
--
-- `next_document_number` advances the company's counters, and a number
-- given out and not used is a gap in the sequence. A View Only member
-- and an auditor write nothing and took invoice numbers. A writer takes
-- any; HR and payroll the employee's and the payroll run's; anybody in
-- the company her own claim's and leave's. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_nw (org uuid, viewer uuid, auditor uuid, clerk uuid,
  hr uuid, staff uuid);
grant select on t_nw to authenticated;

do $$
declare r t_nw;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Nombor Siri Sdn Bhd', array['hr', 'payroll']);
  r.viewer  := pg_temp.another_user('lihat@nombor.test');
  r.auditor := pg_temp.another_user('audit@nombor.test');
  r.clerk   := pg_temp.another_user('kerani@nombor.test');
  r.hr      := pg_temp.another_user('hr@nombor.test');
  r.staff   := pg_temp.another_user('staf@nombor.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.viewer, 'viewer', 'active'),
         (r.org, r.auditor, 'auditor', 'active'),
         (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.hr, 'hr_manager', 'active'),
         (r.org, r.staff, 'employee', 'active');
  insert into t_nw select r.*;
end $$;

create or replace function pg_temp.number_for(p_org uuid, p_type text)
returns text language plpgsql as $$
begin
  return public.next_document_number(p_org, p_type);
exception when insufficient_privilege then
  return 'refused';
end $$;

create temporary table t_got (who text, invoice text, employee text,
  payroll_run text, claim text, leave text);
grant all on t_got to authenticated;

create or replace function pg_temp.take_all(p_who text) returns void
language sql as $$
  insert into t_got
  select p_who,
         pg_temp.number_for(org, 'invoice'), pg_temp.number_for(org, 'employee'),
         pg_temp.number_for(org, 'payroll_run'),
         pg_temp.number_for(org, 'expense_claim'),
         pg_temp.number_for(org, 'leave_request')
    from t_nw;
$$;

select pg_temp.sign_in_as((select viewer from t_nw));
set local role authenticated;
select pg_temp.take_all('viewer');
reset role;
select pg_temp.sign_in_as((select auditor from t_nw));
set local role authenticated;
select pg_temp.take_all('auditor');
reset role;
select pg_temp.sign_in_as((select clerk from t_nw));
set local role authenticated;
select pg_temp.take_all('clerk');
reset role;
select pg_temp.sign_in_as((select hr from t_nw));
set local role authenticated;
select pg_temp.take_all('hr');
reset role;
select pg_temp.sign_in_as((select staff from t_nw));
set local role authenticated;
select pg_temp.take_all('staff');
reset role;

create or replace function pg_temp.took(p_who text) returns text
language sql as $$
  select concat_ws(' / ',
           case when invoice = 'refused' then 'no invoice' else 'invoice' end,
           case when employee = 'refused' then 'no employee' else 'employee' end,
           case when payroll_run = 'refused' then 'no payroll run' else 'payroll run' end,
           case when claim = 'refused' then 'no claim' else 'claim' end,
           case when leave = 'refused' then 'no leave' else 'leave' end)
    from t_got where who = p_who;
$$;

do $$
begin
  perform pg_temp.check_eq('a View Only member takes no number but a claim''s and a leave''s',
    pg_temp.took('viewer'), 'no invoice / no employee / no payroll run / claim / leave');
  perform pg_temp.check_eq('nor does an auditor',
    pg_temp.took('auditor'), 'no invoice / no employee / no payroll run / claim / leave');
  perform pg_temp.check_eq('a clerk, who writes, takes any',
    pg_temp.took('clerk'), 'invoice / employee / payroll run / claim / leave');
  perform pg_temp.check_eq('the HR manager takes the employee''s and the payroll run''s, and no invoice',
    pg_temp.took('hr'), 'no invoice / employee / payroll run / claim / leave');
  perform pg_temp.check_eq('an employee takes only a claim''s and a leave''s',
    pg_temp.took('staff'), 'no invoice / no employee / no payroll run / claim / leave');
  perform pg_temp.check_eq('so the invoice sequence has no gap: the clerk''s was the first',
    (select invoice from t_got where who = 'clerk'),
    'INV-' || extract(year from pg_temp.today())::int || '-00001');
end $$;

-- Somebody outside the company takes nothing of it, as before.
select pg_temp.sign_in_as(pg_temp.another_user('orang@luar.test'));
set local role authenticated;
select pg_temp.take_all('outsider');
reset role;

do $$
begin
  perform pg_temp.check_eq('and a stranger takes none at all',
    pg_temp.took('outsider'), 'no invoice / no employee / no payroll run / no claim / no leave');
end $$;

rollback;
