-- ---------------------------------------------------------------------
-- 0481  The same company, typed by hand
-- ---------------------------------------------------------------------
-- 0477 links the records of one company through `party_id`, and sets
-- it in the one place it knew of: `create_contact_as`, which makes the
-- second record from the first. A record typed by hand was outside
-- that. Al Hardware filed as a supplier in March, and typed in again
-- as a customer in June by somebody who did not look, is two records
-- that do not know of each other -- the sheet shows nothing on either,
-- and `create_contact_as` would happily make a third customer record
-- from the supplier. Worse, the same supplier typed in twice is two
-- suppliers, two codes, and bills split between them.
--
-- ### What changes
--
--   * `contact_lookalikes(org, type, name, registration, tin, id)` is
--     what the editor asks while the form is being filled: which
--     records already carry this registration number, this ID, this
--     TIN or this name, and whether any of them is already in the
--     role being typed. The editor says so before Save -- "already on
--     file as S-2026-00001" -- and Save is not refused, because the
--     database cannot know that the number was typed wrongly rather
--     than the record duplicated. What it can do is say.
--
--   * A trigger, `contact_joins_its_party`: a record inserted, or one
--     whose identifiers change, with no party of its own and the same
--     registration number, ID or TIN as a live record of the company,
--     is linked to that record's party. The registration number is a
--     company's, not a role's, so the same number is the same company
--     -- and from then on the sheet shows the records together and
--     `create_contact_as` refuses a second record for a role that is
--     taken. The first record is the party, as 0477 has it, and the
--     link is the one write this makes to it.
--
--     A name is not an identifier. Two "Ali Enterprise"s in one town
--     are ordinary, so a name match is something the editor mentions
--     and nothing the trigger acts on.
--
--   * `app.identifying_number(text)` is what "the same number" means:
--     letters and digits only, in upper case, so `1234567-X` and
--     `1234567X` are one number -- and null for what is not a number
--     at all. Import files say `N/A` and `NIL` in a column they have
--     nothing for, and every such row would otherwise be one company;
--     and LHDN's general TINs (`EI00000000010` and its siblings) are
--     shared by design by every buyer who has none of their own.
--
-- ### Mutants
--
-- Run against `supabase/tests/contact_lookalikes.sql`, each named with
-- the assertion that kills it:
--   * the registration number compared verbatim -- "written with a
--     dash, it is still the same number";
--   * placeholders treated as numbers -- "N/A is not a registration
--     number" and "LHDN's general TIN is not anybody's";
--   * the name treated as an identifier by the trigger -- "a name
--     alone links nothing";
--   * the org scope dropped from the match -- "another company's
--     contacts are not looked at";
--   * the record matched against itself on edit -- "a record is not
--     its own lookalike";
--   * `same_role` always false -- "and as a supplier, it is already on
--     file";
--   * the trigger not setting `party_id` -- "typed by hand, the
--     customer record joins the supplier's party";
--   * the trigger not marking the first record as the party -- "and
--     the supplier record is the party";
--   * a record with a party re-linked when its number changes --
--     "a record that has a party keeps it";
--   * the ID compared without its type -- "an NRIC is not a BRN with
--     the same digits";
--   * the guard dropped -- "somebody outside the company is refused".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- What "the same number" means
-- ---------------------------------------------------------------------
create or replace function app.identifying_number(p text)
returns text
language sql immutable
set search_path = pg_temp as $$
  select case
    -- N/A, NIL, NONE, a dash, an empty cell: not a number.
    when v !~ '[1-9]' then null
    -- LHDN's general TINs, issued to nobody in particular:
    -- EI00000000010 (general public), 020, 030, 040.
    when v ~ '^EI0+[0-9]{2}$' then null
    else v end
  from (select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '',
                                    'g'))) s(v);
$$;

comment on function app.identifying_number(text) is
  'A registration number, ID or TIN reduced to what identifies: '
  'letters and digits in upper case, or null for a placeholder (N/A, '
  'NIL, a dash) or one of LHDN''s general TINs. See 0481.';

-- A name for comparing, not for linking: case and punctuation folded,
-- whitespace collapsed.
create or replace function app.comparable_name(p text)
returns text
language sql immutable
set search_path = pg_temp as $$
  select nullif(trim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+',
                                    ' ', 'g')), '');
$$;

create index if not exists contacts_org_registration_idx
  on public.contacts (org_id, app.identifying_number(registration_no))
  where registration_no is not null and deleted_at is null;
create index if not exists contacts_org_tin_idx
  on public.contacts (org_id, app.identifying_number(tin))
  where tin is not null and deleted_at is null;

-- ---------------------------------------------------------------------
-- The match
-- ---------------------------------------------------------------------
-- Every live record of the company that carries one of the values,
-- with the strongest reason: a registration number over an ID over a
-- TIN over a name. Read by the trigger (without the name) and by the
-- editor's question (with it).
create or replace function app.contact_matches(
  p_org_id          uuid,
  p_exclude         uuid,
  p_name            text,
  p_registration_no text,
  p_tin             text,
  p_id_type         text,
  p_id_value        text)
returns table (contact_id uuid, matched_on text)
language sql stable
set search_path = public, app, pg_temp as $$
  select m.id, m.matched_on
    from (
      select c.id,
             case
               when v.registration_no is not null
                and app.identifying_number(c.registration_no)
                    = v.registration_no
                 then 'registration_no'
               when v.id_value is not null
                and c.id_type = p_id_type
                and app.identifying_number(c.id_value) = v.id_value
                 then 'id'
               when v.tin is not null
                and app.identifying_number(c.tin) = v.tin
                 then 'tin'
               when v.name is not null
                and app.comparable_name(c.name) = v.name
                 then 'name'
             end as matched_on
        from public.contacts c,
             (select app.identifying_number(p_registration_no),
                     app.identifying_number(p_tin),
                     app.identifying_number(p_id_value),
                     app.comparable_name(p_name))
               as v(registration_no, tin, id_value, name)
       where c.org_id = p_org_id
         and c.deleted_at is null
         and (p_exclude is null or c.id <> p_exclude)
    ) m
   where m.matched_on is not null;
$$;

-- ---------------------------------------------------------------------
-- The trigger
-- ---------------------------------------------------------------------
create or replace function app.contact_joins_its_party()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_match public.contacts;
begin
  -- The strongest identifier, and among equals the record filed
  -- first: a company's first record is the party every later one
  -- points at. The name is deliberately not passed.
  select c.* into v_match
    from app.contact_matches(
           new.org_id, new.id, null,
           new.registration_no, new.tin, new.id_type, new.id_value) m
    join public.contacts c on c.id = m.contact_id
   order by case m.matched_on
              when 'registration_no' then 1
              when 'id' then 2
              else 3 end,
            c.created_at, c.code
   limit 1;

  if v_match.id is null then
    return new;
  end if;

  new.party_id := coalesce(v_match.party_id, v_match.id);

  -- The one write to the record already on file: which company it
  -- is. Not its code, not its type, not a document.
  update public.contacts
     set party_id = v_match.id
   where id = v_match.id and party_id is null;

  return new;
end $$;

comment on function app.contact_joins_its_party() is
  'A contact with no party and the same registration number, ID or '
  'TIN as a live record of the company joins that record''s party. '
  'A name links nothing. See 0481.';

revoke all on function app.contact_joins_its_party()
  from public, anon, authenticated;

drop trigger if exists contact_joins_its_party on public.contacts;
create trigger contact_joins_its_party
  before insert or update of registration_no, tin, id_type, id_value
  on public.contacts
  for each row
  when (new.party_id is null and new.deleted_at is null
        and (new.registration_no is not null
             or new.tin is not null
             or new.id_value is not null))
  execute function app.contact_joins_its_party();

-- ---------------------------------------------------------------------
-- What the editor asks
-- ---------------------------------------------------------------------
create or replace function public.contact_lookalikes(
  p_org_id          uuid,
  p_contact_type    app.contact_type,
  p_name            text,
  p_registration_no text default null,
  p_tin             text default null,
  p_id_type         text default null,
  p_id_value        text default null,
  p_exclude         uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  -- The records already in the role being typed come first: those are
  -- the ones Save would duplicate. Then the same company in another
  -- role, which Save will link to.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'code', c.code,
           'name', c.name,
           'contact_type', c.contact_type,
           'matched_on', m.matched_on,
           'same_role', app.contact_carries(c.contact_type, p_contact_type)
                     or app.contact_carries(p_contact_type, c.contact_type))
           order by
             (app.contact_carries(c.contact_type, p_contact_type)
              or app.contact_carries(p_contact_type, c.contact_type)) desc,
             case m.matched_on
               when 'registration_no' then 1
               when 'id' then 2
               when 'tin' then 3
               else 4 end,
             c.code), '[]'::jsonb)
    into v_rows
    from (
      select *
        from app.contact_matches(
               p_org_id, p_exclude, p_name,
               p_registration_no, p_tin, p_id_type, p_id_value)
       limit 5) m
    join public.contacts c on c.id = m.contact_id;

  return v_rows;
end $$;

comment on function public.contact_lookalikes(
  uuid, app.contact_type, text, text, text, text, text, uuid) is
  'The records already carrying this registration number, ID, TIN or '
  'name, and whether each is already in the role being typed. What '
  'the editor says before Save. See 0481.';

revoke all on function public.contact_lookalikes(
  uuid, app.contact_type, text, text, text, text, text, uuid)
  from public, anon;
grant execute on function public.contact_lookalikes(
  uuid, app.contact_type, text, text, text, text, text, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if app.identifying_number('1234567-X') <> '1234567X' then
    raise exception '0481: the dash is not folded';
  end if;
  if app.identifying_number('N/A') is not null
     or app.identifying_number('EI00000000010') is not null then
    raise exception '0481: a placeholder passes for a number';
  end if;
  if app.identifying_number('C12345678900') <> 'C12345678900' then
    raise exception '0481: a real TIN is refused';
  end if;
  if not exists (
    select 1 from pg_trigger
     where tgname = 'contact_joins_its_party'
       and tgrelid = 'public.contacts'::regclass) then
    raise exception '0481: the trigger is not on contacts';
  end if;
  if position('null,' in pg_get_functiondef(
       'app.contact_joins_its_party()'::regprocedure)) = 0 then
    raise exception '0481: the trigger passes the name to the match';
  end if;
  if not has_function_privilege('authenticated',
       'public.contact_lookalikes(uuid, app.contact_type, text, text, '
       'text, text, text, uuid)', 'execute') then
    raise exception '0481: the editor cannot ask';
  end if;
  if has_function_privilege('authenticated',
       'app.contact_joins_its_party()', 'execute') then
    raise exception '0481: the linking write is reachable from an API key';
  end if;
end $do$;
