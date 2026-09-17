-- =====================================================================
-- iAkauntan :: 0634 the trail you can actually search
--
-- `audit_trail` takes a table, a record and a limit. It is capped at
-- 500 rows and ordered newest first, which means the honest answer to
-- "who changed the bank account details in March" is: page through the
-- change history until March appears, and if more than five hundred
-- things have changed since, it never does.
--
-- Two filters fix that, and they are the two somebody actually arrives
-- with — a PERSON and a DATE. `audit_logs` already carries `user_id`
-- and `created_at`; nothing could ask about either.
--
-- ---------------------------------------------------------------------
-- Why the old signature goes rather than gaining an overload
--
-- New parameters with defaults would make `audit_trail(org, table,
-- record, limit)` match both forms, and Postgres refuses an ambiguous
-- call rather than choosing. So the four-argument form is dropped and
-- the seven-argument one replaces it. Every existing caller passes
-- four arguments and keeps working, because the three new ones default
-- to null.
--
-- ---------------------------------------------------------------------
-- It is still a read that writes, and still must not be polled
--
-- `0583` put it in the undocumented-writes list on purpose: reading the
-- trail records a `sensitive_read` against the caller, because this is
-- the one place where salary history, bank numbers and everybody's
-- access changes can be read in one go.
--
-- Filters make that WORSE if they are used carelessly — a screen that
-- re-reads on every keystroke of a date field would write an event per
-- keystroke and bury the ones somebody is looking for. The comment says
-- so, and the card that uses it reads on a button rather than on
-- change.
--
-- ---------------------------------------------------------------------
-- The date is a DAY, in Malaysian time
--
-- `created_at` is `timestamptz`. Somebody asking for "the 3rd" means
-- the 3rd in Kuala Lumpur, and comparing a timestamptz to a date in the
-- server's zone would silently answer about a different day — the
-- mistake `malaysian_clock.sql` exists to catch. `p_to` is inclusive of
-- its whole day for the same reason: "from the 1st to the 3rd" said by
-- a person includes the 3rd.
-- =====================================================================

drop function if exists public.audit_trail(uuid, text, uuid, integer);

create or replace function public.audit_trail(
  p_org_id    uuid,
  p_table     text default null,
  p_record_id uuid default null,
  p_limit     integer default 100,
  p_actor_id  uuid default null,
  p_from      date default null,
  p_to        date default null)
returns table (
  id bigint, at timestamptz, actor text, action text,
  table_name text, record_id uuid, changes jsonb)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the audit trail'
      using errcode = '42501';
  end if;

  perform app.note_read(p_org_id, 'audit_trail');

  return query
  select l.id, l.created_at,
         coalesce(p.full_name, p.email, 'system'),
         l.action, l.table_name, l.record_id,
         jsonb_build_object('from', l.old_data, 'to', l.new_data)
    from public.audit_logs l
    left join public.profiles p on p.id = l.user_id
   where l.org_id = p_org_id
     and (p_table is null or l.table_name = p_table)
     and (p_record_id is null or l.record_id = p_record_id)
     -- A null `user_id` is the database's own write, and asking for a
     -- PERSON must not return the rows nobody did. `=` gives that for
     -- free: null equals nothing, so those rows drop out without a
     -- clause of their own.
     and (p_actor_id is null or l.user_id = p_actor_id)
     and (p_from is null
          or (l.created_at at time zone 'Asia/Kuala_Lumpur')::date >= p_from)
     and (p_to is null
          or (l.created_at at time zone 'Asia/Kuala_Lumpur')::date <= p_to)
   order by l.id desc
   limit least(coalesce(p_limit, 100), 500);
end;
$$;

comment on function public.audit_trail(
  uuid, text, uuid, integer, uuid, date, date) is
  'Returns what changed, most recent first, with the before and after '
  'of each row. Filterable by table, by record, by WHO made the change '
  'and by a range of days in Malaysian time. A READ THAT WRITES: it '
  'records a `sensitive_read` against the caller, which is why it is '
  'volatile and why it is in the undocumented-writes list at all. Do '
  'not poll it, and do not re-read it on every keystroke of a filter — '
  'either buries the events somebody is looking for. Capped at 500 rows '
  'however large `p_limit` is. Owner or administrator only. See 0634.';

grant execute on function public.audit_trail(
  uuid, text, uuid, integer, uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- Who there is to filter by
-- ---------------------------------------------------------------------
-- The trail names people; a filter needs the list. Members of this
-- company only, and only the ones who have actually changed something,
-- because a dropdown of forty names of whom three appear in the trail
-- is a dropdown that wastes thirty-seven choices.
create or replace function public.audit_trail_actors(p_org_id uuid)
returns table (user_id uuid, name text, entries bigint)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or admin may read the audit trail'
      using errcode = '42501';
  end if;

  -- Deliberately NOT `note_read`. This is the list of names on a filter,
  -- not the trail itself, and recording a sensitive read for drawing a
  -- dropdown is how the log fills with events nobody caused.
  return query
  select l.user_id,
         coalesce(p.full_name, p.email, 'system'),
         count(*)
    from public.audit_logs l
    left join public.profiles p on p.id = l.user_id
   where l.org_id = p_org_id
     and l.user_id is not null
   group by l.user_id, coalesce(p.full_name, p.email, 'system')
   order by count(*) desc, 2;
end;
$$;

comment on function public.audit_trail_actors(uuid) is
  'Who appears in this company''s change history, and how often, for '
  'the filter on the trail. Not a sensitive read: it is a list of '
  'names, and recording one for drawing a dropdown fills the log with '
  'events nobody caused. Owner or administrator only. See 0634.';

grant execute on function public.audit_trail_actors(uuid) to authenticated;
