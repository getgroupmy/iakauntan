-- =====================================================================
-- iAkauntan :: 0644 a note is as private as what it is about
--
-- `public.notes` -- free-form notes attachable to anything, on the
-- `entity_table` / `entity_id` shape `attachments` uses -- has existed
-- since `0008` with four policies, a grant, and an index on
-- `(org_id, entity_table, entity_id)`. No function and no line of Dart
-- has ever touched it. The orphan sweep found `notes.is_pinned` and
-- recorded the table, not the column, as the finding.
--
-- This migration does not build the feature. It fixes what the feature
-- would have been built on, because the policies are the naive version
-- and they were written before the question had been thought through:
--
--     notes_select  app.is_org_member(org_id)
--     notes_insert  app.can_write(org_id)
--     notes_update  app.can_write(org_id)
--     notes_delete  app.can_write(org_id)
--
-- ---------------------------------------------------------------------
-- What that would have meant
--
-- A note is filed against a ROW, and `entity_table` says which. So a
-- note on an `employee_documents` row -- "passport expires in March,
-- chase the renewal" -- was readable by every member of the company,
-- and so was one on a `payslips` row or a `corp_persons` row.
--
-- That is the exact hole `app.can_read_attachment` exists to close for
-- the file itself. `0460` and `0565` reasoned it out at length and
-- `0568` widened it: the ledger audience is kept out of personnel
-- records, whoever runs payroll is let in because a work permit
-- decides whether somebody may be paid, and the employee it is about
-- reads their own and nobody else's. A note about a passport would
-- have gone round all of it.
--
-- And `can_write` on UPDATE and DELETE means any colleague may edit or
-- silently remove somebody else's note. A note is a record of what
-- somebody said they would do -- "promised payment Friday" -- and a
-- record a third party can rewrite is not evidence of anything.
--
-- Nothing has been lost yet: the table is empty in every deployment,
-- because nothing can write to it. This closes the door before there
-- is anything behind it.
--
-- ---------------------------------------------------------------------
-- The same question the thing it is about asks
--
-- Reading a note asks `app.can_read_attachment(org, table, record)`,
-- which is not a metaphor -- it is literally "who may see something
-- filed against this row", already written, already asserted, and
-- already carrying the personnel carve-out, the bug-report case and
-- the mailbox case. Two answers to that question would be one too
-- many.
--
-- Writing one asks `app.can_attach_to`, the same way, which also means
-- an employee may put a note on their own expense claim and not on a
-- colleague's -- without a line of that being restated here.
--
-- Editing and deleting ask both: the write permission AND authorship.
-- `created_by` has been on the table since `0008`; nothing wrote it
-- either, so a trigger fills it the way `employee_documents` fills
-- `uploaded_by` -- from `auth.uid()`, once, at insert, not from
-- whatever the client sends.
--
-- An administrator may delete anybody's note and may not edit it. The
-- difference is deliberate: removing a note that should not be on the
-- file is housekeeping somebody may need to do, while editing one puts
-- words in a colleague's mouth under their name, and there is no
-- version of that which is not worse than deleting it and writing your
-- own.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who wrote it, recorded rather than claimed
-- ---------------------------------------------------------------------
create or replace function app.notes_set_author()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $function$
begin
  if tg_op = 'INSERT' then
    -- From the session, not from the payload. A client that sends
    -- `created_by` is a client claiming to be somebody else.
    new.created_by := auth.uid();
    return new;
  end if;

  -- And it does not move afterwards. Without this, an edit could
  -- reassign a note to a colleague, which is the same forgery by a
  -- longer route.
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  return new;
end;
$function$;

drop trigger if exists set_note_author on public.notes;

create trigger set_note_author
  before insert or update on public.notes
  for each row
  execute function app.notes_set_author();

-- ---------------------------------------------------------------------
-- The four policies, replaced
-- ---------------------------------------------------------------------
drop policy if exists notes_select on public.notes;
drop policy if exists notes_insert on public.notes;
drop policy if exists notes_update on public.notes;
drop policy if exists notes_delete on public.notes;

-- A note is as readable as the row it is about, and no more.
create policy notes_select on public.notes for select
  using (app.can_read_attachment(org_id, entity_table, entity_id));

-- And as writable. `can_attach_to` is where "may this person file
-- something against this row" already lives, including the employee
-- who may put one on their own claim and not on a colleague's.
create policy notes_insert on public.notes for insert
  with check (app.can_attach_to(org_id, entity_table, entity_id));

-- Editing is authorship AND permission. The author may correct their
-- own; nobody else may, however senior -- an edit under somebody
-- else's name is words in their mouth.
create policy notes_update on public.notes for update
  using (created_by = auth.uid()
         and app.can_attach_to(org_id, entity_table, entity_id))
  with check (created_by = auth.uid()
              and app.can_attach_to(org_id, entity_table, entity_id));

-- Deleting is the author, or an administrator. Taking a note off a
-- file is housekeeping somebody may legitimately need to do; the
-- difference from editing is that it leaves nothing claiming to be
-- somebody's words.
create policy notes_delete on public.notes for delete
  using (app.can_admin(org_id)
         or (created_by = auth.uid()
             and app.can_attach_to(org_id, entity_table, entity_id)));

comment on table public.notes is
  'Free-form notes filed against any row, on the entity_table/entity_id '
  'shape attachments uses. 0644: a note is exactly as private as the '
  'row it is about -- reading asks app.can_read_attachment and writing '
  'asks app.can_attach_to, so a note on a payslip is not company '
  'reading. created_by is set by a trigger from auth.uid() and never '
  'moves.';

comment on column public.notes.is_pinned is
  'Kept at the top of the list for the row it is about. Nothing reads '
  'it yet -- the table has no screen; see docs/unreachable.md.';

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_using text;
begin
  select pg_get_expr(polqual, polrelid) into v_using
    from pg_policy
   where polrelid = 'public.notes'::regclass and polname = 'notes_select';

  if v_using is null or v_using !~ 'can_read_attachment' then
    raise exception 'reading a note no longer asks what the row asks: %',
      coalesce(v_using, '(no policy)');
  end if;

  -- The one that would undo the whole migration quietly: the old
  -- policy's question, still there.
  if v_using ~ 'is_org_member' then
    raise exception 'a note is still readable by the whole company';
  end if;

  select pg_get_expr(polqual, polrelid) into v_using
    from pg_policy
   where polrelid = 'public.notes'::regclass and polname = 'notes_update';
  if v_using is null or v_using !~ 'created_by' then
    raise exception 'anybody can still edit anybody''s note';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.notes'::regclass
                    and tgname = 'set_note_author') then
    raise exception 'nothing records who wrote a note';
  end if;
end $do$;
