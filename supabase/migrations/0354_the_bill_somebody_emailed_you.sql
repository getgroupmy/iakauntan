-- =====================================================================
-- iAkauntan :: 0354 the bill somebody emailed you
--
-- `0328` gave every company an address of its own and built everything
-- an attachment needs: a table for it, a read policy scoped to the
-- company that owns the mailbox, a `select` grant, and a `raw_path`
-- column on the message for the original. Then the pipeline never
-- wrote any of it.
--
-- `cloudflare/email-router/worker.js` posts `{ to, from, message_id,
-- subject, text, html }`. Its `split()` walks the MIME parts and keeps
-- the two it recognises — `text/plain` and `text/html` — and drops
-- every other part on the floor. `receive-email` has no attachment
-- field to receive one with, and `receive_email` has no argument to
-- store one through.
--
-- So a supplier emails a PDF invoice to `bills@sinar.iakauntan.com`,
-- the covering note arrives, and the invoice does not. Nothing says so:
-- the message is there, it reads as if it were the whole of what was
-- sent, and the only sign is the sentence in the body referring to an
-- attachment that is not there. Worse than a failure, because a failure
-- would be noticed.
--
-- This closes it end to end: a bucket, a writer the ingest path can
-- reach and nobody else can, and a reader for the app.
--
-- ## Where the files go
--
-- A bucket of their own rather than `attachments`. What a company
-- attaches to its own invoice and what a stranger posted through the
-- letterbox are different things with different provenance, and the
-- policy on this one has to say "the company that owns the mailbox
-- this arrived at" rather than "the company that uploaded it" — nobody
-- uploaded it. Keeping them apart also means an attachment that turns
-- out to be malware can be dealt with as a class.
--
-- The path is `<org_id>/<email_id>/<n>-<name>`, so the policy can read
-- the owning company out of the first segment the way `0010` and `0138`
-- both do rather than joining back to a table on every object.
--
-- ## Nothing here is written by a client
--
-- `record_inbound_attachment` is granted to `service_role` alone, for
-- the reason `0328` gives about `receive_email`: a client that could
-- write to this table could invent a document that appears to have
-- arrived from somebody. The bucket has no insert policy for
-- `authenticated` at all, so the same is true of the bytes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The bucket
-- ---------------------------------------------------------------------
--
-- 25 MB, matching `attachments` and `chat`. A message bigger than that
-- is one Cloudflare will have declined before this ever sees it.
insert into storage.buckets (id, name, public, file_size_limit)
values ('mail', 'mail', false, 26214400)
on conflict (id) do nothing;

-- Read by the company the mailbox belongs to, and by nobody else — the
-- same sentence `0328` wrote for `inbound_emails`, including the part
-- about platform staff. Mail is the most private thing on the platform.
drop policy if exists mail_files_read on storage.objects;
create policy mail_files_read on storage.objects
  for select to authenticated
  using (bucket_id = 'mail'
         and app.is_org_member(
               nullif(split_part(name, '/', 1), '')::uuid)
         and app.has_module(
               nullif(split_part(name, '/', 1), '')::uuid, 'mailbox'));

-- No insert, update or delete policy for `authenticated`, deliberately.
-- The ingest path writes under the service role, which policies do not
-- apply to, and nothing else has any business putting a file in here or
-- taking one out. What arrived is what arrived.

-- ---------------------------------------------------------------------
-- Recording one
-- ---------------------------------------------------------------------
create or replace function public.record_inbound_attachment(
  p_email_id     uuid,
  p_filename     text,
  p_content_type text,
  p_size_bytes   bigint,
  p_storage_path text
)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_id  uuid;
begin
  select org_id into v_org from public.inbound_emails where id = p_email_id;
  if v_org is null then
    raise exception 'No such message.' using errcode = 'P0002';
  end if;

  -- The path decides who may read the bytes, so a path that does not
  -- start with the owning company would hand this message's attachment
  -- to a different company's members. Checked here rather than trusted,
  -- because the caller composes it.
  if p_storage_path is null
     or split_part(p_storage_path, '/', 1) <> v_org::text then
    raise exception
      'An attachment is filed under the company whose mailbox it '
      'arrived at, and % is not.', coalesce(p_storage_path, '<null>')
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_filename), '') = '' then
    raise exception 'An attachment needs a filename.' using errcode = '23514';
  end if;

  -- Delivered twice is what a retry looks like, and `receive_email`
  -- already answers that for the message itself by doing nothing on a
  -- repeated Message-ID. A retry that got past that would be recording
  -- the same file against the same message a second time.
  select a.id into v_id
    from public.inbound_email_attachments a
   where a.email_id = p_email_id and a.storage_path = p_storage_path;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.inbound_email_attachments
    (email_id, filename, content_type, size_bytes, storage_path)
  values (p_email_id, btrim(p_filename), p_content_type,
          greatest(coalesce(p_size_bytes, 0), 0), p_storage_path)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.record_inbound_attachment(
  uuid, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.record_inbound_attachment(
  uuid, text, text, bigint, text) to service_role;

comment on function public.record_inbound_attachment(
  uuid, text, text, bigint, text) is
  'Files an attachment against a message that arrived at a reserved address. Service role only: the ingest path is the edge function and nothing else.';

-- Repeated delivery is the case this exists for, so it is an index
-- rather than a scan of a table that grows with every message.
create unique index if not exists inbound_email_attachments_path_idx
  on public.inbound_email_attachments (email_id, storage_path);

-- ---------------------------------------------------------------------
-- Reading them
-- ---------------------------------------------------------------------
--
-- The read policy on the table already says who may see these, so this
-- adds nothing to it — what it adds is the message's own org_id, which
-- the client needs to build a storage path and which the attachment row
-- does not carry.
create or replace function public.inbound_attachments(p_email_id uuid)
returns table (
  id           uuid,
  filename     text,
  content_type text,
  size_bytes   bigint,
  storage_path text)
language sql
stable
set search_path = public, app, pg_temp as $$
  select a.id, a.filename, a.content_type, a.size_bytes, a.storage_path
    from public.inbound_email_attachments a
   where a.email_id = p_email_id
   order by a.filename;
$$;

revoke all on function public.inbound_attachments(uuid) from public, anon;
grant execute on function public.inbound_attachments(uuid) to authenticated;

comment on function public.inbound_attachments(uuid) is
  'What came attached to one message. Runs as the caller, so the read policy on inbound_email_attachments still decides.';
