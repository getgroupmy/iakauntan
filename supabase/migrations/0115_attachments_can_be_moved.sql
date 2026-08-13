-- =====================================================================
-- iAkauntan :: 0115 a file may be moved, not only put down and picked up
--
-- 0068 gave the attachments bucket three of the four verbs: read, write
-- and delete. Nothing could *move* an object, and for a long time
-- nothing needed to.
--
-- Scanning a receipt needs to. The paper is captured before the record
-- it belongs to exists — that is the whole shape of the feature, since
-- somebody photographs a receipt and then decides what it was — so the
-- file is parked against a placeholder and moved onto the expense or the
-- bill once that has an id. The object has to move with the row: the
-- storage policies read the organization, the table and the record
-- straight out of the object name, so a row repointed on its own would
-- be refused by the trigger, and an object left behind would be
-- unreadable to everyone who could reach the record.
--
-- Supabase implements a move as an UPDATE on `storage.objects`. With no
-- UPDATE policy, RLS refused it — and refused it as
--
--     StorageException(message: Object not found, statusCode: 404)
--
-- which is the least helpful true thing it could have said. A row you
-- may not see and a row that is not there are indistinguishable through
-- RLS, so a missing policy arrives looking like missing data.
--
-- Both halves are checked, and they are not the same question. `using`
-- asks whether you may take the file from where it is; `with_check`
-- asks whether where you are putting it is somewhere you could have
-- uploaded to in the first place — same organization, same four-part
-- shape as `attachments_write`. Without the second, a move would be a
-- way to write an object into a path no upload would have accepted.
-- =====================================================================

drop policy if exists attachments_move on storage.objects;
create policy attachments_move on storage.objects
  for update to authenticated
  using (
    bucket_id = 'attachments'
    and app.can_write(app.uuid_or_null(split_part(name, '/', 1))))
  with check (
    bucket_id = 'attachments'
    and app.can_write(app.uuid_or_null(split_part(name, '/', 1)))
    and split_part(name, '/', 2) <> ''
    and app.uuid_or_null(split_part(name, '/', 3)) is not null
    and split_part(name, '/', 4) <> '');
