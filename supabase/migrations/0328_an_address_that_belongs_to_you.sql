-- A company's own address on the platform's domain:
-- xxxx@iakauntan.com, sending and receiving.
--
-- Asked for as a module of its own, beside `workspace_address` and not
-- part of it: a company may want the address without the door, or the
-- door without the address, and mail costs money in a different shape
-- from a name in DNS.
--
-- ## Sending was nearly here already
--
-- `0095` queues outbound mail in `email_outbox` and `send-email` drains
-- it through Resend under one verified sender, `MAIL_FROM`. All this
-- adds is a column: a message may name its own sender, and the function
-- refuses any sender the company has not been granted. The secret stays
-- exactly where it was — in the edge function's environment, never in a
-- row and never in the bundle.
--
-- ## Receiving is new
--
-- Mail for `@iakauntan.com` reaches Cloudflare Email Routing on the
-- domain's MX records, which hands each message to a worker, which
-- posts it to the `receive-email` function. That function is the only
-- thing that writes here, under the service role, through
-- `app.receive_email` — so a client holding the publishable key cannot
-- invent a message that appears to have arrived from somebody.
--
-- What lands is kept whole: the parsed fields for the screen, and the
-- raw message in storage for when the parse was wrong. Mail to an
-- address nobody has reserved is dropped rather than stored, because
-- keeping it would make this table the platform's spam folder.
--
-- The MX records and the worker are not in this repository. Until they
-- are in place every row here is correct and nothing arrives.

-- ---------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order, is_active)
values
  ('mailbox', 'Your own email address',
   'Send and receive at your name on our domain - hello@iakauntan.com. '
   'Mail arrives in the app against the company it was sent to, and '
   'anything you send can go out from that address instead of ours.',
   false, 29.00, 111, true)
on conflict (code) do update
  set name          = excluded.name,
      description   = excluded.description,
      monthly_price = excluded.monthly_price,
      is_active     = excluded.is_active;

-- ---------------------------------------------------------------------
-- What a company has asked for, and what it was given
-- ---------------------------------------------------------------------
-- The same request-and-decide shape as `0327`, and for the same reason:
-- one domain, one namespace, and `billing@iakauntan.com` in a
-- stranger's hands is worth more to them than any subdomain. The
-- blocklist is literally the same table.
create table if not exists public.org_mailboxes (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null
               references public.organizations (id) on delete cascade,

  -- The part before the @. Stored folded by `app.normalize_host_label`,
  -- because mail routing treats the local part case-insensitively in
  -- practice however RFC 5321 permits it not to.
  local_part   text not null unique,

  status       text not null default 'requested'
               check (status in ('requested', 'approved', 'refused')),

  requested_by uuid references auth.users (id) on delete set null,
  requested_at timestamptz not null default now(),
  decided_by   uuid references auth.users (id) on delete set null,
  decided_at   timestamptz,
  note         text,

  constraint org_mailboxes_decided
    check ((status = 'requested') = (decided_at is null))
);

-- More than one, unlike the subdomain: sales@ and support@ at one
-- company are two addresses doing two jobs, not two doors into one
-- workspace.
create index if not exists org_mailboxes_org_idx
  on public.org_mailboxes (org_id, status);

comment on table public.org_mailboxes is
  'Addresses on the platform domain, one row per local part. Only an '
  'approved row sends or receives.';

-- ---------------------------------------------------------------------
-- What arrived
-- ---------------------------------------------------------------------
create table if not exists public.inbound_emails (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null
              references public.organizations (id) on delete cascade,
  mailbox_id  uuid not null
              references public.org_mailboxes (id) on delete cascade,

  -- The sender's own Message-ID. Unique, so the same message delivered
  -- twice - which happens, and is what a retry looks like - lands once.
  message_id  text not null unique,

  from_email  citext not null,
  from_name   text,
  to_email    citext not null,
  subject     text,
  body_text   text,
  body_html   text,

  -- Where the whole thing sits in the `attachments` bucket, for when
  -- the parse above was wrong about something.
  raw_path    text,

  received_at timestamptz not null default now(),
  read_at     timestamptz,

  -- Turned into a ticket, for a company that also has the service desk.
  -- Nullable and un-enforced in both directions: a message need not
  -- become anything, and a company without ticketing still gets its
  -- mail.
  ticket_id   uuid
);

create index if not exists inbound_emails_org_idx
  on public.inbound_emails (org_id, received_at desc);
create index if not exists inbound_emails_unread_idx
  on public.inbound_emails (org_id) where read_at is null;

comment on table public.inbound_emails is
  'Mail that arrived at a reserved address. Written only by the ingest '
  'function under the service role: nothing a client can reach can '
  'invent a message that appears to have come from somebody.';

create table if not exists public.inbound_email_attachments (
  id          uuid primary key default gen_random_uuid(),
  email_id    uuid not null
              references public.inbound_emails (id) on delete cascade,
  filename    text not null,
  content_type text,
  size_bytes  bigint,
  storage_path text not null
);

create index if not exists inbound_email_attachments_email_idx
  on public.inbound_email_attachments (email_id);

-- ---------------------------------------------------------------------
-- Sending from the address, rather than from ours
-- ---------------------------------------------------------------------
alter table public.email_outbox
  add column if not exists from_email citext;

comment on column public.email_outbox.from_email is
  'The reserved address this goes out from, or null for the platform''s '
  'own sender. Checked against `org_mailboxes` on the way in, so a '
  'company cannot queue mail as somebody else by writing a row.';

-- The domain the platform's addresses live on. A setting rather than a
-- literal, so a deployment under another name does not need this
-- migration edited - which it could not be, once applied.
create or replace function app.mail_domain()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- `platform_settings.value` is jsonb, and `#>> '{}'` is how a jsonb
  -- string gives up its text without the quotes around it.
  select coalesce(
    nullif((select value #>> '{}' from public.platform_settings
             where key = 'mail_domain'), ''),
    'iakauntan.com');
$$;

insert into public.platform_settings (key, value, description)
values ('mail_domain', to_jsonb('iakauntan.com'::text),
        'The domain reserved addresses are issued on.')
on conflict (key) do nothing;

create or replace function app.check_outbox_sender()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.from_email is null then
    return new;
  end if;

  if not exists (
    select 1
      from public.org_mailboxes m
     where m.org_id = new.org_id
       and m.status = 'approved'
       and lower(new.from_email) =
           m.local_part || '@' || app.mail_domain()
  ) then
    raise exception 'This company may not send as %', new.from_email;
  end if;

  return new;
end;
$$;

drop trigger if exists email_outbox_sender on public.email_outbox;
create trigger email_outbox_sender
  before insert or update of from_email on public.email_outbox
  for each row execute function app.check_outbox_sender();

-- ---------------------------------------------------------------------
-- Asking, and deciding
-- ---------------------------------------------------------------------
create or replace function public.request_mailbox(
  p_org_id uuid,
  p_local_part text
)
returns public.org_mailboxes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name    text := app.normalize_host_label(p_local_part);
  v_problem text;
  v_row     public.org_mailboxes;
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an owner or administrator can ask for an address';
  end if;

  if not app.has_module(p_org_id, 'mailbox') then
    raise exception 'This company does not have the email address module';
  end if;

  v_problem := app.check_host_label(v_name, 'mailbox');
  if v_problem is not null then
    raise exception '%', v_problem;
  end if;

  insert into public.org_mailboxes (org_id, local_part, requested_by)
  values (p_org_id, v_name, auth.uid())
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'That address is already taken.';
end;
$$;

create or replace function public.decide_mailbox(
  p_id uuid,
  p_approve boolean,
  p_note text default null
)
returns public.org_mailboxes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.org_mailboxes;
begin
  if not app.is_platform_admin() then
    raise exception 'Only platform staff can decide an address';
  end if;

  update public.org_mailboxes
     set status     = case when p_approve then 'approved' else 'refused' end,
         decided_by = auth.uid(),
         decided_at = now(),
         note       = p_note
   where id = p_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'No such request';
  end if;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Taking delivery
-- ---------------------------------------------------------------------
-- Called by `receive-email` under the service role and by nothing else.
-- Returns the row it wrote, or null when the address is not one we
-- carry - which is the ordinary case for a domain that receives mail at
-- all, and is not an error.
--
-- In `public` rather than `app` because PostgREST only exposes `public`
-- and `graphql_public`, and a function the edge function cannot reach
-- is a function that does nothing. What keeps it private is the grant
-- below, which names the service role and nobody else - the schema was
-- never the thing protecting it.
create or replace function public.receive_email(
  p_to         text,
  p_from       text,
  p_from_name  text,
  p_message_id text,
  p_subject    text,
  p_body_text  text,
  p_body_html  text,
  p_raw_path   text default null
)
returns public.inbound_emails
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_local text := app.normalize_host_label(split_part(p_to, '@', 1));
  v_box   public.org_mailboxes;
  v_row   public.inbound_emails;
begin
  select * into v_box
    from public.org_mailboxes
   where local_part = v_local
     and status = 'approved';

  -- Nobody's address. Dropped rather than stored: keeping it would make
  -- this table the platform's spam folder.
  if v_box.id is null then
    return null;
  end if;

  -- The module can be switched off, and mail should stop arriving when
  -- it is. The reservation survives, so switching it back on does not
  -- lose the address to somebody else in the meantime.
  if not app.has_module(v_box.org_id, 'mailbox') then
    return null;
  end if;

  insert into public.inbound_emails (
    org_id, mailbox_id, message_id, from_email, from_name,
    to_email, subject, body_text, body_html, raw_path
  )
  values (
    v_box.org_id, v_box.id, p_message_id, p_from, p_from_name,
    p_to, p_subject, p_body_text, p_body_html, p_raw_path
  )
  -- Delivered twice is what a retry looks like. Landing once is the
  -- point of the sender's Message-ID.
  on conflict (message_id) do nothing
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- Who may see what
-- ---------------------------------------------------------------------
alter table public.org_mailboxes enable row level security;
alter table public.inbound_emails enable row level security;
alter table public.inbound_email_attachments enable row level security;

drop policy if exists org_mailboxes_read on public.org_mailboxes;
create policy org_mailboxes_read on public.org_mailboxes
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());

drop policy if exists org_mailboxes_write on public.org_mailboxes;
create policy org_mailboxes_write on public.org_mailboxes
  for all to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

-- Mail is read by the company it was addressed to, and by nobody else -
-- not even platform staff, who can see that an address exists but have
-- no business reading what arrives at it.
drop policy if exists inbound_emails_read on public.inbound_emails;
create policy inbound_emails_read on public.inbound_emails
  for select to authenticated
  using (app.is_org_member(org_id) and app.has_module(org_id, 'mailbox'));

-- Marking one read is the only thing a person does to it. Nothing here
-- may be written or deleted by a client: what arrived is what arrived.
drop policy if exists inbound_emails_mark on public.inbound_emails;
create policy inbound_emails_mark on public.inbound_emails
  for update to authenticated
  using (app.can_write(org_id) and app.has_module(org_id, 'mailbox'))
  with check (app.can_write(org_id) and app.has_module(org_id, 'mailbox'));

drop policy if exists inbound_email_attachments_read
  on public.inbound_email_attachments;
create policy inbound_email_attachments_read
  on public.inbound_email_attachments
  for select to authenticated
  using (exists (
    select 1 from public.inbound_emails e
     where e.id = email_id
       and app.is_org_member(e.org_id)
       and app.has_module(e.org_id, 'mailbox')
  ));

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
-- `0165`'s event trigger strips grants from anything recreated in
-- `public` or `app`, so everything above is re-granted here.
revoke all on function public.request_mailbox(uuid, text) from public;
revoke all on function public.decide_mailbox(uuid, boolean, text) from public;
revoke all on function app.mail_domain() from public;
revoke all on function app.check_outbox_sender() from public;

-- Deliberately granted to nobody but the service role: the ingest path
-- is the edge function and nothing else.
revoke all on function public.receive_email(
  text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.receive_email(
  text, text, text, text, text, text, text, text) to service_role;

grant execute on function public.request_mailbox(uuid, text) to authenticated;
grant execute on function public.decide_mailbox(uuid, boolean, text) to authenticated;
grant execute on function app.mail_domain() to authenticated;

-- Nothing here is anonymous. Mail is the most private thing on the
-- platform and an anonymous reader has no business with any of it.
revoke all on public.org_mailboxes from anon;
revoke all on public.inbound_emails from anon;
revoke all on public.inbound_email_attachments from anon;

grant select on public.org_mailboxes to authenticated;
grant insert, update, delete on public.org_mailboxes to authenticated;
grant select, update on public.inbound_emails to authenticated;
grant select on public.inbound_email_attachments to authenticated;
