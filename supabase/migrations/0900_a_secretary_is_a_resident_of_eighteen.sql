-- =====================================================================
-- iAkauntan :: 0900 a secretary is a resident of eighteen
--
-- Companies Act 2016, s.235: a company secretary is a natural person of
-- at least eighteen whose principal or only place of residence is in
-- Malaysia. `0899` held a director to s.196(1)(a); nothing held the
-- secretary to anything.
--
-- Measured on 14 October 2026, locally, as the owner with the role
-- `authenticated`: a person born ten years earlier, and a company, each
-- appointed secretary and stored.
--
-- Production on 14 October: six secretaries, all individuals recorded
-- as resident in Malaysia; none has a date of birth on file.
--
-- Answered "individual, 18, resident": the eligibility trigger `0899`
-- added now asks the same of a secretary, and one thing more -- a person
-- recorded as not resident in Malaysia (`is_resident_in_malaysia`) is
-- refused. Licensing and membership of a prescribed body are left as
-- they were: the licence columns are free text, and nothing reads them
-- as a rule.
--
-- The function and its trigger are renamed for what they now cover,
-- `app.corp_officer_is_eligible` and `officer_is_eligible`. A director's
-- refusals read exactly as they did.
-- =====================================================================

alter function app.corp_director_is_eligible() rename to corp_officer_is_eligible;
alter trigger director_is_eligible on public.corp_officers rename to officer_is_eligible;

create or replace function app.corp_officer_is_eligible()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $$
declare
  v_p public.corp_persons;
begin
  if new.role not in ('director', 'alternate_director', 'secretary') then
    return new;
  end if;
  select * into v_p from public.corp_persons where id = new.person_id;
  if v_p.id is null then
    return new;  -- the foreign key answers that
  end if;

  if new.role = 'secretary' then
    -- 0900: s.235.
    if v_p.kind <> 'individual' then
      raise exception
        '% is a company, and a secretary is a natural person (Companies '
        'Act 2016, s.235).', v_p.full_name
        using errcode = '23514';
    end if;
    if v_p.date_of_birth + interval '18 years' > new.appointed_on then
      raise exception
        '% was born on % and is not yet eighteen on %. A secretary must be '
        'at least eighteen (Companies Act 2016, s.235).',
        v_p.full_name, to_char(v_p.date_of_birth, 'DD Mon YYYY'),
        to_char(new.appointed_on, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
    if not v_p.is_resident_in_malaysia then
      raise exception
        '% is recorded as not resident in Malaysia, and a secretary''s '
        'principal or only place of residence is in Malaysia (Companies '
        'Act 2016, s.235).', v_p.full_name
        using errcode = '23514';
    end if;
    return new;
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

revoke all on function app.corp_officer_is_eligible() from public, anon, authenticated;

comment on function app.corp_officer_is_eligible() is
  'Companies Act 2016: a director or alternate (s.196(1)(a)) is an '
  'individual of eighteen on the day of appointment; a secretary (s.235) '
  'is an individual of eighteen recorded as resident in Malaysia. An age '
  'is read only where a date of birth is recorded. 0899, 0900.';
