-- ---------------------------------------------------------------------
-- 0494  A portal link that leads somewhere
-- ---------------------------------------------------------------------
-- 0493 emails the customer `app.share_url(token)`, which builds
-- `/#/share/<token>` -- the route that renders one document. A portal
-- token is not a document token: `open_shared_document` looks it up in
-- `document_share_links`, finds nothing, and answers `invalid`. Every
-- portal link 0493 sends leads to a page saying the link is not valid.
--
-- It was not caught because both halves were written from the same
-- assumption and the test extracted the token with `^.*/`, which is
-- happy with either path. The routes are in the Flutter app, and
-- nothing in the database knew there was more than one.
--
-- ### What changes
--
-- `app.portal_url` builds `/#/account/<token>`, the route the customer
-- portal page answers on, and `share_customer_portal` is restated to
-- use it. Nothing else moves.
--
-- The two builders are deliberately separate functions rather than one
-- with a path argument. A caller that has to be told which path to use
-- is a caller that can be told the wrong one, and this migration exists
-- because exactly that happened.
--
-- ### Mutants
--
-- Run against `supabase/tests/customer_portal.sql`, each named with the
-- assertion that kills it:
--   * the portal built on the document path again. Refused by the
--     self-check below before the suite ever sees it, so the kill on
--     record is the migration's own. Run again with that block removed,
--     it dies on "the link goes to the account page, not the document
--     page" -- both guards work, and both are kept;
--   * the site setting ignored -- "and it is built on the site the
--     platform is configured for". That assertion had to be rewritten
--     to bite at all. Written first with an `or not exists` escape for
--     a platform that has configured no site, it was vacuously true on
--     a test database that configures none, and a builder ignoring the
--     setting entirely passed it. It sets `site_url` and compares the
--     whole string now.
-- ---------------------------------------------------------------------

create or replace function app.portal_url(p_token text)
returns text
language sql stable
set search_path = public, app, pg_temp as $$
  select coalesce(
    (select value #>> '{}' from public.platform_settings
      where key = 'site_url'),
    'https://iakauntan.com') || '/#/account/' || p_token;
$$;

comment on function app.portal_url(text) is
  'Where a customer portal token is opened. Deliberately its own '
  'function rather than an argument to app.share_url: 0493 sent every '
  'portal link to the document route by passing the wrong one. '
  'See 0494.';

revoke all on function app.portal_url(text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The one line that was wrong
-- ---------------------------------------------------------------------
-- Restated from the built definition, with `share_url` replaced by
-- `portal_url` and nothing else touched.
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

  -- 0494. The builder this used to call makes the *document* route,
  -- where a portal token resolves to nothing. Named in this
  -- migration's header rather than here, because the self-check below
  -- greps for it and a mention in a comment reads the same as a call.
  v_url := app.portal_url(v_token);

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

revoke all on function public.share_customer_portal(uuid, integer, text)
  from public, anon;
grant execute on function public.share_customer_portal(uuid, integer, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare v_def text := pg_get_functiondef(
  'public.share_customer_portal(uuid, integer, text)'::regprocedure);
begin
  if position('app.portal_url' in v_def) = 0 then
    raise exception '0494: the portal link still goes to the document page';
  end if;
  if position('app.share_url' in v_def) > 0 then
    raise exception '0494: the portal still builds a document URL';
  end if;
  if app.portal_url('abc') not like '%/#/account/abc' then
    raise exception '0494: the account route is not where a portal opens';
  end if;
  -- 0493's own rules, which this restatement must not have lost.
  if position('can_write' in v_def) = 0
     or position('customer_portal' in v_def) = 0 then
    raise exception '0494: the guard or the mail was dropped';
  end if;
end $do$;
