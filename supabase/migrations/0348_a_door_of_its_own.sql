-- ---------------------------------------------------------------------
-- The login page: the sign-in screen's own copy at a company's door.
--
-- `signin` is the platform's front desk. It is written for somebody
-- arriving at `iakauntan.com` who may not have an account yet — it can
-- offer one, it can carry the platform's headline, and its heading says
-- what iAkauntan is.
--
-- A company's own address is a different room with the same furniture.
-- Nobody arrives at `sinar.iakauntan.com` wondering what the product
-- is; they work there. The words that belong over that form are not the
-- words that belong over ours, and until now there was one row of copy
-- serving both, so an operator could write for one audience or the
-- other and not for both.
--
-- So: a sixth page, `login`, drawn by the same screen at `/login` and
-- reached only from a workspace address. Seeded from `signin` rather
-- than from nothing, because a replicate that starts identical is one
-- an operator edits when they have something different to say — and a
-- blank one is a regression on every door the day this ships.
--
-- Ungated, like `signin` and `signup` and for the same reason: it is
-- wording on a screen that always draws, and gating it would leave a
-- blank heading above a form somebody is trying to sign in to.
-- ---------------------------------------------------------------------

alter table public.site_pages
  drop constraint if exists site_pages_slug_check;

alter table public.site_pages
  add constraint site_pages_slug_check
  check (slug in ('signin', 'signup', 'login', 'terms', 'privacy',
                  'contact'));

-- Seeded from `signin`, so a door that has copy today keeps it. The
-- insert is a select rather than a literal for exactly that reason: the
-- point is that nothing changes on the day this lands.
insert into public.site_pages (slug, title, body, is_published)
select 'login', p.title, p.body, p.is_published
  from public.site_pages p
 where p.slug = 'signin'
on conflict (slug) do nothing;

-- And a row even where there was no `signin` row to copy, so the
-- console has something to edit rather than an absence.
insert into public.site_pages (slug) values ('login')
on conflict (slug) do nothing;

create or replace function public.site_pages()
returns table (slug text, title text, body text, is_published boolean)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.slug, p.title, p.body, p.is_published
    from public.site_pages p
   where p.slug in ('signin', 'signup', 'login') or p.is_published;
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
  -- six there are.
  if p_slug not in ('signin', 'signup', 'login', 'terms', 'privacy',
                    'contact') then
    raise exception 'There are six pages: signin, signup, login, terms, '
                    'privacy and contact. Got %', p_slug
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
-- one that needs anon: the form it draws is the one nobody has signed
-- in to yet.
revoke all on function public.site_pages() from public;
grant execute on function public.site_pages() to anon, authenticated;
grant execute on function public.platform_save_site_page(
  text, text, text, boolean) to authenticated;
