-- ---------------------------------------------------------------------
-- 0334 — the pages around the product
--
-- The landing page has had a console since `0316`. The pages beside it
-- have had nothing: the sign-in screen's wording is a Dart string, and
-- Terms, Privacy and Contact are three URL columns on `landing_page`
-- pointing at whatever the operator hosts elsewhere — which for this
-- platform is nowhere.
--
-- ## One table, five rows, no page builder
--
-- Each page is a heading and a body. That is deliberately less than a
-- CMS: the two legal pages are long prose somebody's advisor writes,
-- the contact page is an address and a phone number, and the two auth
-- pages are a line of welcome above a form that this table does not
-- get to touch. None of them wants blocks, columns or a layout.
--
-- The slugs are fixed rather than free. Five pages exist because five
-- screens read them; a sixth row would be a row nothing renders, and
-- somebody would spend an afternoon looking for where it went.
--
-- ## Published, separately from the landing page
--
-- `landing_page.is_published` gates the marketing site. These do not
-- follow it. A platform can perfectly well need a privacy policy before
-- it has written a front page — and the two auth pages have to draw
-- whatever happens, so their rows are always live and `is_published`
-- governs only whether the *linked* pages appear in the footer.
-- ---------------------------------------------------------------------

create table if not exists public.site_pages (
  slug        text primary key
                check (slug in ('signin', 'signup', 'terms', 'privacy',
                                'contact')),
  title       text,
  body        text,
  is_published boolean not null default false,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null
);

comment on table public.site_pages is
  'The five pages around the product: the two auth screens'' wording, '
  'and Terms, Privacy and Contact. Null title or body means the screen '
  'uses the copy it ships with.';

-- The five, so the console has something to open rather than an empty
-- screen with a Save button and no explanation.
insert into public.site_pages (slug) values
  ('signin'), ('signup'), ('terms'), ('privacy'), ('contact')
on conflict (slug) do nothing;

alter table public.site_pages enable row level security;

-- Read through the function below rather than the table: the table is
-- shut to everybody, and the function decides what an anonymous caller
-- may see.
create policy site_pages_admin on public.site_pages
  for all to authenticated
  using (app.is_platform_admin())
  with check (app.is_platform_admin());

-- ---------------------------------------------------------------------
-- What a visitor gets
--
-- Anon-executable, and named in `statutory.sql`'s allowlist with the
-- reason: somebody who has not signed in has to be able to read the
-- terms they are being asked to accept and the privacy policy that
-- describes what happens to them. A policy only members can read is
-- not a policy.
--
-- The two auth pages come back whether or not they are published —
-- they are wording on a screen that always draws, and gating them
-- would leave a blank heading above the form. The three linked pages
-- are gated, so an operator can draft a privacy policy without it
-- appearing half-written.
-- ---------------------------------------------------------------------
create or replace function public.site_pages()
returns table (slug text, title text, body text, is_published boolean)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.slug, p.title, p.body, p.is_published
    from public.site_pages p
   where p.slug in ('signin', 'signup') or p.is_published;
$$;

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
  -- five there are.
  if p_slug not in ('signin', 'signup', 'terms', 'privacy', 'contact') then
    raise exception 'There are five pages: signin, signup, terms, privacy '
                    'and contact. Got %', p_slug
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

-- `0165`'s event trigger strips PUBLIC and anon from anything created
-- or replaced in `public`, so the grants go back on. The reader is the
-- one that needs anon, for the reason given above.
revoke all on function public.site_pages() from public;
grant execute on function public.site_pages() to anon, authenticated;
grant execute on function public.platform_save_site_page(
  text, text, text, boolean) to authenticated;

grant select, insert, update on public.site_pages to authenticated;
revoke all on public.site_pages from anon;
