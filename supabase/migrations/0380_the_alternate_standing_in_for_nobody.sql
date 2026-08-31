-- =====================================================================
-- iAkauntan :: 0380 the alternate standing in for nobody
--
-- Two columns in `0061` that nothing has ever written, and both of them
-- are the half of a statutory record that says who.
--
-- ---------------------------------------------------------------------
-- `corp_officers.alternate_for`
--
-- The register offers "Acting as an alternate" as a tick box and the
-- role enum carries `alternate_director`, so the register can say that
-- somebody is an alternate. `alternate_for` — *whose* — has never been
-- set by anything.
--
-- Under s.208 of the Companies Act 2016 an alternate is appointed by a
-- particular director to act in their place, with that director's vote
-- and only while that director cannot act. A register entry saying
-- somebody is an alternate for nobody in particular does not record an
-- appointment; it records that one happened. It cannot answer the
-- question the column exists for — whether the board had a quorum on
-- the day, which is the question a resolution's validity turns on,
-- because an alternate votes in place of their principal and not as
-- well as them.
--
-- ---------------------------------------------------------------------
-- One fact, written once
--
-- `is_alternate boolean` and `role = 'alternate_director'` were two
-- ways of saying the same thing, set independently by the same screen,
-- and `0188`'s seed sets neither. Two sources of truth for one fact is
-- how they come to disagree — a director whose role says alternate and
-- whose flag says no is a row that reads differently depending which
-- half you look at.
--
-- So `is_alternate` stops being typed and becomes derived: it is true
-- exactly when `alternate_for` names somebody. That leaves room for the
-- case the boolean was there for and the role enum cannot express — a
-- deputy secretary standing in for the named one — while making the
-- flag and the relationship impossible to contradict.
--
-- ---------------------------------------------------------------------
-- And what happens when the principal goes
--
-- An alternate acts in the principal's place. When the principal ceases
-- to hold office the alternate's appointment goes with it: there is no
-- longer a place to act in. Until now the foreign key said
-- `on delete set null`, which is about a row being deleted — and an
-- officer who resigns is not deleted, they are dated. So the register
-- would go on showing somebody standing in for a director who left in
-- March.
--
-- Ceasing them is done here rather than left to whoever remembers,
-- because "whoever remembers" is what the s.58 fourteen-day clock runs
-- against.
--
-- ---------------------------------------------------------------------
-- `corp_persons.id_verified_by`
--
-- The person editor records `id_document_type` and `id_verified_on`.
-- Who did the verifying has never been written.
--
-- A secretary is a reporting institution under the AMLA for some
-- engagements, and customer due diligence is a record of an act by a
-- person: this identity document, seen by this individual, on this day.
-- A date with no name attached is not that record — it is an assertion
-- that somebody, at some point, was satisfied. The same shape as
-- `0378`'s `lodged_by`, and it is fixed the same way: the column is
-- stamped from `auth.uid()` by the function that does the verifying,
-- and a date cannot be written without it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is already there
-- ---------------------------------------------------------------------
do $$
declare r record; v_n integer := 0;
begin
  for r in
    select o.org_id, e.name as entity, p.full_name
      from public.corp_officers o
      join public.corp_entities e on e.id = o.entity_id
      join public.corp_persons p on p.id = o.person_id
     where o.resigned_on is null
       and (o.is_alternate or o.role = 'alternate_director')
       and o.alternate_for is null
     order by e.name, p.full_name
  loop
    v_n := v_n + 1;
    raise notice
      '0380: % is an alternate at % and the register does not say whose. '
      'Name the principal: an alternate votes in place of somebody, and '
      'quorum cannot be worked out without knowing who.',
      r.full_name, r.entity;
  end loop;
  if v_n > 0 then
    raise notice
      '0380: % alternate(s) above with no principal named.', v_n;
  end if;

  select count(*) into v_n from public.corp_persons
   where id_verified_on is not null and id_verified_by is null;
  if v_n > 0 then
    raise notice
      '0380: % person(s) carry a verification date and no verifier. The '
      'date stays; it says when somebody was satisfied and not who. New '
      'verifications record both.', v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- An alternate acts in somebody's place
-- ---------------------------------------------------------------------
create or replace function app.corp_officer_alternate_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare v_principal public.corp_officers;
begin
  -- Derived, not typed. The flag and the relationship cannot disagree
  -- because there is only one of them now.
  new.is_alternate := new.alternate_for is not null;

  if new.role = 'alternate_director' and new.alternate_for is null then
    raise exception
      'An alternate director acts in a particular director''s place. Say '
      'whose: an alternate votes instead of their principal and not as '
      'well, so a board''s quorum cannot be worked out without it.'
      using errcode = '23514';
  end if;

  if new.alternate_for is null then return new; end if;

  if new.alternate_for = new.id then
    raise exception 'Nobody stands in for themselves.'
      using errcode = '23514';
  end if;

  select * into v_principal from public.corp_officers
   where id = new.alternate_for;
  if v_principal.id is null then
    raise exception 'No such officer to stand in for.' using errcode = 'P0002';
  end if;
  if v_principal.entity_id <> new.entity_id then
    raise exception
      'The principal has to be an officer of the same company.'
      using errcode = '23514';
  end if;
  if v_principal.person_id = new.person_id then
    raise exception 'Nobody stands in for themselves.'
      using errcode = '23514';
  end if;
  if v_principal.alternate_for is not null then
    raise exception
      'An alternate cannot have an alternate. The appointment is the '
      'principal''s to make, and it has already been made once.'
      using errcode = '23514';
  end if;

  -- Appointing a stand-in for somebody who has already gone is
  -- appointing them to a place that no longer exists.
  if v_principal.resigned_on is not null
     and (new.resigned_on is null or new.resigned_on > v_principal.resigned_on)
  then
    raise exception
      'That director ceased to hold office on %. An alternate acts in '
      'their place, and there is no longer a place.',
      to_char(v_principal.resigned_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;

  return new;
end $$;

drop trigger if exists corp_officers_alternate_ck on public.corp_officers;
create trigger corp_officers_alternate_ck
  before insert or update on public.corp_officers
  for each row execute function app.corp_officer_alternate_guard();

-- Backfill the derived flag so the two say the same thing from here on.
-- Nothing is invented: an alternate with no principal named stays
-- flagged by its role, and the notice above says who they are.
update public.corp_officers
   set is_alternate = (alternate_for is not null)
 where is_alternate is distinct from (alternate_for is not null);

-- ---------------------------------------------------------------------
-- When the principal goes, so does the stand-in
-- ---------------------------------------------------------------------
create or replace function app.corp_officer_cascade_cessation()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare v_n integer;
begin
  -- Judging the change, not the row: without this, every edit to a
  -- long-resigned director — a designation, a spelling — writes their
  -- alternates' rows back to the values they already hold and takes a
  -- row lock on each.
  --
  -- Kept although the mutation run could not kill it, and the reasoning
  -- is the same judgement `0375` records. It is not dead code: it stops
  -- a write. It is unobservable because `app.write_audit_log` already
  -- drops an update whose diff is empty, so the false audit entry this
  -- would otherwise produce never appears — which is the audit trail
  -- being careful, not this being unnecessary. Arriving at the right
  -- register through a second guard downstream is not the same as not
  -- touching rows nobody asked to change.
  if old.resigned_on is not distinct from new.resigned_on then
    return new;
  end if;

  if new.resigned_on is null then
    -- The principal is back. Their alternates were ceased by this
    -- trigger and by nothing else — the date and the reason both say
    -- so — and a cessation that happened only because of the
    -- principal's ends when the principal's does.
    update public.corp_officers a
       set resigned_on = null,
           cessation_reason = null,
           updated_at = now()
     where a.alternate_for = new.id
       and a.resigned_on = old.resigned_on
       and a.cessation_reason like 'Principal ceased%';
    get diagnostics v_n = row_count;
    if v_n > 0 then
      raise notice
        '0380: % alternate appointment(s) restored with the principal.', v_n;
    end if;
    return new;
  end if;

  -- Recording it, or correcting the date. One event, so an alternate
  -- ceased by it moves with it: a date corrected on the principal and
  -- left stale on the stand-in is the register disagreeing with itself
  -- about a single day.
  update public.corp_officers a
     set resigned_on = new.resigned_on,
         cessation_reason = coalesce(
           a.cessation_reason,
           'Principal ceased to hold office on '
             || to_char(new.resigned_on, 'DD Mon YYYY')),
         updated_at = now()
   where a.alternate_for = new.id
     and (a.resigned_on is null
          or (old.resigned_on is not null
              and a.resigned_on = old.resigned_on
              and a.cessation_reason like 'Principal ceased%'));
  get diagnostics v_n = row_count;
  if v_n > 0 then
    raise notice
      '0380: % alternate appointment(s) ceased with the principal.', v_n;
  end if;
  return new;
end $$;

drop trigger if exists corp_officers_cascade_cessation on public.corp_officers;
create trigger corp_officers_cascade_cessation
  after update on public.corp_officers
  for each row execute function app.corp_officer_cascade_cessation();

-- ---------------------------------------------------------------------
-- Who may be stood in for
-- ---------------------------------------------------------------------
create or replace function public.corp_principals_for_alternate(
  p_entity uuid,
  p_exclude uuid default null)
returns table (
  officer_id uuid,
  person_id  uuid,
  full_name  text,
  role       text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select o.id, o.person_id, p.full_name, o.role::text
    from public.corp_officers o
    join public.corp_persons p on p.id = o.person_id
    join public.corp_entities e on e.id = o.entity_id
   where o.entity_id = p_entity
     and app.can_write(e.org_id)
     -- Sitting officers only, who are not themselves standing in for
     -- somebody, and not the person being edited.
     and o.resigned_on is null
     and o.alternate_for is null
     and (p_exclude is null or o.id <> p_exclude)
   order by p.full_name;
$$;

-- ---------------------------------------------------------------------
-- Who saw the document
-- ---------------------------------------------------------------------
create or replace function app.corp_person_verification_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  if new.id_verified_on is null then
    new.id_verified_by := null;
    return new;
  end if;
  -- Rows that predate this carry a date and no verifier, and they stay
  -- editable: refusing every later change to them would mean a phone
  -- number could not be corrected until somebody re-did a check that
  -- may have been done properly years ago.
  if tg_op = 'UPDATE'
     and old.id_verified_on is not distinct from new.id_verified_on then
    return new;
  end if;
  if new.id_verified_by is null then
    raise exception
      'Customer due diligence is a record of an act by a person: this '
      'document, seen by this individual, on this day. Use '
      'verify_person_identity so the register says who.'
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists corp_persons_verification_ck on public.corp_persons;
create trigger corp_persons_verification_ck
  before insert or update on public.corp_persons
  for each row execute function app.corp_person_verification_guard();

create or replace function public.verify_person_identity(
  p_person        uuid,
  p_document_type text,
  p_verified_on   date default null,
  p_notes         text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_p     public.corp_persons;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_on    date := coalesce(p_verified_on, (now() at time zone
                            'Asia/Kuala_Lumpur')::date);
begin
  select * into v_p from public.corp_persons where id = p_person;
  if v_p.id is null then
    raise exception 'No such person.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_p.org_id) then
    raise exception 'not permitted to record a verification'
      using errcode = '42501';
  end if;
  if p_document_type is null or btrim(p_document_type) = '' then
    raise exception
      'Say what was seen. "Verified" with no document named is the part '
      'of the record an examiner asks for.' using errcode = '23514';
  end if;
  if v_on > v_today then
    raise exception 'A document cannot have been seen tomorrow.'
      using errcode = '23514';
  end if;

  update public.corp_persons set
    id_document_type = btrim(p_document_type),
    id_verified_on   = v_on,
    id_verified_by   = auth.uid(),
    kyc_notes        = coalesce(nullif(btrim(coalesce(p_notes, '')), ''),
                                kyc_notes),
    updated_at       = now()
  where id = p_person;
end $$;

-- Undoing one, because a verification recorded against the wrong person
-- is ordinary and a state with no way out is how somebody deletes a
-- person record to fix a mistake.
create or replace function public.unverify_person_identity(p_person uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_p public.corp_persons;
begin
  select * into v_p from public.corp_persons where id = p_person;
  if v_p.id is null then
    raise exception 'No such person.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_p.org_id) then
    raise exception 'not permitted to withdraw a verification'
      using errcode = '42501';
  end if;

  -- Only the date. `corp_persons_verification_ck` clears the verifier
  -- with it, because a verifier with no date is the same broken record
  -- the other way round — and the rule belongs in the one place that
  -- every write goes through, not restated here where a direct UPDATE
  -- would miss it. The mutation run made the point: restating it here
  -- was a line nothing could observe.
  update public.corp_persons set
    id_verified_on = null,
    updated_at     = now()
  where id = p_person;
end $$;

-- ---------------------------------------------------------------------
revoke all on function
  public.corp_principals_for_alternate(uuid, uuid) from public, anon;
revoke all on function
  public.verify_person_identity(uuid, text, date, text) from public, anon;
revoke all on function
  public.unverify_person_identity(uuid) from public, anon;

grant execute on function
  public.corp_principals_for_alternate(uuid, uuid) to authenticated;
grant execute on function
  public.verify_person_identity(uuid, text, date, text) to authenticated;
grant execute on function
  public.unverify_person_identity(uuid) to authenticated;

comment on function app.corp_officer_alternate_guard() is
  'An alternate director acts in a named director''s place (CA 2016 '
  's.208), so `alternate_for` is required and `is_alternate` is derived '
  'from it rather than typed beside it.';
comment on function app.corp_officer_cascade_cessation() is
  'An alternate''s appointment ends with the principal''s: there is no '
  'longer a place to act in. The foreign key said `on delete set null`, '
  'which is about deletion, and an officer who resigns is dated rather '
  'than deleted.';
comment on function public.verify_person_identity(uuid, text, date, text) is
  'Records a CDD check as what it is — this document, seen by this '
  'individual, on this day. `id_verified_by` was a column nothing wrote, '
  'which left a date asserting that somebody was satisfied without '
  'saying who.';
