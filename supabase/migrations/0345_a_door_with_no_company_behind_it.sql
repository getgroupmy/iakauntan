-- ---------------------------------------------------------------------
-- A door policy for a door that is nobody's company
--
-- `0344` made an address that belongs to the platform rather than to a
-- customer. `may_use_workspace` — the door policy from `0333` — was
-- written when every address belonged to a company, and it asks one
-- question: is this person on that company's team? An `admin` address
-- has no company, `app.is_org_member(null)` is false, and so the door
-- refused everybody.
--
-- Refused loudly, too. The sign-in screen calls this immediately after
-- a successful sign-in and signs the session out again when it answers
-- false, so `pos.iakauntan.com` took a correct password, issued a
-- token, and logged straight back out — the auth log shows `POST
-- /token` and `POST /logout` a moment apart, three times, once per
-- person trying to work out what they were doing wrong.
--
-- The fix is to ask the question only where it means something. A
-- company's door checks the team, as it always has. An address of ours
-- has no team to be on, and a reserved name has no sign-in form to
-- reach in the first place — `0331`'s page answers there — so neither
-- has a door policy to apply.
--
-- Worth restating what this function is, because widening it sounds
-- like widening access and is not: it is a **door policy, not a
-- security boundary**. The same person signing in at `iakauntan.com`
-- with the same password reaches exactly the same data, because the
-- data is protected by RLS on every table rather than by which hostname
-- the browser used. What it buys is that a company's own address
-- behaves like one — a stranger let into a page carrying Sinar's name
-- and logo has been told something untrue about their relationship to
-- Sinar, even though they only ever reach their own books. An address
-- with no company on it tells nobody anything untrue, which is why
-- there is nothing here for it to enforce.
-- ---------------------------------------------------------------------

create or replace function public.may_use_workspace(p_host text)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp as $$
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
              -- `0345`. Only a company's door has a team to be on. An
              -- address of ours has no company, and a reserved one has
              -- no sign-in form; either way there is nothing here to
              -- check, and checking answered false for everybody.
              and (s.purpose is distinct from 'company'
                   or app.is_org_member(s.org_id)
                   or app.is_platform_admin()));
$$;

-- `0165` strips grants from anything recreated in `public`, and this is
-- called by the sign-in screen with a session in hand.
revoke all on function public.may_use_workspace(text) from public;
grant execute on function public.may_use_workspace(text)
  to authenticated, service_role;
