-- =====================================================================
-- iAkauntan :: 0848 the paper stays where it was filed
--
-- `0708` made a file EVIDENCE when the record it is filed against is
-- posted, or a successful reading of it filled that record in -- and
-- refused deleting the row. Only the row, and only a delete. The row
-- could still be rewritten, and the file it names lives in the
-- `attachments` bucket, where the storage policies ask only whether
-- you may attach to that record.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`, on a posted invoice's signed purchase order: the
-- row pointed at another file -- a new name, path and hash -- was
-- accepted; the row moved off the posted invoice onto a draft was
-- accepted, leaving the invoice with no paper at all; the object
-- renamed in storage was accepted; and the object deleted from
-- storage was accepted, the row still naming a file that was gone. The
-- app's own delete removed the object FIRST and the row second, so
-- when `0708` refused the row the file had already been lost.
--
-- Answered "guard the row and the file":
--
--   * `evidence_stays_as_filed` refuses a client's own change -- role
--     `authenticated` or `anon`, at the top trigger depth -- to any
--     column of an attachment that is evidence. The app's one update,
--     refiling a fresh capture from its placeholder onto the record it
--     became, moves a file whose record does not exist yet, which is
--     never evidence.
--
--   * `an_evidence_file_stays`, on `storage.objects` in the
--     `attachments` bucket only, refuses a client's delete of an
--     evidence file, and an update that changes what the file is: its
--     bucket or name (a move), or its version or eTag (an overwrite).
--     A timestamp is not what the file is, and passes. The bucket is not
--     versioned (`versioning_status` DISABLED in production), so a
--     delete there is a delete; were versioning turned on, a delete
--     would become an update of markers this does not read.
--
--   * The app deletes the row before the object, so a refused row
--     keeps its file.
--
-- The Storage API runs a client's request as that client's role and
-- writes the table before it touches the bytes, so a refusal here
-- leaves the bytes where they were. That is argued from the SQL, not
-- watched: `run_locally.sh` stubs `storage.objects` as a bare table.
-- `protect_objects_delete`, Supabase's own statement trigger, refuses a
-- delete that does not come through the Storage API before any row
-- trigger runs; this one asks the next question.
--
-- Production held seven attachments on 12 October, three of them
-- evidence, every file present. NOT security definer, either trigger:
-- a definer would always answer "the owner".
-- =====================================================================

create or replace function app.evidence_stays_as_filed()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if to_jsonb(new) is distinct from to_jsonb(old)
     and app.attachment_is_evidence(old.id) then
    raise exception
      '% is what this record was built from -- it is posted, or its '
      'figures were read off this page -- so it stays filed where it is, '
      'as the file it is. Section 82 of the Income Tax Act 1967 asks for '
      'the paperwork behind a return to be kept for seven years. A file '
      'nothing was built from can still be moved.',
      old.file_name
      using errcode = '42501';
  end if;
  return new;
end $$;

revoke all on function app.evidence_stays_as_filed()
  from public, anon, authenticated;

comment on function app.evidence_stays_as_filed() is
  'On attachments: refuses a client''s own change to an attachment that '
  'is evidence (app.attachment_is_evidence). Refiling a capture from its '
  'placeholder passes. 0848.';

create trigger evidence_stays_as_filed
  before update on public.attachments
  for each row execute function app.evidence_stays_as_filed();

create or replace function app.an_evidence_file_stays()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  o jsonb := to_jsonb(old);
  n jsonb := to_jsonb(new);
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1
     or old.bucket_id is distinct from 'attachments' then
    return coalesce(new, old);
  end if;

  -- What the file is has not moved: it was read, or a timestamp was.
  if tg_op = 'UPDATE'
     and n -> 'bucket_id' is not distinct from o -> 'bucket_id'
     and n -> 'name' is not distinct from o -> 'name'
     and n -> 'version' is not distinct from o -> 'version'
     and n -> 'metadata' -> 'eTag' is not distinct from o -> 'metadata' -> 'eTag' then
    return new;
  end if;

  -- As the client, and that is enough: a row is read under
  -- `can_read_attachment` of the same three segments its object's name
  -- carries (`attachment_path_ok`), and an object nobody may read is an
  -- object nobody may move or delete.
  if exists (select 1 from public.attachments a
              where a.storage_path = old.name
                and app.attachment_is_evidence(a.id)) then
    raise exception
      '% is what a record was built from -- it is posted, or its figures '
      'were read off this page -- so the file is not deleted, moved or '
      'written over. Section 82 of the Income Tax Act 1967 asks for the '
      'paperwork behind a return to be kept for seven years.',
      split_part(old.name, '/', 4)
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

revoke all on function app.an_evidence_file_stays()
  from public, anon, authenticated;

comment on function app.an_evidence_file_stays() is
  'On storage.objects, attachments bucket: refuses a client''s delete of '
  'an evidence file, or an update that moves or overwrites one. 0848.';

create trigger an_evidence_file_stays
  before update or delete on storage.objects
  for each row execute function app.an_evidence_file_stays();
