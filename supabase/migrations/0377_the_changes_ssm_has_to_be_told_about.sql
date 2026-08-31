-- =====================================================================
-- iAkauntan :: 0377 the changes SSM has to be told about
--
-- `corp_entities.former_names`, `registered_office_changed_on` and
-- `constitution_adopted_on` have been columns since `0061` and none has
-- ever been written.
--
-- `0063` did the hard part. It knows that a change of registered office
-- is s.46(3) and fourteen days, that a change of name is s.28 and
-- fourteen days, and `corp_open_filing` freezes a computed obligation
-- into a row somebody can work on. What was missing is the event: the
-- entity editor writes `name` and `registered_office` as ordinary form
-- fields, so a company can be renamed by typing over its name and the
-- clock never starts.
--
-- ---------------------------------------------------------------------
-- Why a name is not a text field
--
-- Two statutory things happen when a company changes its name, and both
-- need the old one.
--
-- Section 28 requires the change to be lodged. Section 28(4) requires
-- the **former name to appear alongside the new one on every document
-- the company issues for twelve months** from the date of the change —
-- so a contract, an invoice or a court filing that names only the new
-- company is defective, and the party on the other side may not know
-- they are dealing with the same company at all.
--
-- Typing over the name loses both: the former name is gone and there is
-- no date to count twelve months from. So `former_names` gets the old
-- one, `name_changed_on` gets the date, and `corp_display_name` puts
-- them together for as long as the Act says.
--
-- ---------------------------------------------------------------------
-- Two doors, because there are two things people mean
--
-- A company changing its name and a secretary fixing a typo look
-- identical to a form and are nothing alike on a file. One is an event
-- with a deadline and a twelve-month obligation; the other is the
-- record catching up with what was always true.
--
-- So each has its own function, and the trigger refuses anything else.
-- `correct_company_name` writes no former name, opens no filing and
-- starts no clock, and the audit trail from `0038` shows which of the
-- two doors was used — which is exactly the question an inspection
-- asks.
--
-- The same for the registered office, and it is the weaker case: an
-- address is edited for a dozen innocent reasons, a unit number or a
-- postcode among them. It is guarded the same way anyway, because the
-- alternative is one rule for the sharp case and a different one for
-- the soft case, and the person filling the form has to remember which
-- is which. The screens offer the proper action, so in ordinary use
-- nobody meets the refusal.
--
-- ---------------------------------------------------------------------
-- And the constitution
--
-- `has_constitution` was a tick box and `constitution_adopted_on` was
-- never written. Section 32(1) lets a company adopt a constitution by
-- special resolution and s.32(3) requires a copy to be lodged within
-- thirty days of adoption — a filing type `0063` does not have, added
-- here in the same shape as the rest.
-- =====================================================================

alter table public.corp_entities
  add column if not exists name_changed_on date;

comment on column public.corp_entities.name_changed_on is
  'When the company last changed its name. CA 2016 s.28(4) requires the '
  'former name to appear beside the new one for twelve months from that '
  'date, so the date is not decoration — it is what says when the '
  'obligation ends.';

insert into public.corp_filing_types
  (code, name, statute_ref, legacy_form, trigger_kind, days_allowed,
   applies_to, description, sort_order)
values
  ('adopt_constitution', 'Adoption of a constitution', 'CA 2016 s.32(3)',
   null, 'event', 30,
   array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
   'A company may adopt a constitution by special resolution under '
   's.32(1); a copy is lodged with the Registrar within thirty days of '
   'the adoption.', 95)
on conflict (code) do update set
  name = excluded.name, statute_ref = excluded.statute_ref,
  legacy_form = excluded.legacy_form, trigger_kind = excluded.trigger_kind,
  days_allowed = excluded.days_allowed, applies_to = excluded.applies_to,
  description = excluded.description, sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- A name is an event
-- ---------------------------------------------------------------------
create or replace function public.change_company_name(
  p_entity uuid, p_new_name text, p_resolved_on date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_e    public.corp_entities;
  v_name text := nullif(btrim(coalesce(p_new_name, '')), '');
  v_on   date;
begin
  select * into v_e from public.corp_entities where id = p_entity;
  if v_e.id is null then
    raise exception 'No such entity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_e.org_id) then
    raise exception 'not permitted to change a company''s particulars'
      using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'A company needs a name.' using errcode = '23514';
  end if;
  if v_name = v_e.name then
    raise exception 'That is already its name.' using errcode = '23514';
  end if;

  v_on := coalesce(p_resolved_on,
                   (now() at time zone 'Asia/Kuala_Lumpur')::date);
  if v_e.incorporated_on is not null and v_on < v_e.incorporated_on then
    raise exception
      'A company cannot change its name before it existed (% ).',
      to_char(v_e.incorporated_on, 'DD Mon YYYY') using errcode = '23514';
  end if;

  update public.corp_entities set
    -- The old one goes on the front: `corp_display_name` reads the most
    -- recent, and a company that has changed its name twice in a year
    -- shows the one it was before this change.
    former_names    = array_prepend(v_e.name, coalesce(v_e.former_names, '{}')),
    name            = v_name,
    name_changed_on = v_on,
    updated_at      = now()
  where id = p_entity;

  return public.corp_open_filing(p_entity, 'change_of_name', v_on);
end $$;

-- The other door. No former name, no filing, no clock: nothing about
-- the company changed, only what this record said about it.
create or replace function public.correct_company_name(
  p_entity uuid, p_name text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_e    public.corp_entities;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  select * into v_e from public.corp_entities where id = p_entity;
  if v_e.id is null then
    raise exception 'No such entity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_e.org_id) then
    raise exception 'not permitted to change a company''s particulars'
      using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'A company needs a name.' using errcode = '23514';
  end if;

  -- The marker the trigger below looks for, set for exactly one
  -- statement and cleared immediately. `is_local` alone would leave it
  -- standing for the rest of the transaction, and a second bare update
  -- would ride through on it.
  perform set_config('app.particulars_correction', 'on', true);
  update public.corp_entities
     set name = v_name, updated_at = now()
   where id = p_entity;
  perform set_config('app.particulars_correction', '', true);
end $$;

-- ---------------------------------------------------------------------
-- So is an address
-- ---------------------------------------------------------------------
create or replace function public.change_registered_office(
  p_entity uuid, p_address text, p_effective_on date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_e   public.corp_entities;
  v_adr text := nullif(btrim(coalesce(p_address, '')), '');
  v_on  date;
begin
  select * into v_e from public.corp_entities where id = p_entity;
  if v_e.id is null then
    raise exception 'No such entity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_e.org_id) then
    raise exception 'not permitted to change a company''s particulars'
      using errcode = '42501';
  end if;
  if v_adr is null then
    raise exception
      'A registered office is where the Registrar sends things. It cannot '
      'be blank.' using errcode = '23514';
  end if;
  if v_adr = coalesce(v_e.registered_office, '') then
    raise exception 'That is already the registered office.'
      using errcode = '23514';
  end if;

  v_on := coalesce(p_effective_on,
                   (now() at time zone 'Asia/Kuala_Lumpur')::date);

  update public.corp_entities set
    registered_office            = v_adr,
    registered_office_changed_on = v_on,
    updated_at                   = now()
  where id = p_entity;

  return public.corp_open_filing(p_entity, 'change_registered_office', v_on);
end $$;

create or replace function public.correct_registered_office(
  p_entity uuid, p_address text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_e   public.corp_entities;
  v_adr text := nullif(btrim(coalesce(p_address, '')), '');
begin
  select * into v_e from public.corp_entities where id = p_entity;
  if v_e.id is null then
    raise exception 'No such entity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_e.org_id) then
    raise exception 'not permitted to change a company''s particulars'
      using errcode = '42501';
  end if;

  perform set_config('app.particulars_correction', 'on', true);
  update public.corp_entities
     set registered_office = v_adr, updated_at = now()
   where id = p_entity;
  perform set_config('app.particulars_correction', '', true);
end $$;

-- ---------------------------------------------------------------------
-- And a constitution
-- ---------------------------------------------------------------------
create or replace function public.adopt_constitution(
  p_entity uuid, p_adopted_on date default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_e  public.corp_entities;
  v_on date;
begin
  select * into v_e from public.corp_entities where id = p_entity;
  if v_e.id is null then
    raise exception 'No such entity.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_e.org_id) then
    raise exception 'not permitted to change a company''s particulars'
      using errcode = '42501';
  end if;
  if v_e.has_constitution and v_e.constitution_adopted_on is not null then
    raise exception
      'This company adopted a constitution on %. Amending one is an '
      'alteration under s.36, not a fresh adoption.',
      to_char(v_e.constitution_adopted_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  v_on := coalesce(p_adopted_on,
                   (now() at time zone 'Asia/Kuala_Lumpur')::date);
  if v_e.incorporated_on is not null and v_on < v_e.incorporated_on then
    raise exception
      'A company cannot adopt a constitution before it existed (%).',
      to_char(v_e.incorporated_on, 'DD Mon YYYY') using errcode = '23514';
  end if;

  update public.corp_entities set
    has_constitution        = true,
    constitution_adopted_on = v_on,
    updated_at              = now()
  where id = p_entity;

  return public.corp_open_filing(p_entity, 'adopt_constitution', v_on);
end $$;

-- ---------------------------------------------------------------------
-- What the company is called on a document today
--
-- CA 2016 s.28(4): for twelve months from the change, the former name
-- goes beside the new one. After that it is just history.
-- ---------------------------------------------------------------------
create or replace function public.corp_display_name(
  p_entity uuid, p_as_at date default null)
returns text
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_e  public.corp_entities;
  v_on date := coalesce(p_as_at, (now() at time zone 'Asia/Kuala_Lumpur')::date);
begin
  select * into v_e from public.corp_entities where id = p_entity;
  if v_e.id is null then
    raise exception 'No such entity.' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_e.org_id) then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  if v_e.name_changed_on is null
     or coalesce(array_length(v_e.former_names, 1), 0) = 0
     or v_on >= (v_e.name_changed_on + interval '12 months')::date
     -- Before the change, the company was called the old name and this
     -- is a document dated then. Answering with the new one would put
     -- today's name on last year's paper.
     or v_on < v_e.name_changed_on then
    return case
      when v_e.name_changed_on is not null
       and v_on < v_e.name_changed_on
       and coalesce(array_length(v_e.former_names, 1), 0) > 0
      then v_e.former_names[1]
      else v_e.name end;
  end if;

  return format('%s (formerly %s)', v_e.name, v_e.former_names[1]);
end $$;

-- ---------------------------------------------------------------------
-- And nothing else may write these
-- ---------------------------------------------------------------------
create or replace function app.corp_particulars_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;

  -- A correction, announced by the function that is allowed to make one.
  -- Set immediately before its update and cleared immediately after, so
  -- the window is one statement wide.
  if coalesce(current_setting('app.particulars_correction', true), '') = 'on'
  then
    return new;
  end if;

  -- Judging the change, not the row. An edit that leaves the name alone
  -- is an edit about something else, and this has nothing to say about
  -- it.
  if new.name is distinct from old.name
     and new.name_changed_on is not distinct from old.name_changed_on
     and new.former_names is not distinct from old.former_names then
    raise exception
      'A company''s name is not a text field. Changing it is lodged under '
      's.28 and the former name goes on its documents for twelve months, '
      'so use change_company_name — or correct_company_name if this is a '
      'typo rather than a change of name.'
      using errcode = '23514';
  end if;

  if new.registered_office is distinct from old.registered_office
     and new.registered_office_changed_on
         is not distinct from old.registered_office_changed_on then
    raise exception
      'Moving the registered office is lodged under s.46(3) within '
      'fourteen days. Use change_registered_office — or '
      'correct_registered_office if the address here was simply wrong.'
      using errcode = '23514';
  end if;

  return new;
end $$;

create trigger corp_entities_particulars_ck
  before update on public.corp_entities
  for each row execute function app.corp_particulars_guard();

revoke all on function public.change_company_name(uuid, text, date)
  from public, anon;
revoke all on function public.correct_company_name(uuid, text) from public, anon;
revoke all on function public.change_registered_office(uuid, text, date)
  from public, anon;
revoke all on function public.correct_registered_office(uuid, text)
  from public, anon;
revoke all on function public.adopt_constitution(uuid, date) from public, anon;
revoke all on function public.corp_display_name(uuid, date) from public, anon;
grant execute on function public.change_company_name(uuid, text, date)
  to authenticated;
grant execute on function public.correct_company_name(uuid, text) to authenticated;
grant execute on function public.change_registered_office(uuid, text, date)
  to authenticated;
grant execute on function public.correct_registered_office(uuid, text)
  to authenticated;
grant execute on function public.adopt_constitution(uuid, date) to authenticated;
grant execute on function public.corp_display_name(uuid, date) to authenticated;

comment on function public.change_company_name(uuid, text, date) is
  'Renames a company, keeps the former name, and opens the s.28 filing. '
  'Typing over the name loses both the old name and the date twelve '
  'months of s.28(4) are counted from.';
comment on function public.corp_display_name(uuid, date) is
  'What the company is called on a document of that date: the new name '
  'with the former one beside it for twelve months after a change, and '
  'the former name alone on paper dated before it.';
