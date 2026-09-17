-- =====================================================================
-- iAkauntan :: 0626 the number only the customer has
--
-- From 1 August 2024 an e-Invoice will not clear MyInvois without the
-- buyer's TIN and the identification number it was issued against. We
-- hold neither for most contacts, and there is no way to obtain them
-- except to ask the customer -- one customer at a time, by telephone,
-- reading a twelve-character string down a line and typing it into a
-- form. That is the step that stalls an onboarding: a company with
-- four hundred customers cannot start e-Invoicing until four hundred
-- telephone calls have been made.
--
-- The mechanism to fix it has existed since 0067 and was widened by
-- 0493: a scoped token, emailed, opened by somebody with no account.
-- `open_customer_portal` shows a customer what they owe. This shows
-- them what we hold about them, and lets them correct it.
--
-- ---------------------------------------------------------------------
-- A stranger's form does not overwrite master data
--
-- The single decision in this migration. The link is emailed by the
-- company to its own customer, which is the same trust as the portal --
-- but the portal only READS, and this writes into the columns an
-- e-Invoice is built from. A submission that silently replaced a TIN
-- somebody had already verified with LHDN would take a working contact
-- and break it, and nothing in the product would say when.
--
-- So the rule is: **a submission fills a blank; it never overwrites.**
--
--   * Every submission is recorded in full, whatever happens next --
--     who said it, from which address, at what time. If LHDN later
--     rejects an invoice on the TIN, the answer to "where did this
--     number come from" is a row rather than a recollection.
--   * Fields the contact has no value for are written immediately.
--     That is the whole saving, and it is the ordinary case: a contact
--     with no TIN is precisely the contact the link is sent to.
--   * Fields that disagree with something already held are NOT
--     written. They sit on the submission until somebody in the
--     company looks at them and calls `apply_tax_submission`, which
--     requires `app.can_write` -- the same permission that issued the
--     link.
--
-- ---------------------------------------------------------------------
-- A changed TIN is an unverified TIN
--
-- `contacts.is_tin_verified` means LHDN matched that TIN to that
-- identification number. Write a different TIN over it and the flag is
-- a claim about a number that is no longer there, so
-- `apply_tax_submission` clears it. This is the assertion most worth
-- having: a stale true is worse than a false, because the e-Invoice
-- screen shows a tick beside a number nobody checked.
--
-- The same holds when the ID TYPE or ID VALUE moves, because that is
-- what the TIN was matched against.
--
-- ---------------------------------------------------------------------
-- What the customer is shown
--
-- What we already hold: their name, their address, their TIN if we
-- have one. Deliberately, and it is a disclosure: somebody holding the
-- link learns the customer's TIN. The alternative is a blank form,
-- which asks a customer to retype an address we already have correctly
-- and produces a conflict for every field they type differently -- and
-- a conflict is the case that needs a human, which is the case this
-- migration exists to avoid.
--
-- What it does NOT show is anything about money. The portal is for
-- that, it is a different token, and the two are not interchangeable.
--
-- ---------------------------------------------------------------------
-- A correction is allowed, and lands in review
--
-- The link is not spent by one submission. A customer who mistypes and
-- sends again gets a second row, and the first is superseded. The
-- second will usually NOT auto-apply -- the fields it corrects are no
-- longer blank, because the first submission filled them -- so it waits
-- for a person. That is the right way round: the first answer from a
-- customer is better than nothing, and the second contradicting it is
-- exactly the thing a human should see.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The link
-- ---------------------------------------------------------------------
create table public.tax_detail_requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  contact_id uuid not null,

  token_hash text not null unique,
  expires_at timestamptz not null,
  sent_to_email text,

  opened_at timestamptz,
  last_opened_at timestamptz,
  open_count integer not null default 0,
  submitted_at timestamptz,
  submission_count integer not null default 0,

  ip_address inet,
  user_agent text,
  revoked_at timestamptz,

  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),

  -- So the submission below can name the pair rather than the id.
  unique (org_id, id),

  constraint tax_detail_requests_contact_same_org
    foreign key (org_id, contact_id)
    references public.contacts (org_id, id) on delete cascade
);

create index tax_detail_requests_contact_idx
  on public.tax_detail_requests (contact_id);

comment on table public.tax_detail_requests is
  'A scoped token letting one customer fill in their own tax details '
  'without an account. document_share_links, pointed at a form. 0626.';

alter table public.tax_detail_requests enable row level security;

create policy tax_detail_requests_select on public.tax_detail_requests
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_detail_requests_update on public.tax_detail_requests
  for update to authenticated using (app.can_write(org_id));

grant select, update on public.tax_detail_requests to authenticated;
revoke all on public.tax_detail_requests from anon;

-- ---------------------------------------------------------------------
-- What the customer said
-- ---------------------------------------------------------------------
create table public.tax_detail_submissions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  contact_id uuid not null,
  request_id uuid not null,

  submitted_at timestamptz not null default now(),

  -- Provenance. Never written to the contact: who filled the form in is
  -- not who the contact IS, and a clerk's name is not the company's.
  submitted_by_name text,
  submitted_by_email text,
  ip_address inet,
  user_agent text,

  -- The answers, exactly as given.
  tin text,
  id_type text check (id_type in ('NRIC', 'BRN', 'PASSPORT', 'ARMY')),
  id_value text,
  sst_registration_no text,
  email text,
  phone text,
  address_line1 text,
  address_line2 text,
  address_line3 text,
  postcode text,
  city text,
  state_code text references public.ref_states (code),
  country_code char(3) references public.ref_countries (code),

  -- Which of them reached the contact, and when somebody decided.
  applied_fields text[] not null default '{}',
  applied_at timestamptz,
  applied_by uuid references auth.users (id),
  dismissed_at timestamptz,
  dismissed_by uuid references auth.users (id),
  superseded_at timestamptz,

  -- A form submitted empty is a customer who clicked the button and
  -- typed nothing. It is not an answer and must not queue for review as
  -- though it were one.
  constraint tax_detail_submissions_says_something check (
    tin is not null or id_type is not null or id_value is not null
    or sst_registration_no is not null or email is not null
    or phone is not null or address_line1 is not null
    or address_line2 is not null or address_line3 is not null
    or postcode is not null or city is not null
    or state_code is not null or country_code is not null),

  constraint tax_detail_submissions_contact_same_org
    foreign key (org_id, contact_id)
    references public.contacts (org_id, id) on delete cascade,
  constraint tax_detail_submissions_request_same_org
    foreign key (org_id, request_id)
    references public.tax_detail_requests (org_id, id) on delete cascade
);

-- Not `applied_at is null`: a submission that auto-filled three blanks
-- and disagreed on a fourth is both applied AND waiting, and an index
-- that excluded it would be an index the review query cannot use.
create index tax_detail_submissions_pending_idx
  on public.tax_detail_submissions (org_id, submitted_at desc)
  where dismissed_at is null and superseded_at is null;

comment on table public.tax_detail_submissions is
  'What a customer filled in on their own tax-details form, recorded in '
  'full whether or not it reached the contact. 0626.';

alter table public.tax_detail_submissions enable row level security;

create policy tax_detail_submissions_select on public.tax_detail_submissions
  for select to authenticated using (app.is_org_member(org_id));

grant select on public.tax_detail_submissions to authenticated;
revoke all on public.tax_detail_submissions from anon;

-- ---------------------------------------------------------------------
-- Where the link goes
--
-- Its own builder, not an argument to `app.share_url`. 0493 emailed
-- every customer portal link on the DOCUMENT path and 0494 had to be
-- written to undo it, because `open_shared_document` looks a portal
-- token up in `document_share_links`, finds nothing and answers
-- `invalid` -- so every link 0493 sent led to a page saying the link
-- was not valid. 0494's conclusion was that "a caller that has to be
-- told which path to use is a caller that can be told the wrong one",
-- and this is the third path.
-- ---------------------------------------------------------------------
create or replace function app.tax_details_url(p_token text)
returns text
language sql stable
set search_path = public, app, pg_temp as $$
  select coalesce(
    (select value #>> '{}' from public.platform_settings
      where key = 'site_url'),
    'https://iakauntan.com') || '/#/tax-details/' || p_token;
$$;

comment on function app.tax_details_url(text) is
  'Where a tax-details token is opened. Its own function for 0494''s '
  'reason. See 0626.';

revoke all on function app.tax_details_url(text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Issuing one
--
-- `share_customer_portal`'s shape, and for its reasons: the guard is
-- `can_write` because handing somebody a form that writes into master
-- data is the company's decision, not a reader's; the previous live
-- link is revoked because the last link sent has to be the one that
-- works; and the URL is returned whether or not there was anywhere to
-- email it, because reading it out over the telephone is a real thing
-- and a customer with no address on file is not a reason to refuse.
-- ---------------------------------------------------------------------
create or replace function public.request_tax_details(
  p_contact_id uuid,
  p_valid_days integer default 30,
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
  if not app.can_write(c.org_id) then
    raise exception 'Not permitted to ask this contact for their details'
      using errcode = '42501';
  end if;

  v_to := coalesce(
    nullif(btrim(p_email), ''),
    (select cp.email::text from public.contact_persons cp
      where cp.contact_id = c.id and cp.is_primary limit 1),
    c.email::text);

  v_token := app.corp_new_token();

  update public.tax_detail_requests
     set revoked_at = now()
   where contact_id = p_contact_id and revoked_at is null;

  insert into public.tax_detail_requests
    (org_id, contact_id, token_hash, expires_at, sent_to_email, created_by)
  values (c.org_id, c.id, app.corp_token_hash(v_token),
          now() + make_interval(days => greatest(coalesce(p_valid_days, 30), 1)),
          v_to, auth.uid());

  v_url := app.tax_details_url(v_token);

  if v_to is not null then
    select * into t from app.default_email_template('tax_details_request');
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
        'tax_details_request',
        'taxdetails:' || app.corp_token_hash(v_token));
    exception when others then
      -- The link is the deliverable and the mail is the delivery. One
      -- that cannot be queued must not lose the other. 0493's reasoning
      -- and 0493's words.
      raise warning 'tax details mail failed for %: %', c.id, sqlerrm;
    end;
  end if;

  return jsonb_build_object('url', v_url, 'sent_to', v_to);
end $$;

comment on function public.request_tax_details(uuid, integer, text) is
  'Issues one contact a link to fill in their own TIN and tax details, '
  'and emails it. See 0626.';

revoke all on function public.request_tax_details(uuid, integer, text)
  from public, anon;
grant execute on function public.request_tax_details(uuid, integer, text)
  to authenticated, service_role;

create or replace function public.revoke_tax_detail_request(p_contact_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.contacts where id = p_contact_id;
  if v_org is null or not app.can_write(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update public.tax_detail_requests
     set revoked_at = now()
   where contact_id = p_contact_id and revoked_at is null;
end $$;

comment on function public.revoke_tax_detail_request(uuid) is
  'Closes any live tax-details link for one contact. Requires '
  'can_write. See 0626.';

revoke all on function public.revoke_tax_detail_request(uuid) from public, anon;
grant execute on function public.revoke_tax_detail_request(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Opening it
-- ---------------------------------------------------------------------
create or replace function public.open_tax_detail_request(p_token text)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.tax_detail_requests;
  c       public.contacts;
  o       public.organizations;
  v_state text;
begin
  select * into l from public.tax_detail_requests
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

  -- Recorded even when the answer is 'expired', as 0067 and 0493 have
  -- it: that somebody tried is worth as much as that somebody read it.
  update public.tax_detail_requests
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

  return jsonb_build_object(
    'state', 'open',
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'email', o.email,
      'phone', o.phone,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object(
      'name', c.name,
      'legal_name', c.legal_name,
      'registration_no', c.registration_no,
      'tin', c.tin,
      'is_tin_verified', c.is_tin_verified,
      'id_type', c.id_type,
      'id_value', c.id_value,
      'sst_registration_no', c.sst_registration_no,
      'email', c.email,
      'phone', c.phone,
      'address_line1', c.address_line1,
      'address_line2', c.address_line2,
      'address_line3', c.address_line3,
      'postcode', c.postcode,
      'city', c.city,
      'state_code', c.state_code,
      'country_code', c.country_code),
    'already_submitted', l.submission_count > 0);
end $$;

comment on function public.open_tax_detail_request(text) is
  'What we hold about one contact, for somebody holding their '
  'tax-details token and no account. Money is not in it. See 0626.';

revoke all on function public.open_tax_detail_request(text) from public;
grant execute on function public.open_tax_detail_request(text)
  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Writing one field, and only into a blank
--
-- One function so the public path and the reviewed path cannot drift
-- on what "already held" means. `p_blank_only` is the whole difference
-- between them.
-- ---------------------------------------------------------------------
create or replace function app.tax_submission_apply(
  p_submission_id uuid,
  p_blank_only    boolean)
returns text[]
language plpgsql
set search_path = public, app, pg_temp as $$
declare
  s        public.tax_detail_submissions;
  c        public.contacts;
  v_done   text[] := '{}';
  v_key    text;
  v_new    text;
  v_old    text;
  v_retin  boolean := false;
begin
  select * into s from public.tax_detail_submissions where id = p_submission_id;
  if s.id is null then
    raise exception 'Submission not found' using errcode = 'P0002';
  end if;
  select * into c from public.contacts where id = s.contact_id;
  if c.id is null then
    raise exception 'Contact not found' using errcode = 'P0002';
  end if;

  foreach v_key in array array[
    'tin', 'id_type', 'id_value', 'sst_registration_no', 'email', 'phone',
    'address_line1', 'address_line2', 'address_line3',
    'postcode', 'city', 'state_code', 'country_code']
  loop
    v_new := nullif(btrim(coalesce(to_jsonb(s) ->> v_key, '')), '');
    v_old := nullif(btrim(coalesce(to_jsonb(c) ->> v_key, '')), '');

    -- Nothing said, or the same thing said again. Neither is a change,
    -- and reporting the second as one would make a form that echoed
    -- what it was shown read as a correction.
    continue when v_new is null or v_new is not distinct from v_old;
    continue when p_blank_only and v_old is not null;

    execute format('update public.contacts set %I = $1 where id = $2', v_key)
      using v_new, c.id;
    v_done := v_done || v_key;

    -- `is_tin_verified` says LHDN matched that TIN to that
    -- identification number. Move any of the three and the flag is a
    -- claim about numbers that are no longer there.
    if v_key in ('tin', 'id_type', 'id_value') then
      v_retin := true;
    end if;
  end loop;

  if v_retin then
    update public.contacts
       set is_tin_verified = false, tin_verified_at = null
     where id = c.id;
  end if;

  return v_done;
end $$;

comment on function app.tax_submission_apply(uuid, boolean) is
  'Copies a customer''s submitted tax details onto their contact. '
  'p_blank_only is the difference between the public path and the '
  'reviewed one. Returns the fields it wrote. See 0626.';

revoke all on function app.tax_submission_apply(uuid, boolean)
  from public, anon;
grant execute on function app.tax_submission_apply(uuid, boolean)
  to service_role;

-- ---------------------------------------------------------------------
-- Submitting the form
-- ---------------------------------------------------------------------
create or replace function public.submit_tax_details(
  p_token   text,
  p_details jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  l       public.tax_detail_requests;
  c       public.contacts;
  v_id    uuid;
  v_done  text[];
  v_ip    inet;
  v_text  text;
begin
  select * into l from public.tax_detail_requests
   where token_hash = app.corp_token_hash(p_token)
     and revoked_at is null and expires_at >= now();
  if l.id is null then
    raise exception 'This link is no longer open' using errcode = '42501';
  end if;

  select * into c from public.contacts where id = l.contact_id;
  if c.id is null or c.deleted_at is not null then
    raise exception 'This link is no longer open' using errcode = '42501';
  end if;

  v_ip := nullif(split_part(coalesce(
    app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet;

  -- The earlier answers on this link are not deleted -- a record of
  -- what a customer said first is the point of keeping any of them --
  -- but they stop being the customer's current answer.
  --
  -- Deliberately NOT restricted to the ones that applied nothing. The
  -- first answer usually DOES apply something -- it fills the blanks,
  -- which is the whole point -- and if that left it current, a
  -- correction would leave two rows on the review list disagreeing with
  -- each other and no way to tell which the customer meant. A dismissed
  -- one is left dismissed: somebody already decided about it.
  update public.tax_detail_submissions
     set superseded_at = now()
   where request_id = l.id
     and dismissed_at is null
     and superseded_at is null;

  insert into public.tax_detail_submissions (
    org_id, contact_id, request_id,
    submitted_by_name, submitted_by_email, ip_address, user_agent,
    tin, id_type, id_value, sst_registration_no, email, phone,
    address_line1, address_line2, address_line3,
    postcode, city, state_code, country_code)
  values (
    l.org_id, c.id, l.id,
    nullif(btrim(p_details ->> 'submitted_by_name'), ''),
    nullif(btrim(p_details ->> 'submitted_by_email'), ''),
    v_ip, app.request_header('user-agent'),
    -- A TIN is written upper case everywhere else in this schema and
    -- `contact_editor.dart` upper-cases it on save. A customer typing
    -- it in lower case must not create a second spelling of the same
    -- number.
    upper(nullif(btrim(p_details ->> 'tin'), '')),
    nullif(btrim(p_details ->> 'id_type'), ''),
    upper(nullif(btrim(p_details ->> 'id_value'), '')),
    upper(nullif(btrim(p_details ->> 'sst_registration_no'), '')),
    lower(nullif(btrim(p_details ->> 'email'), '')),
    nullif(btrim(p_details ->> 'phone'), ''),
    nullif(btrim(p_details ->> 'address_line1'), ''),
    nullif(btrim(p_details ->> 'address_line2'), ''),
    nullif(btrim(p_details ->> 'address_line3'), ''),
    nullif(btrim(p_details ->> 'postcode'), ''),
    nullif(btrim(p_details ->> 'city'), ''),
    upper(nullif(btrim(p_details ->> 'state_code'), '')),
    upper(nullif(btrim(p_details ->> 'country_code'), '')))
  returning id into v_id;

  -- Blanks only. The header says why, and it is the one line in this
  -- migration that a reviewer should be slowest to change.
  v_done := app.tax_submission_apply(v_id, true);

  update public.tax_detail_submissions
     set applied_fields = v_done,
         applied_at = case when cardinality(v_done) > 0 then now() end
   where id = v_id;

  update public.tax_detail_requests
     set submitted_at = now(),
         submission_count = submission_count + 1
   where id = l.id;

  select string_agg(k, ', ' order by k) into v_text
    from unnest(v_done) as k;

  return jsonb_build_object(
    'state', 'received',
    'applied', coalesce(to_jsonb(v_done), '[]'::jsonb),
    'applied_list', coalesce(v_text, ''),
    -- True where something the customer typed disagreed with something
    -- we already hold. The form says so rather than thanking them for a
    -- change that has not happened.
    --
    -- Counted as a DISAGREEMENT, not as "fields submitted minus fields
    -- applied": the page shows the customer what we hold, so most of
    -- what comes back is the same value echoed, and an arithmetic
    -- difference would tell every customer their address is under
    -- review.
    'awaiting_review', exists (
      select 1
        from public.tax_detail_submissions s2,
             unnest(array[
               'tin', 'id_type', 'id_value', 'sst_registration_no',
               'email', 'phone', 'address_line1', 'address_line2',
               'address_line3', 'postcode', 'city', 'state_code',
               'country_code']) as f(field)
       where s2.id = v_id
         and nullif(btrim(coalesce(to_jsonb(s2) ->> f.field, '')), '')
             is not null
         and nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')
             is not null
         and nullif(btrim(coalesce(to_jsonb(s2) ->> f.field, '')), '')
             is distinct from
             nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')));
end $$;

comment on function public.submit_tax_details(text, jsonb) is
  'Records what a customer filled in on their own tax-details form, and '
  'fills the contact''s BLANK fields from it. Never overwrites. 0626.';

revoke all on function public.submit_tax_details(text, jsonb) from public;
grant execute on function public.submit_tax_details(text, jsonb)
  to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- The other half: somebody in the company looks at what disagreed
-- ---------------------------------------------------------------------
create or replace function public.apply_tax_submission(p_submission_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  s      public.tax_detail_submissions;
  v_done text[];
begin
  select * into s from public.tax_detail_submissions where id = p_submission_id;
  if s.id is null then
    raise exception 'Submission not found' using errcode = 'P0002';
  end if;
  -- The same permission that issued the link. Accepting a TIN into a
  -- contact an e-Invoice is built from is a write, whatever it looks
  -- like on the screen.
  if not app.can_write(s.org_id) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  v_done := app.tax_submission_apply(p_submission_id, false);

  update public.tax_detail_submissions
     set applied_fields = (
           select coalesce(array_agg(distinct k order by k), '{}')
             from unnest(applied_fields || v_done) as k),
         applied_at = now(),
         applied_by = auth.uid(),
         dismissed_at = null,
         dismissed_by = null
   where id = p_submission_id;

  return jsonb_build_object('applied', coalesce(to_jsonb(v_done), '[]'::jsonb));
end $$;

comment on function public.apply_tax_submission(uuid) is
  'Accepts a customer''s submitted tax details over what the contact '
  'already held. Requires can_write. See 0626.';

revoke all on function public.apply_tax_submission(uuid) from public, anon;
grant execute on function public.apply_tax_submission(uuid)
  to authenticated, service_role;

create or replace function public.dismiss_tax_submission(p_submission_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select org_id into v_org from public.tax_detail_submissions
   where id = p_submission_id;
  if v_org is null or not app.can_write(v_org) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update public.tax_detail_submissions
     set dismissed_at = now(), dismissed_by = auth.uid()
   where id = p_submission_id;
end $$;

comment on function public.dismiss_tax_submission(uuid) is
  'Records that somebody in the company looked at a customer''s '
  'submission and is keeping what the contact already holds. Writes '
  'nothing to the contact. Requires can_write. See 0626.';

revoke all on function public.dismiss_tax_submission(uuid) from public, anon;
grant execute on function public.dismiss_tax_submission(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- What is waiting, and what each row disagrees with
--
-- The screen needs both sides or it cannot ask the question. A row
-- saying "the customer says C1234567890" is not answerable without
-- "you hold C9999999999".
-- ---------------------------------------------------------------------
create or replace function public.pending_tax_submissions(p_org_id uuid)
returns table (
  submission_id uuid,
  contact_id uuid,
  contact_name text,
  submitted_at timestamptz,
  submitted_by_name text,
  submitted_by_email text,
  applied_fields text[],
  conflicts jsonb)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select s.id, s.contact_id, c.name, s.submitted_at,
         s.submitted_by_name, s.submitted_by_email, s.applied_fields,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'field', k.field, 'theirs', k.theirs, 'ours', k.ours)
                  order by k.field)
             from (
               select f.field,
                      nullif(btrim(coalesce(to_jsonb(s) ->> f.field, '')), '')
                        as theirs,
                      nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')
                        as ours
                 from unnest(array[
                        'tin', 'id_type', 'id_value', 'sst_registration_no',
                        'email', 'phone', 'address_line1', 'address_line2',
                        'address_line3', 'postcode', 'city', 'state_code',
                        'country_code']) as f(field)) k
            where k.theirs is not null
              and k.ours is not null
              and k.theirs is distinct from k.ours), '[]'::jsonb)
    from public.tax_detail_submissions s
    join public.contacts c on c.id = s.contact_id
   where s.org_id = p_org_id
     and app.is_org_member(p_org_id)
     and s.dismissed_at is null
     and s.superseded_at is null
     and exists (
       select 1
         from unnest(array[
                'tin', 'id_type', 'id_value', 'sst_registration_no',
                'email', 'phone', 'address_line1', 'address_line2',
                'address_line3', 'postcode', 'city', 'state_code',
                'country_code']) as f(field)
        where nullif(btrim(coalesce(to_jsonb(s) ->> f.field, '')), '')
              is not null
          and nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')
              is not null
          and nullif(btrim(coalesce(to_jsonb(s) ->> f.field, '')), '')
              is distinct from
              nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), ''))
   order by s.submitted_at desc;
$$;

comment on function public.pending_tax_submissions(uuid) is
  'Customer tax-detail submissions that disagree with what the contact '
  'holds, with both sides of each disagreement. See 0626.';

revoke all on function public.pending_tax_submissions(uuid) from public, anon;
grant execute on function public.pending_tax_submissions(uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- The invitation
--
-- Restated in full from the built definition, as 0490, 0491 and 0493
-- each had to. The nine above are unchanged.
-- ---------------------------------------------------------------------
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
    ('platform_invoice_reminder',
     'Still outstanding: {{invoice_no}}',
     E'Dear {{company_name}},\n\nOur records show {{currency}} {{total_amount}} still outstanding on invoice {{invoice_no}}, issued {{days}} days ago on {{issue_date}}.\n\n{{description}}\n\nYou can settle it under Settings, on the Your subscription card.\n\nIf you have already paid, please ignore this message and accept our apologies for the crossover.\n\nRegards,\n{{issuer_name}}'),
    ('platform_payment_received',
     'Payment received — thank you',
     E'Dear {{company_name}},\n\nThank you. We have received {{currency}} {{total_amount}} against invoice {{invoice_no}}.\n\nRegards,\n{{issuer_name}}'),
    ('customer_portal',
     'Your account with {{company_name}}',
     E'Dear {{contact_name}},\n\nYou can see everything outstanding on your account with {{company_name}}, and settle any of it, here:\n\n{{link}}\n\nThe link is yours alone -- please do not forward it.\n\nRegards,\n{{company_name}}')
,
    -- 0626. The ask. It says WHY, because a request for a tax number
    -- arriving out of nowhere reads as the thing people are warned
    -- about, and because "so that our invoices to you clear MyInvois"
    -- is a reason the recipient also benefits from.
    ('tax_details_request',
     'Your tax details for e-Invoicing — {{company_name}}',
     E'Dear {{contact_name}},\n\nFrom this year every invoice we issue to you has to be submitted to LHDN''s MyInvois system, and it will not be accepted without your Tax Identification Number (TIN) and the registration or identification number it was issued against.\n\nRather than ask you for them over the telephone, you can fill them in here:\n\n{{link}}\n\nIt shows what we already hold, so in most cases there is little to type. Nothing about your account or any amount owing is on that page.\n\nThe link is yours alone -- please do not forward it.\n\nRegards,\n{{company_name}}')
  ) as t (code, subject, body)
  where t.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- And onto the change feed
--
-- Both tables earn the triggers 0547 asks of every org-scoped table.
-- A submission arriving from a customer is precisely the thing a
-- bookkeeper with the contact list open should be told about, and it
-- arrives while nobody is looking -- which is the case the feed exists
-- for. Neither is a read receipt.
-- ---------------------------------------------------------------------
create trigger live_change_insert after insert on public.tax_detail_requests
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_detail_requests
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_detail_requests
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

create trigger live_change_insert after insert on public.tax_detail_submissions
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_detail_submissions
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_detail_submissions
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
begin
  -- Ten templates now, and the nine that were already there must have
  -- survived the restatement.
  if (select count(*) from (
        select app.default_email_template(c) from (values
          ('document_new'), ('invoice_reminder'), ('payment_received'),
          ('receipt_issued'), ('platform_invoice'),
          ('platform_invoice_reminder'), ('platform_payment_received'),
          ('customer_portal'), ('tax_details_request')
        ) as v(c)) x) <> 9 then
    raise exception '0626: a template was lost in the restatement';
  end if;

  if not has_function_privilege('anon',
       'public.submit_tax_details(text, jsonb)', 'execute')
     or not has_function_privilege('anon',
       'public.open_tax_detail_request(text)', 'execute') then
    raise exception '0626: the public form cannot reach its own functions';
  end if;

  -- And the other direction: nobody without an account may accept a
  -- submission over what the contact already holds.
  if has_function_privilege('anon',
       'public.apply_tax_submission(uuid)', 'execute') then
    raise exception '0626: anon can accept a submission';
  end if;

  -- 0494's guard, restated for the third path. It is here rather than
  -- only in the suite because 0494's whole finding was that both halves
  -- were written from the same assumption, so the test agreed with the
  -- bug.
  if position('app.share_url' in
       (select prosrc from pg_proc p join pg_namespace n
          on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'request_tax_details')) > 0
  then
    raise exception
      '0626: the tax details link is built on the document path';
  end if;
  if app.tax_details_url('abc') not like '%/#/tax-details/abc' then
    raise exception '0626: tax_details_url does not lead to the form';
  end if;
end $do$;
