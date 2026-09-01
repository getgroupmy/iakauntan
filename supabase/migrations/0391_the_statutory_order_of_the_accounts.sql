-- =====================================================================
-- iAkauntan :: the statutory order of the accounts
--
-- `fs_filings` carries three dates that describe one sequence the
-- Companies Act 2016 lays down:
--
--   * `directors_approval_date` — s.251(1): the accounts are approved by
--     the board and signed by two directors;
--   * `circulated_on` — s.258(1): sent to every member within six months
--     of the financial year end;
--   * `lodged_on` — s.259(1): lodged with the Registrar within thirty
--     days of that circulation.
--
-- Each has to happen before the next. None of that is enforced. The
-- first two are plain date pickers on the filing form, written straight
-- into the table, and `fs_lodge` writes the third without looking at
-- either.
--
-- What that costs is not tidiness. `fs_deadlines` computes the s.259
-- deadline as "thirty days from what actually happened, falling back to
-- thirty days from the deadline when it has not happened yet" — its own
-- comment says *the clock runs from the act, not from the entitlement*.
-- Feed it a circulation date that precedes the approval it is supposed
-- to be of, or a lodgement recorded with no circulation at all, and it
-- computes a deadline from something that did not happen and reports a
-- filing compliant. That is the shape this project keeps finding: not an
-- absence, but a control that appears to have been applied.
--
-- Three other things follow from the same reading.
--
-- Accounts are approved before they are circulated, and both before they
-- are lodged, so `fs_lodge` now refuses a filing that was never
-- circulated. Thirty days from nothing is not a deadline anybody met.
--
-- None of the three may be in the future. A date somebody will get to is
-- not a record of an act, and every one of these is evidence of an act.
--
-- And `corp_entity_id` has never been written by anything. It exists so
-- that a corporate secretarial practice preparing a client's accounts
-- can tie them to the entity whose s.68 and s.259 deadlines `0063`
-- already tracks. Without it the deadline board and the accounts being
-- prepared for the same company are two systems that have not been
-- introduced.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The order, wherever the dates are written from
--
-- A trigger rather than a check constraint, because the message is the
-- useful part: an accountant who has typed the circulation date into the
-- approval box needs to be told which two dates disagree, not that a
-- constraint was violated.
--
-- Judging the row and not only the change, deliberately and unlike most
-- guards here: these three dates are a statement about one sequence, and
-- a row that already contradicts itself is wrong whichever field the
-- current edit touched.
-- ---------------------------------------------------------------------
create or replace function app.fs_filing_dates_guard()
returns trigger language plpgsql
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  if new.directors_approval_date is not null
     and new.directors_approval_date > v_today then
    raise exception
      'The directors cannot have approved the accounts on a day that '
      'has not happened. Section 251 is a record of a meeting.'
      using errcode = '23514';
  end if;
  if new.circulated_on is not null and new.circulated_on > v_today then
    raise exception
      'Accounts cannot have been circulated on a day that has not '
      'happened.' using errcode = '23514';
  end if;
  if new.lodged_on is not null and new.lodged_on > v_today then
    raise exception
      'Accounts cannot have been lodged on a day that has not happened.'
      using errcode = '23514';
  end if;

  if new.circulated_on is not null then
    if new.directors_approval_date is null then
      raise exception
        'Record the directors'' approval before the circulation. Under '
        's.258 what goes to the members is the approved accounts, so a '
        'circulation with no approval behind it is a draft that left '
        'the building.' using errcode = '23514';
    end if;
    if new.circulated_on < new.directors_approval_date then
      raise exception
        'The accounts were approved on % and circulated on %, which is '
        'the wrong way round.',
        to_char(new.directors_approval_date, 'DD Mon YYYY'),
        to_char(new.circulated_on, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
  end if;

  if new.lodged_on is not null and new.circulated_on is not null
     and new.lodged_on < new.circulated_on then
    raise exception
      'The accounts were circulated on % and lodged on %. Section 259 '
      'lodges what was circulated, within thirty days of circulating '
      'it.',
      to_char(new.circulated_on, 'DD Mon YYYY'),
      to_char(new.lodged_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  -- The audit report is signed on the accounts the directors approved,
  -- so it cannot predate the period it reports on. It may be later than
  -- the approval — the two are usually the same day, and the auditor
  -- occasionally signs after — but it cannot be before the year end.
  if new.audit_report_date is not null
     and new.audit_report_date < new.fy_end then
    raise exception
      'The audit report is dated %, before the year end it reports on.',
      to_char(new.audit_report_date, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  return new;
end $$;

drop trigger if exists fs_filings_dates_ck on public.fs_filings;
create trigger fs_filings_dates_ck
  before insert or update on public.fs_filings
  for each row execute function app.fs_filing_dates_guard();

-- ---------------------------------------------------------------------
-- Which company these accounts are for
--
-- Only an entity of the same organization, and only one at a time. A
-- practice keeps many entities and prepares accounts for each; picking
-- the wrong one puts a client's figures against another client's name.
-- ---------------------------------------------------------------------
create or replace function public.fs_set_entity(
  p_filing_id uuid, p_entity_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare
  f public.fs_filings;
  e public.corp_entities;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then
    raise exception 'not permitted to amend these accounts'
      using errcode = '42501';
  end if;
  if f.status = 'lodged' then
    raise exception
      'These accounts have been lodged. What they were filed for cannot '
      'change afterwards.' using errcode = '42501';
  end if;

  if p_entity_id is not null then
    select * into e from public.corp_entities where id = p_entity_id;
    if e.id is null or e.org_id <> f.org_id then
      raise exception 'No such company.' using errcode = 'P0002';
    end if;
  end if;

  perform set_config('app.fs_writing', 'on', true);
  update public.fs_filings
     set corp_entity_id = p_entity_id, updated_at = now()
   where id = p_filing_id;
  perform set_config('app.fs_writing', 'off', true);
end $$;

-- ---------------------------------------------------------------------
-- Lodging what was circulated
--
-- `fs_lodge` from `0172`, with the one guard it was missing. Section 259
-- lodges the circulated accounts within thirty days of circulating them:
-- a lodgement recorded with no circulation date has a thirty-day clock
-- that never started, and `fs_deadlines` then measures it against the
-- entitlement instead of the act and calls it on time.
--
-- Re-issued in full rather than patched, because this file is where the
-- rule now lives and a reader of `0172` needs to find the whole function
-- in one place either way.
-- ---------------------------------------------------------------------
create or replace function public.fs_lodge(
  p_filing_id uuid, p_reference text, p_lodged_on date default current_date)
returns void language plpgsql security definer
set search_path = pg_catalog, public, app, pg_temp as $$
declare f public.fs_filings;
begin
  select * into f from public.fs_filings where id = p_filing_id;
  if not found then
    raise exception 'No such filing' using errcode = 'P0002';
  end if;
  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then
    raise exception 'You may not lodge these accounts' using errcode = '42501';
  end if;
  if f.status <> 'frozen' then
    raise exception
      'Freeze the accounts before recording the lodgement — what was '
      'filed has to be a fixed set of figures.' using errcode = '22023';
  end if;
  if coalesce(trim(p_reference), '') = '' then
    raise exception 'Record the MBRS reference mPortal gave you'
      using errcode = '22023';
  end if;
  if f.circulated_on is null then
    raise exception
      'Record when the accounts went to the members first. Section 259 '
      'lodges the circulated accounts within thirty days of circulating '
      'them, and a lodgement with no circulation behind it is measured '
      'against a clock that never started.' using errcode = '22023';
  end if;

  perform set_config('app.fs_writing', 'on', true);
  update public.fs_filings
     set status = 'lodged', lodged_on = p_lodged_on,
         mbrs_reference = trim(p_reference)
   where id = p_filing_id;
  perform set_config('app.fs_writing', 'off', true);
end $$;

-- ---------------------------------------------------------------------
-- What is late, across every filing
--
-- `fs_deadlines` answers for one filing, which is right on the filing's
-- own screen and no use at all to a practice with forty companies. The
-- question there is which of them is about to miss a date, and the
-- answer has to name the company rather than the filing id — which is
-- what `corp_entity_id` is for.
-- ---------------------------------------------------------------------
create or replace function public.report_fs_deadlines(
  p_org_id uuid,
  p_within_days integer default 60)
returns table (
  filing_id uuid,
  company text,
  registration_no text,
  fy_end date,
  status app.fs_filing_status,
  approved_on date,
  circulated_on date,
  lodged_on date,
  circulate_by date,
  lodge_by date,
  days_left integer,
  is_late boolean)
language plpgsql stable security definer
set search_path = pg_catalog, public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) or not app.has_module(p_org_id, 'mbrs')
  then
    raise exception 'Not your company' using errcode = '42501';
  end if;

  return query
    select f.id,
           -- The entity when one is named, and the organization's own
           -- name when it is not: a company keeping its own books here
           -- has no `corp_entities` row and its accounts are still its
           -- accounts.
           coalesce(e.name, o.name),
           e.registration_no,
           f.fy_end, f.status,
           f.directors_approval_date, f.circulated_on, f.lodged_on,
           d.circulate_by, d.lodge_by, d.days_left, d.is_late
      from public.fs_filings f
      join public.organizations o on o.id = f.org_id
      left join public.corp_entities e on e.id = f.corp_entity_id
      cross join lateral public.fs_deadlines(f.id) d
     where f.org_id = p_org_id
       and f.status <> 'lodged'
       and d.lodge_by <= current_date + coalesce(p_within_days, 60)
     order by d.lodge_by, coalesce(e.name, o.name);
end $$;

grant execute on function public.fs_set_entity(uuid, uuid) to authenticated;
grant execute on function public.report_fs_deadlines(uuid, integer)
  to authenticated;
