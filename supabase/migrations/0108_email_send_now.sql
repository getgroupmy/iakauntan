-- =====================================================================
-- iAkauntan :: 0108 send it now, send it somewhere else, and say what
-- happened
--
-- Three things the outbox could not answer.
--
-- ---------------------------------------------------------------------
-- 1. Send now
--
-- `email_document` queues; the schedule drains every half hour. That is
-- the right default and a poor answer to "the customer is on the phone".
-- The Outbox screen already had a Send now button, but it lived one
-- screen away from the document and nobody sending an invoice would find
-- it.
--
-- Nothing here sends. The split this system is built on does not move:
-- the database writes a row and never waits on a third party, and the
-- edge function is the only thing that can talk to Resend. What changes
-- is that the row records *which button was pressed*, so the app can
-- follow a queue with an immediate drain of that one message and the log
-- can say afterwards which it was.
--
-- `immediate` is therefore an intent, not an outcome. If the drain that
-- follows it fails — no network, mail not configured, provider down —
-- the row stays `queued` and the scheduler picks it up later. Send now
-- degrades to send soon rather than to lost, which is the behaviour you
-- want at 5pm on a Friday.
--
-- ---------------------------------------------------------------------
-- 2. Somewhere else
--
-- Already possible: `email_document(..., p_to => '…')` has always taken
-- an address and issued the share token against it. Nothing in the app
-- passed one, so every document went to whatever was on the customer
-- record. Sending a copy to a client's accountant, or to yourself before
-- it goes to the customer, needed a database call.
--
-- No change is required here for that. It is written down because the
-- absence looked like a missing feature and was a missing text field.
--
-- ---------------------------------------------------------------------
-- 3. The log
--
-- Also mostly already there — `email_outbox` records the address, the
-- status, when it was queued, when it was sent and what the provider
-- said — and readable, because the table's select policy is
-- `app.is_org_member(org_id)` and every row carries `document_id`. The
-- one fact it did not hold is the one this migration adds.
--
-- So there is no view and no reader function: the app selects the rows
-- it is already entitled to. A SECURITY DEFINER wrapper would only move
-- the policy somewhere harder to review.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which button was pressed
--
-- Defaulted, so the nightly reminders and everything already queued read
-- as `queued` without a backfill — which is what they were.
-- ---------------------------------------------------------------------
alter table public.email_outbox
  add column if not exists dispatch text not null default 'queued';

alter table public.email_outbox
  drop constraint if exists email_outbox_dispatch_ck;
alter table public.email_outbox
  add constraint email_outbox_dispatch_ck
  check (dispatch in ('queued', 'immediate'));

comment on column public.email_outbox.dispatch is
  'How the sender asked for it to go: queued (next scheduled drain) or '
  'immediate (the app drains this row straight after). An intent at the '
  'time of queueing, not a delivery outcome — read status for that.';

-- ---------------------------------------------------------------------
-- Queueing a document, now recording the choice
--
-- Dropped and recreated rather than `create or replace`, because a
-- different argument list makes an *overload* rather than a replacement.
-- Leaving both would mean two functions with the same name, one of which
-- silently ignores the new argument, and PostgREST picking between them
-- by the keys in the request body.
-- ---------------------------------------------------------------------
drop function if exists public.email_document(uuid, text, text, integer);

create or replace function public.email_document(
  p_document_id uuid,
  p_to text default null,
  p_template_code text default 'document_new',
  p_share_days integer default 30,
  p_dispatch text default 'queued')
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

  -- Cheap, and worth having: a typo in a hand-typed address is a
  -- message that goes nowhere and comes back as a provider error hours
  -- later. This is not RFC 5322 — it is the check that catches a missing
  -- @ and a trailing comma from a pasted list.
  if v_to !~ '^[^@[:space:],]+@[^@[:space:],]+\.[^@[:space:],]{2,}$' then
    raise exception '% does not look like an email address', v_to
      using errcode = '23514';
  end if;

  -- The token is issued against the address it is being sent to, so
  -- overriding the recipient issues a link for *that* person rather than
  -- reusing one cut for the customer.
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
     template_code, document_id, dispatch, created_by)
  values (
    d.org_id, v_to,
    app.render_email(t.subject, v_vars),
    app.render_email(t.body, v_vars),
    s.reply_to, coalesce(s.from_name, o.name),
    p_template_code, d.id, p_dispatch, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- The old signature's grant went with the old function. EXECUTE goes to
-- PUBLIC on a new function, so it has to be taken away before it is
-- given back — the lesson 0080 exists for.
-- ---------------------------------------------------------------------
revoke all on function public.email_document(uuid, text, text, integer, text)
  from public, anon;
grant execute on function public.email_document(uuid, text, text, integer, text)
  to authenticated;

-- =====================================================================
-- Everything that ever left the building
--
-- "Did the customer get this?" has three possible answers in this
-- system and they were in three places: a message in `email_outbox`, a
-- link in `document_share_links`, and a PDF that left no trace at all.
-- The first two are recorded well — the share table even counts opens,
-- which is the only evidence a document reached a human — so this does
-- not copy them into a fourth table. It records the one that was
-- missing and reads all three as one timeline.
--
-- Sales documents only, which is what the whole path is: sharing a
-- supplier a link to their own bill is not a thing anybody wants, and
-- neither emailing nor sharing has ever been offered for purchases.
-- =====================================================================

create table if not exists public.document_downloads (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  document_id  uuid not null references public.sales_documents (id) on delete cascade,
  format       text not null default 'pdf' check (format in ('pdf')),
  downloaded_by uuid references auth.users (id),
  downloaded_at timestamptz not null default now()
);

create index if not exists document_downloads_document
  on public.document_downloads (document_id, downloaded_at desc);

alter table public.document_downloads enable row level security;

drop policy if exists document_downloads_select on public.document_downloads;
create policy document_downloads_select on public.document_downloads
  for select to authenticated using (app.is_org_member(org_id));

-- No insert policy: written only through the function below, which sets
-- `org_id` from the document rather than trusting the caller for it.
revoke all on public.document_downloads from anon, authenticated;
grant select on public.document_downloads to authenticated;

-- ---------------------------------------------------------------------
-- Recording one
--
-- The PDF is built in the browser from data the user already has on
-- screen, so this cannot be enforced — somebody with the API could read
-- the document without calling it. It is a record of what the app did,
-- which is what "who sent the customer their invoice" actually asks,
-- not an access log. Worth being clear about rather than implying more.
-- ---------------------------------------------------------------------
create or replace function public.log_document_download(
  p_document_id uuid,
  p_format text default 'pdf')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org uuid;
  v_id  uuid;
begin
  select org_id into v_org from public.sales_documents
   where id = p_document_id and deleted_at is null;
  if v_org is null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  insert into public.document_downloads
    (org_id, document_id, format, downloaded_by)
  values (v_org, p_document_id, p_format, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- The timeline
--
-- SECURITY INVOKER, deliberately. Every table it reads already carries
-- an `app.is_org_member` select policy, so the caller's own rights
-- decide what comes back and there is nothing here to get wrong. A
-- definer wrapper would move that decision into a function body where
-- it would have to be re-implemented and could drift.
--
-- `at` is when the thing happened; `status` is what became of it; and
-- `detail` is the one extra fact per kind worth reading in a list —
-- which button was pressed, how many times a link was opened, what
-- format was taken.
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
         case e.dispatch when 'immediate' then 'sent now'
                         else 'queued' end::text,
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

revoke all on function public.log_document_download(uuid, text) from public, anon;
grant execute on function public.log_document_download(uuid, text) to authenticated;

revoke all on function public.document_activity(uuid) from public, anon;
grant execute on function public.document_activity(uuid) to authenticated;
