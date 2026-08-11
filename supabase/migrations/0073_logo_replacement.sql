-- =====================================================================
-- iAkauntan :: 0073 replacing a company logo
--
-- The `logos` bucket had an INSERT policy and nothing else, so a company
-- could upload a logo exactly once. Uploading again to the same path is
-- an UPDATE as far as storage is concerned, and with no UPDATE policy it
-- was refused — which reads as "the upload failed" rather than "you are
-- not allowed to change your mind".
--
-- Same admin check as the insert, and the same path rule: the first
-- segment of the object name is the organization that owns it, so one
-- company cannot overwrite another's mark.
-- =====================================================================

create policy logos_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'logos'
    and app.can_admin((nullif(split_part(name, '/', 1), ''))::uuid)
  )
  with check (
    bucket_id = 'logos'
    and app.can_admin((nullif(split_part(name, '/', 1), ''))::uuid)
  );

create policy logos_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'logos'
    and app.can_admin((nullif(split_part(name, '/', 1), ''))::uuid)
  );
