-- =====================================================================
-- iAkauntan :: 0109 attach the PDF, or just send the link
--
-- Until now every message carried a link and nothing else. A link is the
-- better default — it is always the current document, it records that
-- somebody opened it, and it does not sit in a mailbox looking
-- authoritative six months after the invoice was revised. But plenty of
-- customers file a PDF, some accounts departments will not click a link
-- at all, and "please attach it" is not a request anybody should have to
-- refuse.
--
-- So: optional, off by default, and the link stays either way.
--
-- ---------------------------------------------------------------------
-- Where the file lives
--
-- In the `attachments` bucket, under the path convention 0068 already
-- enforces: {org_id}/{entity_type}/{entity_id}/{filename}. That is not a
-- coincidence being exploited — it is the convention, and it means this
-- migration adds no storage policy at all. Writing is already gated on
-- `app.can_write(org)` and reading on `app.can_read_attachment(...)`,
-- both keyed off the path itself.
--
-- The PDF is rendered in the browser, because that is the only place the
-- renderer exists. The client uploads it and passes the path; this
-- function checks the path is the caller's own organization and this
-- document, so a path pointing anywhere else is refused rather than
-- attached.
--
-- The edge function reads it with the service role when it sends, which
-- is why nothing here needs a signed URL: the bytes never travel through
-- a link that could outlive the message.
-- =====================================================================

alter table public.email_outbox
  add column if not exists attachment_path text,
  add column if not exists attachment_name text;

comment on column public.email_outbox.attachment_path is
  'Object name in the `attachments` bucket, or null for link-only. Read '
  'by the send-email function with the service role at send time.';

-- ---------------------------------------------------------------------
-- Queueing, with an optional attachment
--
-- Dropped and recreated for the same reason as 0108: a longer argument
-- list overloads rather than replaces, and two `email_document`s would
-- let PostgREST pick by request body.
-- ---------------------------------------------------------------------
drop function if exists public.email_document(uuid, text, text, integer, text);

create or replace function public.email_document(
  p_document_id uuid,
  p_to text default null,
  p_template_code text default 'document_new',
  p_share_days integer default 30,
  p_dispatch text default 'queued',
  p_attachment_path text default null,
  p_attachment_name text default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  d public.sales_documents;
  o public.organizations;
  c public.contacts;
  s public.email_settings;
  t record;
  v_to text;
  v_link text;
  v_vars jsonb;
  v_id uuid;
  v_path text := nullif(btrim(coalesce(p_attachment_path, '')), '');
begin
  if p_dispatch not in ('queued', 'immediate') then
    raise exception 'Dispatch must be queued or immediate, not %', p_dispatch
      using errcode = '23514';
  end if;

  select * into d from public.sales_documents where id = p_document_id;
  if d.id is null or d.deleted_at is not null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not app.can_write(d.org_id) then
    raise exception 'Not permitted to send this document'
      using errcode = '42501';
  end if;

  -- An attachment path is a claim about a file the caller uploaded, and
  -- it arrives from the client. Anchoring it to this organization *and*
  -- this document is what stops one being pointed at somebody else's
  -- upload and mailed out — the storage policy governs who may write
  -- there, not what a queued message may reference.
  if v_path is not null then
    if split_part(v_path, '/', 1) <> d.org_id::text
       or split_part(v_path, '/', 2) <> 'sales_documents'
       or split_part(v_path, '/', 3) <> p_document_id::text
       or split_part(v_path, '/', 4) = '' then
      raise exception
        'An attachment must live under %/sales_documents/%/', d.org_id,
        p_document_id using errcode = '42501';
    end if;
  end if;

  select * into o from public.organizations where id = d.org_id;
  select * into c from public.contacts where id = d.contact_id;
  select * into s from public.email_settings where org_id = d.org_id;

  if not coalesce(s.is_enabled, false) then
    raise exception 'Email is switched off for this organization'
      using errcode = '22023';
  end if;

  v_to := coalesce(
    nullif(btrim(p_to), ''),
    (select cp.email::text from public.contact_persons cp
      where cp.contact_id = d.contact_id and cp.is_primary limit 1),
    c.email::text);

  if v_to is null then
    raise exception 'No address to send to; add one to the customer'
      using errcode = '23514';
  end if;

  if v_to !~ '^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]{2,}$' then
    raise exception '% does not look like an email address', v_to
      using errcode = '23514';
  end if;

  v_link := null;
  if d.status not in ('draft', 'void', 'rejected') then
    v_link := app.share_url(app.issue_share_token(p_document_id, p_share_days, v_to));
  end if;

  select * into t from app.email_template(d.org_id, p_template_code);
  if t.subject is null then
    raise exception 'No template called %', p_template_code using errcode = 'P0002';
  end if;

  v_vars := app.document_email_vars(d.id, v_link);

  insert into public.email_outbox
    (org_id, to_email, subject, body, reply_to, from_name,
     template_code, document_id, dispatch,
     attachment_path, attachment_name, created_by)
  values (
    d.org_id, v_to,
    app.render_email(t.subject, v_vars),
    app.render_email(t.body, v_vars),
    s.reply_to, coalesce(s.from_name, o.name),
    p_template_code, d.id, p_dispatch,
    v_path,
    case when v_path is null then null
         else coalesce(nullif(btrim(p_attachment_name), ''),
                       split_part(v_path, '/', 4))
    end,
    auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.email_document(
  uuid, text, text, integer, text, text, text) from public, anon;
grant execute on function public.email_document(
  uuid, text, text, integer, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- The trail says whether a file went with it
--
-- Because "I sent you the invoice" and "I sent you a link to the
-- invoice" are different claims, and a month later somebody needs to
-- know which one was made.
-- ---------------------------------------------------------------------
create or replace function public.document_activity(p_document_id uuid)
returns table (
  at        timestamptz,
  kind      text,
  recipient text,
  status    text,
  detail    text,
  note      text)
language sql stable
set search_path = public, app, pg_temp as $$
  select e.queued_at,
         'email'::text,
         e.to_email::text,
         e.status::text,
         (case e.dispatch when 'immediate' then 'sent now' else 'queued' end
          || case when e.attachment_path is not null
                  then ' · PDF attached' else ' · link only' end)::text,
         case
           when e.status = 'sent' and e.sent_at is not null
             then 'delivered to the provider ' ||
                  to_char(e.sent_at at time zone 'Asia/Kuala_Lumpur',
                          'DD Mon YYYY HH24:MI')
           when e.last_error is not null then e.last_error
           else null
         end::text
    from public.email_outbox e
   where e.document_id = p_document_id

  union all

  select l.created_at,
         'share link'::text,
         l.sent_to_email::text,
         case
           when l.revoked_at is not null then 'revoked'
           when l.expires_at < now() then 'expired'
           when l.opened_at is not null then 'opened'
           else 'live'
         end::text,
         case
           when coalesce(l.open_count, 0) = 0 then 'never opened'
           when l.open_count = 1 then 'opened once'
           else 'opened ' || l.open_count || ' times'
         end::text,
         case when l.last_opened_at is not null
              then 'last opened ' ||
                   to_char(l.last_opened_at at time zone 'Asia/Kuala_Lumpur',
                           'DD Mon YYYY HH24:MI')
              else null
         end::text
    from public.document_share_links l
   where l.document_id = p_document_id

  union all

  select d.downloaded_at,
         'pdf'::text,
         null::text,
         'downloaded'::text,
         d.format::text,
         null::text
    from public.document_downloads d
   where d.document_id = p_document_id

  order by 1 desc;
$$;

revoke all on function public.document_activity(uuid) from public, anon;
grant execute on function public.document_activity(uuid) to authenticated;
