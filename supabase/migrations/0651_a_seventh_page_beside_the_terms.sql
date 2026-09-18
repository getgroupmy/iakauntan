-- =====================================================================
-- A seventh page, beside the terms
--
-- Asked for: a "Terms of Service" page in the console under Terms of
-- Use, and in the same place on the landing page.
--
-- ## Why a new slug and not a rename
--
-- Terms of Use and Terms of Service are not two names for one document
-- in the places that matter. The first is commonly the rules for using
-- a website; the second is the contract for the SERVICE being sold --
-- subscription, payment, liability, termination. A platform that sells
-- accounting software to Malaysian companies plausibly needs both, and
-- the request was to add one BELOW the other rather than to rename the
-- one that is there.
--
-- So `terms` keeps its slug, its URL and whatever an operator has
-- already written into it. Nothing that exists moves.
--
-- ## `terms-of-service`, spelled out
--
-- The slug is the URL: `/terms-of-service`. `tos` would have been
-- shorter and would have read as an abbreviation nobody outside the
-- company knows, on a page whose whole job is to be read by somebody
-- deciding whether to trust this platform with their books. It sits
-- beside `/terms` and the two are told apart at a glance, which
-- `/terms` and `/tos` would not be.
--
-- A hyphen is new here -- the other six slugs are single words -- and
-- nothing objects: the route is `/$slug`, the primary key is `text`,
-- and the console section is keyed by the same string.
--
-- ## Gated, like the other three the footer links to
--
-- `site_pages()` returns the auth pages whatever their state, because
-- they are wording on a screen that always draws. This is not one of
-- those. A terms of service half written is not a terms of service,
-- and a draft of one leaking is worse than a footer with one fewer
-- link -- so it travels only once somebody has published it, which is
-- what the unchanged `or p.is_published` already does.
--
-- The reader therefore needs no change at all, and that is worth
-- saying rather than leaving somebody to check: the only reason it
-- names slugs is to UNGATE three of them.
-- =====================================================================

alter table public.site_pages
  drop constraint if exists site_pages_slug_check;

alter table public.site_pages
  add constraint site_pages_slug_check
  check (slug in ('signin', 'signup', 'login', 'terms', 'terms-of-service',
                  'privacy', 'contact'));

-- Empty and unpublished. Unlike `0348`'s `login`, there is nothing to
-- seed it FROM: this is a different document from the terms of use, and
-- copying that one in would hand an operator a page that looks written
-- and says the wrong thing.
insert into public.site_pages (slug) values ('terms-of-service')
on conflict (slug) do nothing;

comment on table public.site_pages is
  'The seven pages around the product: the three auth screens'' wording, '
  'and Terms of Use, Terms of Service, Privacy and Contact. Null title '
  'or body means the screen uses the copy it ships with.';

-- ---------------------------------------------------------------------
-- The writer's own list of slugs
--
-- Restated rather than left alone. The check constraint would now
-- accept the new page and this function would still refuse it, naming
-- six -- a refusal that is both wrong and confidently specific, which
-- is the worst kind to debug.
-- ---------------------------------------------------------------------
create or replace function public.platform_save_site_page(
  p_slug text,
  p_title text default null,
  p_body text default null,
  p_is_published boolean default null
)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'These pages are the platform''s own and may only be '
                    'changed by a platform administrator'
      using errcode = '42501';
  end if;

  -- The check constraint would catch this, with a message about a
  -- constraint. An operator who mistyped a slug wants to be told which
  -- seven there are.
  if p_slug not in ('signin', 'signup', 'login', 'terms',
                    'terms-of-service', 'privacy', 'contact') then
    raise exception 'There are seven pages: signin, signup, login, terms, '
                    'terms-of-service, privacy and contact. Got %', p_slug
      using errcode = '22023';
  end if;

  insert into public.site_pages (slug) values (p_slug)
    on conflict (slug) do nothing;

  update public.site_pages p set
    -- Emptied to null, like every other optional line of copy on this
    -- platform, so clearing a box restores what the screen ships with
    -- rather than rendering a blank heading.
    title        = case when p_title is null then p.title
                       else nullif(btrim(p_title), '') end,
    body         = case when p_body is null then p.body
                       else nullif(btrim(p_body), '') end,
    is_published = coalesce(p_is_published, p.is_published),
    updated_at   = now(),
    updated_by   = auth.uid()
  where p.slug = p_slug;
end;
$$;

comment on function public.platform_save_site_page is
  'Writes one of the seven pages around the product. Platform '
  'administrators only; an empty title or body clears it back to the '
  'copy the screen ships with.';

-- `0165`'s event trigger strips PUBLIC and anon from anything created
-- or replaced in `public`, so the grant goes back on.
revoke all on function public.platform_save_site_page(
  text, text, text, boolean) from public, anon;
grant execute on function public.platform_save_site_page(
  text, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_n integer;
  v_refused boolean := false;
begin
  select count(*) into v_n from public.site_pages;
  if v_n <> 7 then
    raise exception '0651: expected seven pages, found %', v_n;
  end if;

  -- The new row exists and is NOT published, which is the state a legal
  -- page nobody has written must be in.
  if not exists (select 1 from public.site_pages
                  where slug = 'terms-of-service' and not is_published) then
    raise exception '0651: terms-of-service is missing or already published';
  end if;

  -- And the terms of use are untouched: this adds a page, it does not
  -- move one.
  if not exists (select 1 from public.site_pages where slug = 'terms') then
    raise exception '0651: the terms of use row was lost';
  end if;

  -- The constraint still refuses a slug nothing renders.
  begin
    insert into public.site_pages (slug) values ('about');
  exception when check_violation then v_refused := true;
  end;
  if not v_refused then
    raise exception '0651: the table accepted a slug no screen reads';
  end if;
  delete from public.site_pages where slug = 'about';
end
$do$;
