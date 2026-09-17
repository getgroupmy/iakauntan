-- ---------------------------------------------------------------------
-- 0482  The duplicates already on file
-- ---------------------------------------------------------------------
-- 0481 links the records of one company as they are typed. Everything
-- typed before it is untouched: Al Hardware, filed as a supplier in
-- March and again as a customer in June, is still two records that do
-- not know of each other, and no amount of correct behaviour from now
-- on finds them. They are the records the feature exists for.
--
-- A backfill that linked them all on the way past would be a guess
-- made at scale on somebody else's ledger: a registration number
-- typed into the wrong row links two companies that are not one, and
-- the first anyone would know is a statement carrying another
-- company's invoices. So this reports rather than acts, and the
-- linking is a decision somebody makes about records they can see.
--
-- ### What this adds
--
--   * `contact_duplicates(org)` -- the groups of live records that
--     carry the same registration number, the same ID of the same
--     type, or the same TIN, and are not already one company. A group
--     the person has already decided about stops being reported,
--     because it is linked.
--
--   * `link_contact_records(org, ids)` -- makes them one company. The
--     record filed first is the party, as 0477 has it, and whole
--     families come along: linking a customer record to a supplier
--     that already has a prospect makes one company of all three,
--     never a half-linked set. Writes nothing but `party_id`, which
--     `contacts`' audit trigger records like any other change.
--
--   * `unlink_contact_record(contact)` -- the way back, for the
--     record linked on a number that turned out to be a typing
--     mistake. It leaves the company; the rest stay as they were.
--
-- ### Mutants
--
-- Run against `supabase/tests/contact_duplicates.sql`, each named with
-- the assertion that kills it:
--   * placeholders grouped as numbers -- "N/A is not a duplicate of
--     N/A";
--   * groups reported after they are linked -- "once linked, it is not
--     reported again";
--   * the org scope dropped -- "another company's records are not
--     grouped with ours";
--   * deleted records grouped -- "a deleted record is not a
--     duplicate";
--   * the ID grouped without its type -- "an NRIC and a BRN are not
--     the same number";
--   * the party taken as the last record rather than the first --
--     "the record filed first is the company";
--   * the family left behind -- "linking one record brings its
--     records with it";
--   * `link_contact_records` accepting one record -- "one record is
--     not a link";
--   * a record from another company accepted -- "a record from
--     another company cannot be linked in";
--   * the write guard dropped -- "somebody who may only read cannot
--     link" and "... cannot unlink";
--   * `unlink_contact_record` clearing the whole family -- "unlinking
--     one leaves the others together".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- What is on file twice
-- ---------------------------------------------------------------------
create or replace function public.contact_duplicates(p_org_id uuid)
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

  with keyed as (
    -- One row per record per identifier it carries. A record with a
    -- registration number and a TIN is in two groups, and the same
    -- pair of records found by both is reported once, below.
    select c.id, c.code, c.name, c.contact_type, c.party_id,
           c.created_at, k.matched_on, k.value
      from public.contacts c
     cross join lateral (
       values
         ('registration_no', app.identifying_number(c.registration_no)),
         ('id', case when c.id_type is null then null
                     else c.id_type || ':'
                          || app.identifying_number(c.id_value) end),
         ('tin', app.identifying_number(c.tin))
     ) as k(matched_on, value)
     where c.org_id = p_org_id
       and c.deleted_at is null
       and k.value is not null
       -- `id_type || ':' || null` is null, so the ID row drops itself
       -- when there is no number; the others drop on the placeholder.
       and k.value not like '%:'
  ),
  grouped as (
    select matched_on, value,
           array_agg(id order by created_at, code) as ids,
           count(distinct coalesce(party_id, id)) as companies,
           min(created_at) as filed_first
      from keyed
     group by matched_on, value
    having count(*) > 1
  ),
  -- Not already one company: a group whose records all point at the
  -- same party has been decided about, and saying it again is noise.
  undecided as (
    select * from grouped where companies > 1
  ),
  -- The same set of records found by two identifiers is one group,
  -- reported under the stronger.
  once as (
    select distinct on (ids) *
      from undecided
     order by ids,
              case matched_on
                when 'registration_no' then 1
                when 'id' then 2
                else 3 end
  )
  select coalesce(jsonb_agg(s.g order by s.filed_first, s.value),
                  '[]'::jsonb)
    into v_rows
    from (
      select o.value, o.filed_first,
             jsonb_build_object(
               'matched_on', o.matched_on,
               'value', o.value,
               'records', (
                 select jsonb_agg(jsonb_build_object(
                          'id', c.id,
                          'code', c.code,
                          'name', c.name,
                          'contact_type', c.contact_type,
                          'party_id', c.party_id)
                        order by c.created_at, c.code)
                   from public.contacts c
                  where c.id = any (o.ids))) as g
        from once o
    ) s;

  return v_rows;
end $$;

comment on function public.contact_duplicates(uuid) is
  'Live records of one company carrying the same registration number, '
  'ID or TIN and not yet linked. Reported, not linked: see 0482.';

revoke all on function public.contact_duplicates(uuid) from public, anon;
grant execute on function public.contact_duplicates(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Making them one company
-- ---------------------------------------------------------------------
create or replace function public.link_contact_records(
  p_org_id uuid, p_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_party    uuid;
  v_code     text;
  v_family   uuid[];
  v_named    integer;
  v_linked   integer;
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select count(*) into v_named
    from public.contacts
   where id = any (coalesce(p_ids, '{}'::uuid[]))
     and org_id = p_org_id
     and deleted_at is null;

  -- Every named record must be one of this company's live records:
  -- a link is about records somebody looked at, and an id that is not
  -- there is a question, not a record to skip quietly.
  if v_named <> coalesce(array_length(p_ids, 1), 0) then
    raise exception 'Those are not all records of this company'
      using errcode = 'P0002';
  end if;
  if v_named < 2 then
    raise exception 'Two records or more make a company'
      using errcode = '22023';
  end if;

  -- The whole of every family, not just the records named: a company
  -- half linked is worse than one not linked at all.
  select array_agg(c.id) into v_family
    from public.contacts c
   where c.org_id = p_org_id
     and c.deleted_at is null
     and coalesce(c.party_id, c.id) in (
       select coalesce(s.party_id, s.id)
         from public.contacts s
        where s.id = any (p_ids));

  -- The record filed first is the company, as 0477 has it.
  select c.id, c.code into v_party, v_code
    from public.contacts c
   where c.id = any (v_family)
   order by c.created_at, c.code
   limit 1;

  update public.contacts
     set party_id = v_party
   where id = any (v_family)
     and party_id is distinct from v_party;
  get diagnostics v_linked = row_count;

  return jsonb_build_object(
    'party_id', v_party, 'code', v_code, 'linked', v_linked,
    'records', array_length(v_family, 1));
end $$;

comment on function public.link_contact_records(uuid, uuid[]) is
  'Makes the given contact records one company, bringing along every '
  'record already linked to any of them. See 0482.';

revoke all on function public.link_contact_records(uuid, uuid[])
  from public, anon;
grant execute on function public.link_contact_records(uuid, uuid[])
  to authenticated;

-- ---------------------------------------------------------------------
-- And the way back
-- ---------------------------------------------------------------------
create or replace function public.unlink_contact_record(p_contact_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c public.contacts;
begin
  select * into v_c
    from public.contacts
   where id = p_contact_id and deleted_at is null;
  if v_c.id is null then
    raise exception 'No such contact' using errcode = 'P0002';
  end if;
  if not app.can_write(v_c.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- This record leaves; the others stay as they were, including when
  -- the one leaving is the record the rest are named after -- they go
  -- on pointing at an id, and the sheet reads `party_id = X or
  -- id = X`, which no longer reaches a record that has left.
  update public.contacts set party_id = null where id = v_c.id;

  return jsonb_build_object('id', v_c.id, 'code', v_c.code);
end $$;

comment on function public.unlink_contact_record(uuid) is
  'Takes one record out of its company, for a link made on a number '
  'that turned out to be a typing mistake. See 0482.';

revoke all on function public.unlink_contact_record(uuid) from public, anon;
grant execute on function public.unlink_contact_record(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  if not has_function_privilege('authenticated',
       'public.contact_duplicates(uuid)', 'execute') then
    raise exception '0482: the duplicates report is unreachable';
  end if;
  if not has_function_privilege('authenticated',
       'public.link_contact_records(uuid, uuid[])', 'execute') then
    raise exception '0482: linking is unreachable';
  end if;
  if not has_function_privilege('authenticated',
       'public.unlink_contact_record(uuid)', 'execute') then
    raise exception '0482: unlinking is unreachable';
  end if;
  if has_function_privilege('anon',
       'public.link_contact_records(uuid, uuid[])', 'execute') then
    raise exception '0482: linking is open to anon';
  end if;
  if position('can_write' in pg_get_functiondef(
       'public.link_contact_records(uuid, uuid[])'::regprocedure)) = 0 then
    raise exception '0482: linking does not ask who is asking';
  end if;
  if position('can_write' in pg_get_functiondef(
       'public.unlink_contact_record(uuid)'::regprocedure)) = 0 then
    raise exception '0482: unlinking does not ask who is asking';
  end if;
end $do$;
