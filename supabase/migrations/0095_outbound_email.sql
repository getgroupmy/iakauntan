-- Letting the system say something to somebody outside it.
--
-- Until now nothing has ever left iAkauntan. A document becomes a PDF
-- and the person who made it takes over by hand, which means nobody is
-- ever chased for payment: `balance_amount` and `due_date` have been
-- sitting there for months with nothing reading them for that purpose.
--
-- Three pieces, and the split matters:
--
--   `email_templates`  what to say, editable per organization, with
--                      built-in text for anybody who has not edited it.
--   `email_outbox`     one row per message, queued rather than sent
--                      inline — the database must not wait on a third
--                      party, and a failed send has to be visible and
--                      retryable rather than lost in a log.
--   `send-email`       an edge function holding the provider key,
--                      draining the outbox. It is the only thing in the
--                      system that talks to Resend.
--
-- Nothing here can send. Queueing is all the database does; the key
-- lives in the edge function's secrets and never in a migration, a
-- table or the app bundle.

-- ---------------------------------------------------------------------
-- Who mail comes from, and when to chase
-- ---------------------------------------------------------------------
create table if not exists public.email_settings (
  org_id        uuid primary key references public.organizations (id) on delete cascade,
  is_enabled    boolean not null default false,
  from_name     text,
  reply_to      text,

  -- Days after the due date to send a reminder. The zero is the due
  -- date itself; negatives are before it. Empty means never chase.
  reminder_days integer[] not null default '{}',

  -- Chasing somebody the day a small invoice falls due annoys them for
  -- nothing, so there is a floor under what is worth a reminder.
  reminder_min_amount numeric(18, 2) not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.email_settings enable row level security;

drop policy if exists email_settings_select on public.email_settings;
create policy email_settings_select on public.email_settings
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists email_settings_write on public.email_settings;
create policy email_settings_write on public.email_settings
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

-- ---------------------------------------------------------------------
-- What to say
--
-- A row only exists once somebody has edited one. `app.email_template`
-- falls back to the built-in text below, so a new organization can send
-- before it has configured anything — an empty template table would
-- otherwise mean an empty email.
-- ---------------------------------------------------------------------
create table if not exists public.email_templates (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  code       text not null,
  subject    text not null,
  body       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, code)
);

alter table public.email_templates enable row level security;

drop policy if exists email_templates_select on public.email_templates;
create policy email_templates_select on public.email_templates
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists email_templates_write on public.email_templates;
create policy email_templates_write on public.email_templates
  for all to authenticated
  using (app.can_admin(org_id)) with check (app.can_admin(org_id));

-- The built-in wording. Deliberately plain: this goes to somebody's
-- customer over the company's name, and anything clever here is
-- something they did not choose to say.
create or replace function app.default_email_template(p_code text)
returns table (subject text, body text)
language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select t.subject, t.body from (values
    ('document_new',
     '{{doc_type}} {{doc_no}} from {{company_name}}',
     E'Dear {{contact_name}},\n\n{{doc_type}} {{doc_no}} dated {{doc_date}} is ready, for {{currency}} {{total_amount}}.\n\nYou can view it here: {{link}}\n\nRegards,\n{{company_name}}'),
    ('invoice_reminder',
     'Reminder: {{doc_no}} from {{company_name}}',
     E'Dear {{contact_name}},\n\nOur records show {{currency}} {{balance_amount}} outstanding on {{doc_no}}, which was due on {{due_date}}.\n\nYou can view it here: {{link}}\n\nIf you have already paid, please ignore this message and accept our apologies for the crossover.\n\nRegards,\n{{company_name}}'),
    ('payment_received',
     'Payment received — thank you',
     E'Dear {{contact_name}},\n\nThank you. We have received {{currency}} {{paid_amount}} against {{doc_no}}.\n\nRegards,\n{{company_name}}')
  ) as t (code, subject, body)
  where t.code = p_code;
$$;

create or replace function app.email_template(p_org_id uuid, p_code text)
returns table (subject text, body text)
language plpgsql stable
set search_path = public, app, pg_temp as $$
begin
  return query
    select t.subject, t.body from public.email_templates t
     where t.org_id = p_org_id and t.code = p_code and t.is_active;
  if found then return; end if;
  return query select d.subject, d.body from app.default_email_template(p_code) d;
end;
$$;

-- Token substitution. Nothing conditional and no loops: a template
-- language in here is a template language somebody has to debug at
-- three in the afternoon with a customer waiting.
create or replace function app.render_email(p_text text, p_vars jsonb)
returns text
language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare
  v_out text := coalesce(p_text, '');
  v_key text;
begin
  for v_key in select jsonb_object_keys(p_vars) loop
    v_out := replace(v_out, '{{' || v_key || '}}',
                     coalesce(p_vars ->> v_key, ''));
  end loop;
  -- Anything still unreplaced was a token nobody supplied. Leaving
  -- "{{due_date}}" in a customer's inbox is worse than leaving a gap.
  return regexp_replace(v_out, '\{\{[a-z_]+\}\}', '', 'g');
end;
$$;

-- ---------------------------------------------------------------------
-- The outbox
--
-- Queued, not sent. The database does not wait on a third party, and a
-- message that failed is a row somebody can look at rather than a line
-- in a log nobody reads.
-- ---------------------------------------------------------------------
create table if not exists public.email_outbox (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  to_email     text not null,
  subject      text not null,
  body         text not null,
  reply_to     text,
  from_name    text,

  template_code text,
  document_id  uuid references public.sales_documents (id) on delete set null,

  -- What stops the same reminder going out twice. Every automatic
  -- message carries one; a message somebody sends by hand does not,
  -- because pressing the button twice is a decision.
  dedupe_key   text,

  status       text not null default 'queued'
               check (status in ('queued', 'sent', 'failed', 'cancelled')),
  attempts     integer not null default 0,
  last_error   text,
  provider_id  text,
  queued_at    timestamptz not null default now(),
  sent_at      timestamptz,
  created_by   uuid references auth.users (id)
);

create unique index if not exists email_outbox_dedupe
  on public.email_outbox (org_id, dedupe_key) where dedupe_key is not null;
create index if not exists email_outbox_pending
  on public.email_outbox (queued_at) where status = 'queued';
create index if not exists email_outbox_document
  on public.email_outbox (document_id);

alter table public.email_outbox enable row level security;

-- Readable by members so a failure is visible. Written only through the
-- functions below and drained only by the edge function, which uses the
-- service role and bypasses this.
drop policy if exists email_outbox_select on public.email_outbox;
create policy email_outbox_select on public.email_outbox
  for select to authenticated using (app.is_org_member(org_id));

-- Bodies can name a customer and an amount. Same reasoning as the share
-- link table: RLS is enough, and it should not be the only thing.
revoke all on public.email_outbox from anon;
revoke all on public.email_outbox from authenticated;
grant select on public.email_outbox to authenticated;

revoke all on public.email_settings from anon;
revoke all on public.email_templates from anon;

-- ---------------------------------------------------------------------
-- Queue a document
-- ---------------------------------------------------------------------
create or replace function public.email_document(
  p_document_id uuid,
  p_to text default null,
  p_template_code text default 'document_new',
  p_share_days integer default 30)
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

  -- The contact person's address first: that is the human who asked for
  -- the invoice, where the contact's own address is often accounts@.
  v_to := coalesce(
    nullif(btrim(p_to), ''),
    (select cp.email::text from public.contact_persons cp
      where cp.contact_id = d.contact_id and cp.is_primary limit 1),
    c.email::text);

  if v_to is null then
    raise exception 'No address to send to; add one to the customer'
      using errcode = '23514';
  end if;

  -- A link rather than an attachment. The PDF is built in the client
  -- and the database has no way to make one, and a link is the thing
  -- that records whether anybody opened it.
  v_link := null;
  if d.status not in ('draft', 'void', 'rejected') then
    -- `app.issue_share_token` rather than `public.share_document`: the
    -- permission check has already happened above, and the reminder run
    -- below needs the same token with no signed-in user at all.
    v_link := app.share_url(app.issue_share_token(p_document_id, p_share_days, v_to));
  end if;

  select * into t from app.email_template(d.org_id, p_template_code);
  if t.subject is null then
    raise exception 'No template called %', p_template_code
      using errcode = 'P0002';
  end if;

  v_vars := app.document_email_vars(d.id, v_link);

  insert into public.email_outbox
    (org_id, to_email, subject, body, reply_to, from_name,
     template_code, document_id, created_by)
  values (
    d.org_id, v_to,
    app.render_email(t.subject, v_vars),
    app.render_email(t.body, v_vars),
    s.reply_to, coalesce(s.from_name, o.name),
    p_template_code, d.id, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

-- Where a share token becomes something a person can click. The site
-- address is a platform setting rather than a constant, because the
-- staging deployment must not send links to production.
create or replace function app.share_url(p_token text)
returns text
language sql stable
set search_path = public, app, pg_temp as $$
  select coalesce(
    (select value #>> '{}' from public.platform_settings
      where key = 'site_url'),
    'https://iakauntan.com') || '/#/share/' || p_token;
$$;

create or replace function app.document_email_vars(
  p_document_id uuid, p_link text)
returns jsonb
language sql stable
set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'company_name', coalesce(o.legal_name, o.name),
    'contact_name', coalesce(c.name, 'Sir or Madam'),
    'doc_type', initcap(replace(d.doc_type::text, '_', ' ')),
    'doc_no', d.doc_no,
    'doc_date', to_char(d.doc_date, 'DD Mon YYYY'),
    'due_date', coalesce(to_char(d.due_date, 'DD Mon YYYY'), ''),
    'currency', d.currency,
    'total_amount', to_char(d.total_amount, 'FM999,999,999,990.00'),
    'paid_amount', to_char(d.paid_amount, 'FM999,999,999,990.00'),
    'balance_amount', to_char(d.balance_amount, 'FM999,999,999,990.00'),
    'link', coalesce(p_link, ''))
    from public.sales_documents d
    join public.organizations o on o.id = d.org_id
    left join public.contacts c on c.id = d.contact_id
   where d.id = p_document_id;
$$;

-- ---------------------------------------------------------------------
-- Chasing what is overdue
--
-- Run from the daily job. Every message carries a dedupe key naming the
-- document and the day offset, so the unique index makes a second run
-- on the same day a no-op — which matters, because a reminder sent
-- twice is worse than one sent late.
-- ---------------------------------------------------------------------
create or replace function app.queue_overdue_reminders(p_on date default current_date)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  r record;
  t record;
  v_to text;
  v_link text;
  v_vars jsonb;
  v_n integer := 0;
begin
  for r in
    select d.*, s.reminder_days, s.from_name, s.reply_to,
           s.reminder_min_amount,
           (p_on - d.due_date) as days_over
      from public.sales_documents d
      join public.email_settings s on s.org_id = d.org_id
      join public.organizations o on o.id = d.org_id
     where s.is_enabled
       and array_length(s.reminder_days, 1) is not null
       and coalesce(o.status, 'active') = 'active'
       and d.deleted_at is null
       and d.doc_type = 'invoice'
       and d.status in ('posted', 'partial')
       and d.balance_amount > 0
       and d.due_date is not null
       and d.balance_amount >= s.reminder_min_amount
       and (p_on - d.due_date) = any (s.reminder_days)
  loop
    v_to := coalesce(
      (select cp.email::text from public.contact_persons cp
        where cp.contact_id = r.contact_id and cp.is_primary limit 1),
      (select c.email::text from public.contacts c where c.id = r.contact_id));

    -- No address is not an error worth stopping the run for. It is a
    -- customer somebody has to phone.
    continue when v_to is null;

    select * into t from app.email_template(r.org_id, 'invoice_reminder');

    v_link := app.share_url(app.issue_share_token(r.id, 45, v_to));
    v_vars := app.document_email_vars(r.id, v_link);

    begin
      insert into public.email_outbox
        (org_id, to_email, subject, body, reply_to, from_name,
         template_code, document_id, dedupe_key)
      values (
        r.org_id, v_to,
        app.render_email(t.subject, v_vars),
        app.render_email(t.body, v_vars),
        r.reply_to, r.from_name, 'invoice_reminder', r.id,
        'reminder:' || r.id::text || ':' || r.days_over::text);
      v_n := v_n + 1;
    exception when unique_violation then
      -- Already queued on this offset. Nothing to do and nothing wrong.
      null;
    end;
  end loop;

  return v_n;
end;
$$;

-- `share_document` checks `app.can_write`, which is nobody when the
-- cron is running. The reminder needs the same token without the
-- permission check, so the two share everything except that.
create or replace function app.issue_share_token(
  p_document_id uuid, p_valid_days integer, p_email text)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org uuid;
  v_token text := app.corp_new_token();
begin
  select org_id into v_org from public.sales_documents where id = p_document_id;
  if v_org is null then
    raise exception 'Document not found' using errcode = 'P0002';
  end if;

  update public.document_share_links
     set revoked_at = now()
   where document_id = p_document_id and revoked_at is null;

  insert into public.document_share_links
    (org_id, document_id, token_hash, expires_at, sent_to_email)
  values (v_org, p_document_id, app.corp_token_hash(v_token),
          now() + make_interval(days => greatest(coalesce(p_valid_days, 45), 1)),
          p_email);

  return v_token;
end;
$$;

-- Fold the reminders into the job that already runs every night.
create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare o record;
begin
  perform app.run_recurring_journals(p_on);
  perform app.queue_overdue_reminders(p_on);

  for o in select id from public.organizations where coalesce(status, 'active') = 'active'
  loop
    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end;
$$;

revoke all on function public.email_document(uuid, text, text, integer)
  from public, anon;
grant execute on function public.email_document(uuid, text, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- Take back what PostgreSQL gave away
--
-- EXECUTE goes to PUBLIC on every new function, so `grant execute to
-- authenticated` narrows nothing — the lesson from 0080, and this
-- migration walked into it again. Two of these mattered:
--
--   app.issue_share_token       mints a live share link for ANY document
--                               id with no permission check, because the
--                               nightly run has no signed-in user to
--                               check. Reachable by a stranger, it reads
--                               any invoice in the database given its id.
--   app.queue_overdue_reminders would let anybody start a mailing run.
--
-- `supabase/tests/statutory.sql` asserts that no SECURITY DEFINER
-- function outside a three-name allowlist is executable by `anon`. It
-- caught both of these, which is the entire reason it exists.
revoke all on function app.issue_share_token(uuid, integer, text)
  from public, anon, authenticated;
revoke all on function app.queue_overdue_reminders(date)
  from public, anon, authenticated;
revoke all on function app.run_daily_jobs(date)
  from public, anon, authenticated;
revoke all on function app.document_email_vars(uuid, text) from public, anon;
revoke all on function app.share_url(text) from public, anon;
revoke all on function app.email_template(uuid, text) from public, anon;
revoke all on function app.default_email_template(text) from public, anon;
revoke all on function app.render_email(text, jsonb) from public, anon;
