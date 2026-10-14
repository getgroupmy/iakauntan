-- =====================================================================
-- iAkauntan :: 0899 a director is a person of eighteen
--
-- Companies Act 2016, s.196(1)(a): a director shall be a natural person
-- who has attained the age of eighteen years. Neither the officer sheet
-- nor the register asked.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: a person born ten years earlier, and a company
-- (`corp_persons.kind = 'corporate'`), each appointed director and
-- stored.
--
-- Production on 14 October: eight directors, all individuals; none has
-- a date of birth recorded, so none can be shown to be under eighteen.
--
-- Answered "refuse both": `app.corp_director_is_eligible`, before an
-- officer row is written as a director or an alternate director (on
-- insert, and when its person, role or appointment date changes),
-- refuses a person who is not an individual, and one whose recorded
-- date of birth leaves them short of eighteen on the day of
-- appointment. With no date of birth on file the age cannot be read,
-- and is let through as before. It reads the person as the definer, so
-- a row hidden from the writer cannot let an appointment past.
--
-- A correction to a person's date of birth or kind is not refused for
-- what it reveals about an appointment already made: a register is
-- corrected, not kept wrong to stay consistent.
-- =====================================================================

create or replace function app.corp_director_is_eligible()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_p public.corp_persons;
begin
  if new.role not in ('director', 'alternate_director') then
    return new;
  end if;
  select * into v_p from public.corp_persons where id = new.person_id;
  if v_p.id is null then
    return new;  -- the foreign key answers that
  end if;
  if v_p.kind <> 'individual' then
    raise exception
      '% is a company, and a director is a natural person (Companies Act '
      '2016, s.196(1)(a)). A company sits on a board through the '
      'individual it names.', v_p.full_name
      using errcode = '23514';
  end if;
  if v_p.date_of_birth + interval '18 years' > new.appointed_on then
    raise exception
      '% was born on % and is not yet eighteen on %. A director must have '
      'attained eighteen (Companies Act 2016, s.196(1)(a)).',
      v_p.full_name, to_char(v_p.date_of_birth, 'DD Mon YYYY'),
      to_char(new.appointed_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.corp_director_is_eligible() from public, anon, authenticated;

comment on function app.corp_director_is_eligible() is
  'Companies Act 2016 s.196(1)(a): a director (or alternate) is an '
  'individual who has attained eighteen on the day of appointment, where '
  'a date of birth is recorded. 0899.';

create trigger director_is_eligible
  before insert or update of person_id, role, appointed_on
  on public.corp_officers
  for each row execute function app.corp_director_is_eligible();
