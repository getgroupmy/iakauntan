-- =====================================================================
-- iAkauntan :: 0405 one badly named file closed the whole bucket
--
-- Every storage policy in this schema reads the organization out of the
-- first segment of the object's path. Eleven of them do it with
-- `app.uuid_or_null(split_part(name, '/', 1))`, which returns null for
-- anything that is not a uuid. Four do it with a hard cast:
--
--     app.is_chat_participant((nullif(split_part(name,'/',1), ''))::uuid)
--
-- `nullif(..., '')` handles an *empty* first segment and nothing else.
-- A first segment that is present and is not a uuid does not evaluate
-- to null; it raises `22P02`, and a policy predicate that raises does
-- not deny a row, it fails the statement.
--
-- ---------------------------------------------------------------------
-- Measured, as a member of the company that owns the file
--
-- One well-formed row in the `mail` bucket, listed by an ordinary
-- member:
--
--     P6 before: the member can list 1 mail file(s)
--
-- then one row whose path begins `inbox/` rather than with a uuid --
-- the shape a service-role writer would leave -- and the same query, by
-- the same member, for their own company's files:
--
--     P6 after: listing FAILED for everyone
--               22P02 invalid input syntax for type uuid: "inbox"
--
-- Not a leak. Nobody sees anything they should not. What happens is
-- worse in a different direction: **one badly named object makes the
-- bucket unreadable for every user of it**, because the policy is
-- evaluated per row and one row that raises aborts the whole statement.
-- Their own attachments, their own conversations, gone behind an error
-- that names a path they have never heard of.
--
-- ---------------------------------------------------------------------
-- Is it reachable today? Not without a second bug, and that is the point
--
-- Honest answer: nothing writes such a path now. `mail_files.ts` builds
-- `${orgId}/${emailId}/${index}-${name}` from an org id it looked up,
-- and the chat client builds a conversation id the same way. And a
-- client cannot insert a bad row through the front door, because the
-- *write* policy carries the same cast and raises before the row lands.
--
-- So this is a blast radius, not an open door. The reason to close it
-- anyway is that the writers are edge functions holding the service
-- role, which is outside RLS entirely -- one wrong path from any of
-- them, today or in a later change, takes out a whole bucket for every
-- company on the platform rather than failing on its own row. That is a
-- great deal of consequence to leave resting on a string being
-- well-formed, when the schema already has the function that makes it
-- not matter and uses it everywhere else.
--
-- ---------------------------------------------------------------------
-- The fix is the house idiom, and it only ever narrows
--
-- `app.uuid_or_null` returns null for a non-uuid, and both helpers
-- refuse a null -- measured, not assumed:
--
--     app.is_chat_participant(null) = false
--     app.has_module(null, 'mailbox') = false
--     app.is_org_member(null)         = false
--
-- so a badly named row becomes a row nobody can see, which is what a
-- row nobody can name an owner for should be. No caller loses anything:
-- every path that is a uuid evaluates exactly as before.
--
-- `nullif(..., '')` is dropped because it is subsumed --
-- `app.uuid_or_null('')` is already null.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The three chat policies (`0138`)
-- ---------------------------------------------------------------------
drop policy if exists chat_files_read on storage.objects;
create policy chat_files_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat'
    and app.is_chat_participant(app.uuid_or_null(split_part(name, '/', 1)))
  );

drop policy if exists chat_files_write on storage.objects;
create policy chat_files_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat'
    and app.is_chat_participant(app.uuid_or_null(split_part(name, '/', 1)))
  );

drop policy if exists chat_files_delete on storage.objects;
create policy chat_files_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'chat'
    and owner = auth.uid()
    and app.is_chat_participant(app.uuid_or_null(split_part(name, '/', 1)))
  );

-- ---------------------------------------------------------------------
-- And the mail one (`0354`)
-- ---------------------------------------------------------------------
drop policy if exists mail_files_read on storage.objects;
create policy mail_files_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'mail'
    and app.is_org_member(app.uuid_or_null(split_part(name, '/', 1)))
    and app.has_module(app.uuid_or_null(split_part(name, '/', 1)), 'mailbox')
  );

-- ---------------------------------------------------------------------
-- And nothing anywhere still casts
-- ---------------------------------------------------------------------
-- Asked of the catalogue rather than of this file, because the four
-- above were found that way: every policy in the database whose
-- expression contains `::uuid`. There is no legitimate use of it in a
-- policy over a path -- `app.uuid_or_null` exists for exactly this --
-- so the right number is zero, and a fifth one written next year fails
-- here.
do $do$
declare v_left text;
begin
  select string_agg(n.nspname || '.' || c.relname || '.' || p.polname, ', '
                    order by n.nspname, c.relname, p.polname)
    into v_left
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where coalesce(pg_get_expr(p.polqual, p.polrelid), '') ~ '::uuid'
      or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ~ '::uuid';

  if v_left is not null then
    raise exception
      'FAIL 0405: % still casts a path segment to uuid inside a policy. '
      'A cast that raises does not deny a row, it fails the statement, '
      'and one badly named object then closes the bucket for everybody. '
      'Use app.uuid_or_null, which every other policy here uses.',
      v_left;
  end if;
  raise notice
    '0405: no policy casts a path segment to uuid; a badly named object '
    'is now invisible rather than fatal';
end
$do$;
