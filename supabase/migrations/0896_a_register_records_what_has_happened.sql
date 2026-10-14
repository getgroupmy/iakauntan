-- =====================================================================
-- iAkauntan :: 0896 a register records what has happened
--
-- The secretarial sheets will not pick a day after today for the dates
-- a register records -- a movement of shares, an officer's appointment
-- and cessation and the consent and declaration behind it, a charge's
-- creation, lodgement and satisfaction, a beneficial owner's
-- notification and cessation, a person's date of birth. The tables took
-- any day, and the client writes these rows directly.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: a share allotment, a director's appointment, a
-- charge and a beneficial owner each dated a month ahead, all stored;
-- `corp_register_of_members` read that day already listed the allottee
-- with the 900 shares due to be allotted next month.
--
-- Production on 14 October: eight share movements and seventeen
-- officers, none dated ahead; no charges, no beneficial owners.
--
-- Answered "refuse what the sheets refuse": one trigger function,
-- `app.corp_not_after_today`, given the columns of each table the
-- sheets cap, as `column=Label` arguments, refuses any of them after
-- today in Malaysia, on insert and when one of them is written.
-- Other dates on these tables are left as they were -- a filing's due
-- date, a licence's expiry, and the like, are rightly ahead.
-- =====================================================================

create or replace function app.corp_not_after_today()
returns trigger
language plpgsql
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_arg text;
  v_day date;
begin
  foreach v_arg in array tg_argv loop
    v_day := (v_row ->> split_part(v_arg, '=', 1))::date;
    if v_day > app.today() then
      raise exception
        '"%" is %, a day that has not come yet. A register records what '
        'has happened: enter it on the day it does.',
        split_part(v_arg, '=', 2), to_char(v_day, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function app.corp_not_after_today() from public, anon, authenticated;

comment on function app.corp_not_after_today() is
  'Refuses a date after today (Malaysia) in the columns named by the '
  'trigger''s arguments, each `column=Label`: a register records what '
  'has happened. 0896.';

create trigger not_after_today
  before insert or update of event_date on public.corp_share_events
  for each row execute function app.corp_not_after_today(
    'event_date=Date of the movement');

create trigger not_after_today
  before insert or update of appointed_on, consent_received_on,
    declaration_received_on, resigned_on on public.corp_officers
  for each row execute function app.corp_not_after_today(
    'appointed_on=Appointed on', 'consent_received_on=Consent received',
    'declaration_received_on=Declaration received', 'resigned_on=Ceased on');

create trigger not_after_today
  before insert or update of created_on, registered_on, satisfied_on,
    satisfaction_filed_on on public.corp_charges
  for each row execute function app.corp_not_after_today(
    'created_on=Created on', 'registered_on=Lodged with SSM',
    'satisfied_on=Satisfied on', 'satisfaction_filed_on=Memorandum filed');

create trigger not_after_today
  before insert or update of notified_on, ceased_on on public.corp_beneficial_owners
  for each row execute function app.corp_not_after_today(
    'notified_on=Notified on', 'ceased_on=Ceased on');

create trigger not_after_today
  before insert or update of date_of_birth on public.corp_persons
  for each row execute function app.corp_not_after_today(
    'date_of_birth=Date of birth');
