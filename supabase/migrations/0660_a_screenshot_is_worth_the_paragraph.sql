-- =====================================================================
-- Files on a feedback report
--
-- "The employer EPF column is blank" is a sentence somebody has to
-- write back about. The same sentence with a screenshot attached is a
-- bug report. `0460` built somewhere to say it is broken; this is the
-- part that shows it.
--
-- ---------------------------------------------------------------------
-- Why not the `attachments` table
--
-- There is already a general attachment table keyed by
-- `entity_table`/`entity_id`, and it is the wrong home for these, for
-- one reason that decides it: **it is org-scoped and feedback is not.**
--
--   * `feedback_reports.org_id` is NULLABLE, because platform staff
--     belong to no company and report bugs too. An `attachments` row
--     requires an org.
--   * A feedback report is readable by the reporter, by their own
--     company's admins, AND BY PLATFORM STAFF IN ANOTHER ORG
--     ENTIRELY -- that is the whole point of the feature. `attachments`
--     is readable by members of its org, so a platform administrator
--     could read the report and not the screenshot on it.
--
-- The second is the dangerous one, because it fails silently in the
-- direction of "the console shows a report with an attachment it
-- cannot open". So the read rule here is not approximated from another
-- table's: it is `app.can_see_feedback`, which is `0460`'s
-- `feedback_select` policy expressed once and used by the table, the
-- bucket and the console.
--
-- ---------------------------------------------------------------------
-- The bucket, and the lesson from 0405
--
-- The object key is `<report id>/<file>`, so the first path segment is
-- the scope -- the same shape the chat bucket uses.
--
-- `0405` is why `app.uuid_or_null` appears below rather than a cast.
-- A single object whose first segment was not a uuid made every policy
-- on that bucket raise on the cast, which does not fail one row: it
-- closes the bucket for everybody. A policy has to survive a badly
-- named object that is already in it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who may see the files on a report
-- ---------------------------------------------------------------------

-- `0460`'s `feedback_select` rule, as a function, so the table policy,
-- the storage policy and the console all ask the same question.
-- Changing who may read a report now changes who may read its files,
-- which is the only arrangement that cannot drift.
create or replace function app.can_see_feedback(p_report_id uuid)
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select exists (
    select 1
      from public.feedback_reports f
     where f.id = p_report_id
       and (
         f.reported_by = auth.uid()
         or app.is_platform_admin()
         or (f.org_id is not null and app.can_admin(f.org_id))
       )
  );
$$;

comment on function app.can_see_feedback(uuid) is
  'Whether the caller may read a feedback report and therefore its '
  'files. The same rule as 0460''s feedback_select policy, written '
  'once: the reporter, a platform administrator, or an admin of the '
  'company the report was filed against. Platform staff read across '
  'orgs deliberately -- that is what the feature is for.';

-- Attaching is narrower than reading, and deliberately so. An org
-- admin can READ a colleague's report; adding files to it would mean
-- putting a document under somebody else's name, on a record they
-- cannot edit. The reporter is the one describing the fault.
create or replace function app.can_attach_to_feedback(p_report_id uuid)
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select exists (
    select 1
      from public.feedback_reports f
     where f.id = p_report_id
       and f.reported_by = auth.uid()
  );
$$;

comment on function app.can_attach_to_feedback(uuid) is
  'Whether the caller may add a file to a feedback report. Narrower '
  'than can_see_feedback on purpose: only the person who filed it. An '
  'admin who can read a report cannot add a document under somebody '
  'else''s name.';

-- ---------------------------------------------------------------------
-- The rows
-- ---------------------------------------------------------------------
create table public.feedback_attachments (
  id            uuid primary key default gen_random_uuid(),
  report_id     uuid not null
                  references public.feedback_reports (id) on delete cascade,
  -- Cascade, unlike the report's own org reference. A screenshot of a
  -- bug has no meaning without the report it illustrates, and the
  -- storage object is removed alongside it by
  -- `delete_feedback_attachment`.
  uploaded_by   uuid references auth.users (id) on delete set null,
  storage_path  text not null unique,
  file_name     text not null,
  mime_type     text,
  file_size     integer not null,
  created_at    timestamptz not null default now(),
  constraint feedback_attachment_has_a_name
    check (nullif(btrim(file_name), '') is not null),
  -- Ten megabytes, matching the bucket's own limit. Two places, and
  -- both are needed: the bucket stops the upload, this stops a row
  -- claiming a size the object does not have.
  constraint feedback_attachment_is_not_enormous
    check (file_size > 0 and file_size <= 10485760),
  -- The path has to start with the report it belongs to, because that
  -- is what every storage policy below reads to decide who may see it.
  -- Without this a row could point at another report's object and the
  -- storage policy would cheerfully allow it.
  constraint feedback_attachment_path_names_its_report
    check (storage_path like report_id::text || '/%')
);

create index feedback_attachments_report_idx
  on public.feedback_attachments (report_id, created_at);

alter table public.feedback_attachments enable row level security;

create policy feedback_attachments_select on public.feedback_attachments
  for select to authenticated
  using (app.can_see_feedback(report_id));

create policy feedback_attachments_insert on public.feedback_attachments
  for insert to authenticated
  with check (
    uploaded_by = auth.uid()
    and app.can_attach_to_feedback(report_id)
  );

create policy feedback_attachments_delete on public.feedback_attachments
  for delete to authenticated
  using (
    uploaded_by = auth.uid()
    and app.can_attach_to_feedback(report_id)
  );

-- ---------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('feedback', 'feedback', false, 10485760)
on conflict (id) do nothing;

-- `app.uuid_or_null`, not a cast. See the header: 0405.
create policy feedback_files_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'feedback'
    and app.can_see_feedback(app.uuid_or_null(split_part(name, '/', 1)))
  );

create policy feedback_files_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'feedback'
    and app.can_attach_to_feedback(
          app.uuid_or_null(split_part(name, '/', 1)))
  );

create policy feedback_files_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'feedback'
    and owner = auth.uid()
    and app.can_attach_to_feedback(
          app.uuid_or_null(split_part(name, '/', 1)))
  );

-- ---------------------------------------------------------------------
-- Recording one
-- ---------------------------------------------------------------------

-- The object is uploaded by the client, which is the only party
-- holding the bytes; this records that it exists. Both halves are
-- guarded by the same function, so an upload the storage policy
-- allowed cannot fail to be recordable and vice versa.
create or replace function public.attach_feedback_file(
  p_report_id    uuid,
  p_storage_path text,
  p_file_name    text,
  p_file_size    integer,
  p_mime_type    text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id uuid;
  v_count integer;
begin
  if not app.can_attach_to_feedback(p_report_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- Five. Enough for a screenshot of the screen, one of the console
  -- and a file that reproduces it; few enough that nobody empties a
  -- downloads folder into a bug report. Counted here rather than left
  -- to the client, because the client is a browser.
  select count(*) into v_count
    from public.feedback_attachments where report_id = p_report_id;
  if v_count >= 5 then
    raise exception
      'A report can carry five files. Remove one to add another.'
      using errcode = '23514';
  end if;

  insert into public.feedback_attachments
    (report_id, uploaded_by, storage_path, file_name, file_size, mime_type)
  values
    (p_report_id, auth.uid(), p_storage_path, btrim(p_file_name),
     p_file_size, nullif(btrim(coalesce(p_mime_type, '')), ''))
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function
  public.attach_feedback_file(uuid, text, text, integer, text)
  from public, anon;
grant execute on function
  public.attach_feedback_file(uuid, text, text, integer, text)
  to authenticated;

comment on function
  public.attach_feedback_file(uuid, text, text, integer, text) is
  'Records a file already uploaded to the `feedback` bucket against a '
  'report. Only the reporter, at most five per report. The object '
  'itself is uploaded by the client, which is the only party holding '
  'the bytes.';

-- ---------------------------------------------------------------------
-- Reading them back
-- ---------------------------------------------------------------------
create or replace function public.feedback_files(p_report_id uuid)
returns table (
  id           uuid,
  file_name    text,
  mime_type    text,
  file_size    integer,
  storage_path text,
  created_at   timestamptz)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select a.id, a.file_name, a.mime_type, a.file_size, a.storage_path,
         a.created_at
    from public.feedback_attachments a
   where a.report_id = p_report_id
     and app.can_see_feedback(p_report_id)
   order by a.created_at;
$$;

revoke all on function public.feedback_files(uuid) from public, anon;
grant execute on function public.feedback_files(uuid) to authenticated;

comment on function public.feedback_files(uuid) is
  'The files on a report, for whoever may read the report itself. '
  'SECURITY DEFINER and therefore carrying its own check -- without '
  'the can_see_feedback clause this would return every report''s '
  'files to anybody who asked.';
