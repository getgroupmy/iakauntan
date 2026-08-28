-- ---------------------------------------------------------------------
-- Asking the email first, at an address that is for somebody in
-- particular
--
-- A company's door and an address of ours are both for a known set of
-- people. Taking a password from somebody who was never going to be let
-- in is a round trip that ends in a refusal it could have started with —
-- and at a counter, on a tablet, that refusal arrives after the shift
-- has already started typing.
--
-- So the form asks for the email, this answers whether that email has
-- any business here, and the password box only appears if it does.
--
-- ## What this gives away, said plainly
--
-- This is an oracle, and building it is a decision rather than an
-- oversight. Anyone who can reach `sinar.iakauntan.com` can now ask
-- whether a given address is on Sinar's team, without knowing a
-- password. Before this they could only learn that by knowing one.
--
-- `report_failed_sign_in` (0235) is written the other way round and
-- says so in `supabase/tests/statutory.sql`: the same void comes back
-- either way, precisely so it cannot be used to find out which
-- addresses exist. This function contradicts that stance on purpose,
-- for the two addresses where the product is a device on a counter
-- rather than a login page on the internet.
--
-- What it does *not* give away is anything but a yes or no. No name, no
-- company, no user id, no indication whether the address exists at all
-- anywhere else on the platform — an address nobody has ever heard of
-- and an address belonging to a different company are the same answer.
--
-- The bare domain is deliberately outside all of this. It answers true
-- for everybody, so `iakauntan.com` learns nothing it did not already
-- tell you, and the oracle is confined to addresses an operator
-- deliberately pointed at somebody.
-- ---------------------------------------------------------------------

create or replace function public.may_sign_in_here(
  p_host  text,
  p_email text)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp as $$
  with door as (
    select s.purpose, s.org_id, s.module_code
      from public.org_subdomains s
     where s.status = 'approved'
       and s.subdomain = app.normalize_host_label(
                           split_part(coalesce(p_host, ''), '.', 1))
  ),
  who as (
    select u.id
      from auth.users u
     where lower(btrim(u.email)) = lower(btrim(coalesce(p_email, '')))
  )
  select case
           -- The bare domain, a name nobody holds, a parked name, and
           -- an address of ours that opens the whole product: none of
           -- them is for anybody in particular, so none of them has a
           -- question to ask.
           when not exists (select 1 from door) then true
           when (select purpose from door) = 'reserved' then true
           when (select purpose from door) = 'admin'
                and (select module_code from door) is null then true

           -- A company's door: is this address on that team?
           when (select purpose from door) = 'company' then
             exists (select 1
                       from public.org_members om
                       join who on who.id = om.user_id
                      where om.org_id = (select org_id from door)
                        and om.status = 'active')

           -- One of ours, pointed at a module: is this address in any
           -- company that holds it? The address names a module and not
           -- a company, so any of theirs will do — the same reading
           -- `workspace_module_refusal` takes after the password.
           else
             exists (select 1
                       from public.org_members om
                       join who on who.id = om.user_id
                      where om.status = 'active'
                        and app.has_module(om.org_id,
                                           (select module_code from door)))
             -- Platform staff open any address, here as everywhere.
             or exists (select 1
                          from public.platform_admins pa
                          join who on who.id = pa.user_id)
         end;
$$;

-- Anon by necessity: the whole point is to answer before there is a
-- session. `0165` strips grants from anything created here, and
-- `supabase/tests/statutory.sql` asserts by name which functions anon
-- may execute — this one is added to that list with the paragraph above
-- as its justification.
revoke all on function public.may_sign_in_here(text, text) from public;
grant execute on function public.may_sign_in_here(text, text)
  to anon, authenticated;

comment on function public.may_sign_in_here is
  'Whether an email has any business signing in at this address, asked '
  'before the password. True everywhere that is not for somebody in '
  'particular. An oracle by design; see the migration for what it '
  'gives away.';
