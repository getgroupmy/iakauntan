-- ---------------------------------------------------------------------
-- 0493  The customer who holds three links
-- ---------------------------------------------------------------------
-- 0067 gives a customer a signed link to one invoice: they open it,
-- read it, and pay it without an account. It is the right mechanism and
-- it is scoped to one document, so a customer with three invoices
-- outstanding has three links, in three emails, sent on three days, and
-- no way to answer "what do I owe you altogether?" except by finding
-- all three.
--
-- That is the last thing on `docs/gaps-against-akaunting.md` that
-- Akaunting plainly does better: `routes/portal.php` gives a customer a
-- login where their whole account is in one place.
--
-- ### What this is, and what it is not
--
-- It is not a login. There is no password, no account, no row in
-- `auth.users` for a customer -- adding one would put people who are
-- not staff into the same identity table as people who are, and every
-- RLS policy in this database is written on the assumption that an
-- `auth.uid()` belongs to a member of an organization.
--
-- It is the same scoped token, widened by one step: from a document to
-- the contact that owes it. `customer_portal_links` is
-- `document_share_links` with `contact_id` in place of `document_id`,
-- and `open_customer_portal` answers with the account rather than the
-- document -- every outstanding invoice, what each still owes, and the
-- total.
--
-- ### How it reaches the document
--
-- It does not render one. `portal_document_token` mints a normal
-- document share link when the customer clicks through, and everything
-- from there -- `open_shared_document`, `shared_payment_options`,
-- `shared_payment_intent`, the whole of 0412 to 0414 -- is the code
-- that already exists. The portal is a directory, not a second
-- renderer: a second renderer would be a second place for the total to
-- be wrong.
--
-- **It deliberately does not revoke.** `share_document` revokes any
-- live link when it issues one, because "the last link sent is the one
-- that works" is what revoke has to mean for something a person
-- emailed. A customer opening their own portal has sent nobody
-- anything, and killing the link the tenant emailed them last week
-- because they clicked through from the portal would be a bug wearing
-- a rule's clothes.
--
-- ### Mutants
--
-- Run against `supabase/tests/customer_portal.sql`, each named with the
-- assertion that kills it:
--   * the contact scope dropped -- "the portal shows this customer's
--     invoices and nobody else's";
--   * a draft invoice listed, and a settled one listed -- both killed
--     by "the portal shows this customer's invoices and nobody else's",
--     which counts and so fires before either of the assertions written
--     for them. The two named assertions are kept because they say
--     *which* extra document appeared, which a count does not;
--
--     The settled one took a fixture change to bite at all. It was
--     marked `completed`, so the status filter excluded it whatever the
--     balance test said, and the mutant that widened the balance test
--     survived untouched. It is `posted` with a zero balance now, which
--     is the state that actually exercises the filter;
--   * the expiry ignored -- "an expired link opens nothing";
--   * revocation ignored -- "and a revoked one opens nothing either";
--   * the total not the sum of the balances -- "the total is what the
--     lines add up to". This also needed the fixture changed: with
--     every balance equal to its total, a portal summing `total_amount`
--     shows the right number, and the assertion measured nothing. One
--     invoice is part paid now;
--   * `portal_document_token` handing out a token for a document that
--     is not this customer's -- "a portal cannot open somebody else's
--     invoice";
--   * `portal_document_token` revoking the link the tenant emailed --
--     "clicking through the portal does not kill the emailed link".
--     Written with `clock_timestamp()` rather than `now()`, because the
--     self-check below looks for the literal `revoked_at = now()` and
--     refuses to apply the obvious form of this mutant -- so the
--     obvious form never reaches the suite at all. Both guards are
--     kept: the self-check tests the text, the assertion tests what
--     happens;
--   * the guard dropped from `share_customer_portal` -- "somebody who
--     may only read cannot issue one".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The link
-- ---------------------------------------------------------------------
create table if not exists public.customer_portal_links (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  contact_id     uuid not null references public.contacts(id)
                   on delete cascade,
  token_hash     text not null unique,
  expires_at     timestamptz not null,
  sent_to_email  text,
  opened_at      timestamptz,
  last_opened_at timestamptz,
  open_count     integer not null default 0,
  ip_address     inet,
  user_agent     text,
  revoked_at     timestamptz,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now()
);

create index if not exists customer_portal_links_contact
  on public.customer_portal_links (contact_id);

alter table public.customer_portal_links enable row level security;

-- The same shape as `document_share_links`: a member of the company
-- sees who was sent what, somebody who may write can revoke, and the
-- customer's own path is a SECURITY DEFINER function holding a token
-- rather than a policy.
drop policy if exists customer_portal_links_select
  on public.customer_portal_links;
create policy customer_portal_links_select on public.customer_portal_links
  for select to authenticated using (app.is_org_member(org_id));

drop policy if exists customer_portal_links_update
  on public.customer_portal_links;
create policy customer_portal_links_update on public.customer_portal_links
  for update to authenticated using (app.can_write(org_id));

grant select, update on public.customer_portal_links to authenticated;

comment on table public.customer_portal_links is
  'A scoped token letting one customer see their whole account without '
  'an account. document_share_links, one step wider. See 0493.';

-- ---------------------------------------------------------------------
-- Issuing one
-- ---------------------------------------------------------------------
create or replace function public.share_customer_portal(
  p_contact_id uuid,
  p_valid_days integer default 60,
  p_email      text default null)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  c       public.contacts;
  v_token text;
  v_to    text;
  t       record;
  v_url   text;
begin
  select * into c from public.contacts where id = p_contact_id;
  if c.id is null or c.deleted_at is not null then
    raise exception 'Contact not found' using errcode = 'P0002';
  end if;
  -- The same line `share_document` draws. Handing somebody a view of
  -- everything a customer owes is not a read; it is a disclosure, and
  -- it is the company's to make.
  if not app.can_write(c.org_id) then
    raise exception 'Not permitted to share this account'
      using errcode = '42501';
  end if;

  v_to := coalesce(
    nullif(btrim(p_email), ''),
    (select cp.email::text from public.contact_persons cp
      where cp.contact_id = c.id and cp.is_primary limit 1),
    c.email::text);

  v_token := app.corp_new_token();

  -- One live portal per customer, for the same reason `share_document`
  -- keeps one live link per document: a revoke that leaves an older
  -- door open is not a revoke.
  update public.customer_portal_links
     set revoked_at = now()
   where contact_id = p_contact_id and revoked_at is null;

  insert into public.customer_portal_links
    (org_id, contact_id, token_hash, expires_at, sent_to_email, created_by)
  values (c.org_id, c.id, app.corp_token_hash(v_token),
          now() + make_interval(days => greatest(coalesce(p_valid_days, 60), 1)),
          v_to, auth.uid());

  v_url := app.share_url(v_token);

  -- Sent if there is anywhere to send it, and returned either way: a
  -- tenant reading the number out over the phone is a real thing, and
  -- a customer with no address on file is not a reason to refuse.
  if v_to is not null then
    select * into t from app.default_email_template('customer_portal');
    begin
      insert into public.email_outbox
        (org_id, to_email, subject, body, template_code, dedupe_key)
      values (
        c.org_id, v_to,
        app.render_email(t.subject, jsonb_build_object(
          'contact_name', c.name,
          'company_name', (select coalesce(o.legal_name, o.name)
                             from public.organizations o where o.id = c.org_id),
          'link', v_url)),
        app.render_email(t.body, jsonb_build_object(
          'contact_name', c.name,
          'company_name', (select coalesce(o.legal_name, o.name)
                             from public.organizations o where o.id = c.org_id),
          'link', v_url)),
        'customer_portal',
        'portal:' || app.corp_token_hash(v_token));
    exception when others then
      -- The link is the deliverable and the mail is the delivery. One
      -- that cannot be queued must not lose the other.
      raise warning 'customer portal mail failed for %: %', c.id, sqlerrm;
    end;
  end if;

  return jsonb_build_object('url', v_url, 'sent_to', v_to);
end $$;

comment on function public.share_customer_portal(uuid, integer, text) is
  'Issues one customer a link to their whole account and emails it. '
  'See 0493.';

revoke all on function public.share_customer_portal(uuid, integer, text)
  from public, anon;
grant execute on function public.share_customer_portal(uuid, integer, text)
  to authenticated;

create or replace function public.revoke_customer_portal(p_contact_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.contacts where id = p_contact_id;
  if v_org is null or not app.can_write(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update public.customer_portal_links
     set revoked_at = now()
   where contact_id = p_contact_id and revoked_at is null;
end $$;

revoke all on function public.revoke_customer_portal(uuid) from public, anon;
grant execute on function public.revoke_customer_portal(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Opening it
-- ---------------------------------------------------------------------
create or replace function public.open_customer_portal(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.customer_portal_links;
  c       public.contacts;
  o       public.organizations;
  v_state text;
  v_rows  jsonb;
  v_owed  numeric;
begin
  select * into l from public.customer_portal_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'invalid');
  end if;

  select * into c from public.contacts where id = l.contact_id;
  select * into o from public.organizations where id = l.org_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when c.id is null or c.deleted_at is not null then 'withdrawn'
    else 'open'
  end;

  -- Recorded even when the answer is 'expired', as 0067 has it: that
  -- somebody tried is worth as much as that somebody read it.
  update public.customer_portal_links
     set opened_at = coalesce(opened_at, now()),
         last_opened_at = now(),
         open_count = open_count + 1,
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  if v_state <> 'open' then
    return jsonb_build_object('state', v_state);
  end if;

  -- What this customer still owes. Posted and partial only: a draft is
  -- not a demand, and a void or rejected one is withdrawn. Every
  -- record of the same company counts -- 0477 links a contact's
  -- records through `party_id`, so a customer filed twice is one
  -- account here rather than two portals.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'doc_no', d.doc_no,
           'doc_type', d.doc_type,
           'doc_date', d.doc_date,
           'due_date', d.due_date,
           'currency', d.currency,
           'total_amount', d.total_amount,
           'paid_amount', d.paid_amount,
           'balance_amount', d.balance_amount,
           'overdue', d.due_date is not null and d.due_date < app.today())
           order by d.due_date nulls last, d.doc_no), '[]'::jsonb),
         coalesce(sum(d.balance_amount), 0)
    into v_rows, v_owed
    from public.sales_documents d
   where d.org_id = l.org_id
     and d.contact_id in (
       select c2.id from public.contacts c2
        where c2.org_id = l.org_id
          and (c2.id = c.id
               or (c.party_id is not null and c2.party_id = c.party_id)))
     and d.deleted_at is null
     and d.doc_type = 'invoice'
     and d.status in ('posted', 'partial')
     and coalesce(d.balance_amount, 0) > 0;

  return jsonb_build_object(
    'state', 'open',
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'email', o.email,
      'phone', o.phone,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object('name', c.name, 'code', c.code),
    'currency', coalesce(o.base_currency, 'MYR'),
    'total_outstanding', v_owed,
    'invoices', v_rows);
end $$;

comment on function public.open_customer_portal(text) is
  'What one customer owes, for somebody holding their portal token and '
  'no account. See 0493.';

revoke all on function public.open_customer_portal(text) from public;
grant execute on function public.open_customer_portal(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Clicking through to one of them
-- ---------------------------------------------------------------------
create or replace function public.portal_document_token(
  p_token text, p_document_id uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.customer_portal_links;
  c       public.contacts;
  d       public.sales_documents;
  v_token text;
begin
  select * into l from public.customer_portal_links
   where token_hash = app.corp_token_hash(p_token)
     and revoked_at is null and expires_at >= now();
  if l.id is null then
    raise exception 'This link is no longer open' using errcode = '42501';
  end if;

  select * into c from public.contacts where id = l.contact_id;
  select * into d from public.sales_documents where id = p_document_id;

  -- The document has to be this customer's, in this company. Without
  -- this line a portal token is a key to every invoice in the tenant.
  if d.id is null
     or d.deleted_at is not null
     or d.org_id <> l.org_id
     or d.contact_id is null
     or not exists (
       select 1 from public.contacts c2
        where c2.id = d.contact_id
          and c2.org_id = l.org_id
          and (c2.id = c.id
               or (c.party_id is not null and c2.party_id = c.party_id)))
  then
    raise exception 'Not one of this account''s documents'
      using errcode = '42501';
  end if;
  if d.status in ('draft', 'void', 'rejected') then
    raise exception 'A % document cannot be opened', d.status
      using errcode = '22023';
  end if;

  v_token := app.corp_new_token();

  -- Deliberately no revoke. `share_document` kills the previous link
  -- because the tenant just emailed a new one and the last one sent
  -- has to be the one that works. Nobody has sent anything here: the
  -- customer clicked a row in their own account, and taking down the
  -- link they were emailed last week for doing so would be a bug
  -- wearing a rule's clothes.
  insert into public.document_share_links
    (org_id, document_id, token_hash, expires_at, sent_to_email)
  values (l.org_id, d.id, app.corp_token_hash(v_token),
          least(l.expires_at, now() + interval '30 days'),
          l.sent_to_email);

  return v_token;
end $$;

comment on function public.portal_document_token(text, uuid) is
  'Hands a customer holding a portal token a document token for one of '
  'their own invoices, so 0067''s view and 0414''s payment work '
  'unchanged. Revokes nothing. See 0493.';

revoke all on function public.portal_document_token(text, uuid) from public;
grant execute on function public.portal_document_token(text, uuid)
  to anon, authenticated;

-- ---------------------------------------------------------------------
-- The invitation
-- ---------------------------------------------------------------------
-- Restated from the built definition. The seven above are 0068's,
-- 0083's, 0490's and 0491's, unchanged.
create or replace function app.default_email_template(p_code text)
returns table(subject text, body text)
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
     E'Dear {{contact_name}},\n\nThank you. We have received {{currency}} {{paid_amount}} against {{doc_no}}.\n\nRegards,\n{{company_name}}'),
    ('receipt_issued',
     'Receipt {{receipt_no}} from {{company_name}}',
     E'Dear {{contact_name}},\n\nThank you. We have received {{currency}} {{amount}} on {{receipt_date}}, and your receipt {{receipt_no}} is attached.\n\nThis has been set against {{applied_to}}.\n\nRegards,\n{{company_name}}'),
    ('platform_invoice',
     '{{invoice_no}} — {{period}} for {{company_name}}',
     E'Dear {{company_name}},\n\nYour iAkauntan invoice {{invoice_no}} is ready, for {{currency}} {{total_amount}}.\n\n{{description}}\n\nYou can see it and pay it under Settings, on the Your subscription card.\n\nRegards,\n{{issuer_name}}'),
    -- 0491. The chase. It says how long it has been rather than "this
    -- is overdue", because there is no due date on a platform invoice
    -- to be past -- and the last line is the one that matters, since
    -- most of these will be crossovers rather than debts.
    ('platform_invoice_reminder',
     'Still outstanding: {{invoice_no}}',
     E'Dear {{company_name}},\n\nOur records show {{currency}} {{total_amount}} still outstanding on invoice {{invoice_no}}, issued {{days}} days ago on {{issue_date}}.\n\n{{description}}\n\nYou can settle it under Settings, on the Your subscription card.\n\nIf you have already paid, please ignore this message and accept our apologies for the crossover.\n\nRegards,\n{{issuer_name}}'),
    -- And the thank-you. Short on purpose: what somebody needs from it
    -- is confirmation that the money landed against the right bill.
    ('platform_payment_received',
     'Payment received — thank you',
     E'Dear {{company_name}},\n\nThank you. We have received {{currency}} {{total_amount}} against invoice {{invoice_no}}.\n\nRegards,\n{{issuer_name}}')
,
    -- 0493. The customer's own account, in one link. Short: what it is
    -- for is the link, and everything a person needs to decide whether
    -- to click it is the name of the company that sent it.
    ('customer_portal',
     'Your account with {{company_name}}',
     E'Dear {{contact_name}},\n\nYou can see everything outstanding on your account with {{company_name}}, and settle any of it, here:\n\n{{link}}\n\nThe link is yours alone -- please do not forward it.\n\nRegards,\n{{company_name}}')
  ) as t (code, subject, body)
  where t.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  -- Eight templates now, and the seven that were already there must
  -- have survived the restatement.
  if (select count(*) from (
        select app.default_email_template(c) from (values
          ('document_new'), ('invoice_reminder'), ('payment_received'),
          ('receipt_issued'), ('platform_invoice'),
          ('platform_invoice_reminder'), ('platform_payment_received'),
          ('customer_portal')) v(c)) s) <> 8 then
    raise exception '0493: a template is missing';
  end if;

  -- The customer's two doors are open to somebody with no account at
  -- all; the tenant's two are not.
  if not has_function_privilege('anon', 'public.open_customer_portal(text)',
                                'execute')
     or not has_function_privilege('anon',
       'public.portal_document_token(text, uuid)', 'execute') then
    raise exception '0493: a customer cannot reach their own account';
  end if;
  if has_function_privilege('anon',
       'public.share_customer_portal(uuid, integer, text)', 'execute')
     or has_function_privilege('anon',
       'public.revoke_customer_portal(uuid)', 'execute') then
    raise exception '0493: a stranger can issue a portal';
  end if;

  -- The one line that stops a portal token being a key to the whole
  -- tenant.
  if position('Not one of this account' in pg_get_functiondef(
       'public.portal_document_token(text, uuid)'::regprocedure)) = 0 then
    raise exception '0493: a portal opens anybody''s invoice';
  end if;

  -- And the one that keeps the emailed link alive.
  if position('revoked_at = now()' in pg_get_functiondef(
       'public.portal_document_token(text, uuid)'::regprocedure)) > 0 then
    raise exception '0493: clicking through the portal revokes the '
      'link the tenant emailed';
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'customer_portal_links'
       and policyname = 'customer_portal_links_select') then
    raise exception '0493: the portal links table has no read policy';
  end if;
end $do$;
