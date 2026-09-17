-- ---------------------------------------------------------------------
-- 0333 — a door that knows its own people
--
-- `sinar.iakauntan.com` is Sinar's door, and until now anybody with an
-- iAkauntan account could walk through it. They landed in their own
-- books, not Sinar's — RLS never let go of that — but the page had
-- Sinar's name and logo on it and let a stranger in, which is not what
-- a company that paid for its own address expects to see.
--
-- ## What this can and cannot be
--
-- Read this before relying on it. This is a **door policy, not a
-- security boundary.** The same person can sign in at `iakauntan.com`
-- with the same password and reach exactly the same data, because the
-- data was never protected by which hostname the browser used — it is
-- protected by RLS on every table, which this does not touch and does
-- not need to.
--
-- What it buys is that a company's own address behaves like a company's
-- own address: the people it lets in are the people on its team, and
-- everybody else is told plainly that they are at the wrong door.
--
-- ## Why a function rather than a lookup
--
-- `workspace_by_host` deliberately returns a name and a logo and no
-- identifiers: it answers to `anon`, and a function that handed out
-- `org_id` for any guessable label would be a directory of every
-- company on the platform. This answers a different question — "may
-- *I* use this door" — for a caller who is already signed in, and
-- returns one boolean, so it leaks nothing either.
-- ---------------------------------------------------------------------
create or replace function public.may_use_workspace(p_host text)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  -- No row for the host is *true*, not false. An address nobody holds
  -- is not a company's door, and the visitor there is getting the
  -- unknown-name page from `0331` rather than a sign-in form; answering
  -- false would also lock everybody out of the bare domain the moment
  -- this is called from somewhere it should not be.
  select not exists (
           select 1
             from public.org_subdomains s
            where s.status = 'approved'
              and s.subdomain = app.normalize_host_label(
                                  split_part(coalesce(p_host, ''), '.', 1)))
      or exists (
           select 1
             from public.org_subdomains s
            where s.status = 'approved'
              and s.subdomain = app.normalize_host_label(
                                  split_part(coalesce(p_host, ''), '.', 1))
              and (app.is_org_member(s.org_id) or app.is_platform_admin()));
$$;

-- Granted to `authenticated` only, and not to `anon`. Before somebody
-- signs in the answer would be "no" for every company, which is both
-- useless and a way to ask which labels are taken.
grant execute on function public.may_use_workspace(text) to authenticated;
