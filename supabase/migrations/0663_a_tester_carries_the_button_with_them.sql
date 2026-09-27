-- =====================================================================
-- Beta testers, and the button that follows them
--
-- `0460` built somewhere to say it is broken and `0660` let a report
-- carry the screenshot. Both of them still ask the same thing of the
-- person who found the fault: stop, find "Report a problem" in a menu,
-- and describe a screen they have now navigated away from.
--
-- The people who will not do that are exactly the people whose reports
-- are worth the most -- the handful trying a build before everybody
-- else. So: a list of them, and for anybody on it a button that is on
-- every screen, that can be dragged out of the way, and that takes the
-- screenshot itself.
--
-- ---------------------------------------------------------------------
-- Why a table and not a flag on the profile
--
-- A column on `profiles` would be writable by the person it describes.
-- `profiles` has a self-update policy -- it must, it is where somebody
-- changes their own name -- and a boolean beside `full_name` is a
-- boolean anybody can set on themselves with the anon key and a REST
-- call.
--
-- It is a small privilege to steal. It is still a privilege nobody
-- should be able to grant themselves, and a separate table with no
-- write policy at all is the same arrangement `0018` chose for
-- `platform_admins`, for the same reason and in the same words: it can
-- only be granted out of band, so nobody escalates into it.
--
-- ---------------------------------------------------------------------
-- What being on the list does NOT do
--
-- Nothing. It is not a role, it gates no data, and no policy anywhere
-- else consults it. It decides whether one button is drawn. That is
-- worth saying plainly, because a table called `beta_testers` reads
-- like an entitlement and the next person to touch it will be tempted
-- to hang one on it -- at which point a list that was safe to be loose
-- with becomes a list that is not.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------
create table public.beta_testers (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  added_by   uuid references auth.users (id) on delete set null,
  -- Who asked for them and why. A list of uuids nobody wrote a reason
  -- beside is a list nobody dares prune, which is how it becomes
  -- permanent.
  note       text,
  created_at timestamptz not null default now()
);

alter table public.beta_testers enable row level security;

comment on table public.beta_testers is
  'People who see the floating report button on every screen. Granted '
  'out of band by platform staff only -- there is no write policy, so '
  'nobody can add themselves. Being on it entitles the holder to '
  'nothing except the button.';

-- A tester may see their OWN row, and that is the whole read rule for
-- an ordinary caller. It is what the app asks on sign-in.
create policy beta_testers_self on public.beta_testers
  for select to authenticated using (user_id = auth.uid());

-- Platform staff see the list, because the console has to show it.
create policy beta_testers_platform on public.beta_testers
  for select to authenticated using (app.is_platform_admin());

-- A policy is not a grant. `0662` was this same omission on
-- `feedback_attachments`, found in CI by `table_grants.sql`, and the
-- two policies above are decoration without this line.
--
-- SELECT only. Every write goes through the guarded functions below,
-- which is what "granted out of band" means in practice.
grant select on public.beta_testers to authenticated;

-- ---------------------------------------------------------------------
-- Asking whether the button belongs on the screen
-- ---------------------------------------------------------------------

-- The app could select its own row through the policy above. This
-- exists because the answer is a single boolean asked once per session,
-- and a function says so in one round trip without the client having to
-- know the table is there at all.
create or replace function public.am_i_a_beta_tester()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.beta_testers b where b.user_id = auth.uid());
$$;

-- `public`, so hosted Supabase's default privileges have ALREADY
-- granted execute to `anon` and `authenticated` by the time this line
-- runs. Revoking is not tidiness; it is the only thing standing between
-- the anon key and this function. `0657` learned that in CI and `0661`
-- learned the mirror image of it in the `app` schema.
revoke all on function public.am_i_a_beta_tester() from public, anon;
grant execute on function public.am_i_a_beta_tester() to authenticated;

comment on function public.am_i_a_beta_tester() is
  'Whether the caller sees the floating report button. Answers about '
  'the CALLER only -- it takes no argument, so it cannot be asked '
  'about anybody else.';

-- ---------------------------------------------------------------------
-- The console's side
-- ---------------------------------------------------------------------

-- Finding somebody to add. Platform staff only, and it answers across
-- every tenant on purpose: the people worth putting on a beta are in
-- customer companies, not in ours.
--
-- Returns at most 20. Not paging, refusing -- a name search that comes
-- back with four hundred rows has not been typed enough of yet, and a
-- console that renders them all is a console somebody scrolls instead
-- of typing one more letter.
create or replace function public.search_platform_users(
  p_query text,
  p_limit integer default 20)
returns table (
  user_id   uuid,
  full_name text,
  email     text,
  is_beta   boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  v_needle text;
begin
  if not app.is_platform_admin() then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  v_needle := btrim(coalesce(p_query, ''));
  -- Two characters before anything comes back. One letter matches most
  -- of the table, and a directory of every user on the platform is not
  -- what a search box is for.
  if length(v_needle) < 2 then
    return;
  end if;

  return query
    select p.id,
           p.full_name,
           p.email::text,
           exists (select 1 from public.beta_testers b
                    where b.user_id = p.id)
      from public.profiles p
     where p.full_name ilike '%' || v_needle || '%'
        or p.email::text ilike '%' || v_needle || '%'
     order by
       -- An exact e-mail first. Somebody who pasted a whole address
       -- knows who they mean and should not have to read a list.
       (lower(p.email::text) = lower(v_needle)) desc,
       p.full_name nulls last,
       p.email
     limit greatest(1, least(coalesce(p_limit, 20), 50));
end; $$;

revoke all on function public.search_platform_users(text, integer)
  from public, anon;
grant execute on function public.search_platform_users(text, integer)
  to authenticated;

comment on function public.search_platform_users(text, integer) is
  'Name/e-mail search across every tenant, for the platform console''s '
  'user picker. Platform staff only. Needs two characters and returns '
  'at most fifty; says of each whether they are already a beta tester '
  'so the console can show it rather than adding a duplicate.';

-- The list itself, joined to the names, because a console showing
-- uuids is a console nobody can prune.
create or replace function public.beta_testers_list()
returns table (
  user_id    uuid,
  full_name  text,
  email      text,
  note       text,
  added_by   text,
  created_at timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  return query
    select b.user_id,
           p.full_name,
           p.email::text,
           b.note,
           a.full_name,
           b.created_at
      from public.beta_testers b
      left join public.profiles p on p.id = b.user_id
      -- Left, and it matters: `added_by` is ON DELETE SET NULL, so a
      -- tester added by somebody who has since left must still appear.
      -- An inner join here would make rows vanish from the list while
      -- leaving the button on the testers' screens.
      left join public.profiles a on a.id = b.added_by
     order by b.created_at desc;
end; $$;

revoke all on function public.beta_testers_list() from public, anon;
grant execute on function public.beta_testers_list() to authenticated;

comment on function public.beta_testers_list() is
  'The beta list with names attached, newest first. Platform staff '
  'only.';

-- ---------------------------------------------------------------------
-- Adding and removing
-- ---------------------------------------------------------------------
create or replace function public.assign_beta_tester(
  p_user_id uuid,
  p_note    text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  -- A uuid that is not a user would otherwise be refused by the
  -- foreign key with a message about a constraint name.
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'No such user' using errcode = '23503';
  end if;

  insert into public.beta_testers (user_id, added_by, note)
  values (p_user_id, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''))
  -- Assigning somebody already on the list updates the note rather
  -- than failing. The console shows who is already on it, so reaching
  -- here twice means somebody meant to change the reason.
  on conflict (user_id) do update
    set note = coalesce(excluded.note, public.beta_testers.note);
end; $$;

revoke all on function public.assign_beta_tester(uuid, text)
  from public, anon;
grant execute on function public.assign_beta_tester(uuid, text)
  to authenticated;

comment on function public.assign_beta_tester(uuid, text) is
  'Puts somebody on the beta list. Platform staff only. Assigning '
  'twice updates the note instead of failing.';

create or replace function public.remove_beta_tester(p_user_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  delete from public.beta_testers where user_id = p_user_id;
end; $$;

revoke all on function public.remove_beta_tester(uuid) from public, anon;
grant execute on function public.remove_beta_tester(uuid) to authenticated;

comment on function public.remove_beta_tester(uuid) is
  'Takes somebody off the beta list. Platform staff only. Their '
  'reports stay; only the button goes.';
