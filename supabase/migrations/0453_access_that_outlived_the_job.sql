-- ---------------------------------------------------------------------
-- 0453  Access that outlived the job
-- ---------------------------------------------------------------------
-- 0450 grants a practice's staff access to its clients by writing
-- ordinary `org_members` rows carrying `via_firm_id`. That was the
-- right decision -- no policy in the schema changes meaning -- and it
-- left one thing undone: `app.sync_firm_access` only ever *inserts*.
--
-- Nothing took the access back. Measured, on a company whose books one
-- practice keeps and one member of staff works on:
--
--   | after | rows in `org_members` |
--   |---|---|
--   | while employed | 1 |
--   | **removed from the practice** | **1** |
--   | **suspended at the practice** | **1** |
--
-- Somebody who leaves an accounting firm keeps every client's ledger,
-- payroll and bank detail, and keeps it silently: their membership of
-- the client company is a perfectly ordinary row that nothing marks as
-- borrowed except the `via_firm_id` nobody was reading on the way out.
-- For a practice with forty clients, one resignation is forty
-- companies.
--
-- ### Why a trigger and not a function
--
-- The obvious fix is `remove_firm_member(...)` doing both halves. It is
-- not enough. 0450 grants `delete` on `public.firm_members` to
-- `authenticated` and gates it with the `firm_members_write` policy, so
-- a partner can remove somebody with a single PostgREST call and never
-- touch the function. A rule that only holds when you go through the
-- front door is not a rule.
--
-- So the access follows the membership from a trigger on the table
-- itself: however the row goes away -- function, direct delete, cascade
-- from a deleted firm -- the borrowed rows go with it.
--
-- ### What is deliberately not revoked
--
-- Only rows with `via_firm_id` equal to *this* firm. A person the
-- client invited themselves, or who is at a second practice that also
-- keeps these books, keeps the membership they hold in their own right.
-- That is the same line `detach_company_from_firm` draws, and it is the
-- reason `via_firm_id` exists at all.
--
-- ### And a reader for the staff list
--
-- `profiles_select` is `id = auth.uid() or app.shares_org_with(id)`, so
-- two people at the same practice cannot see each other's names until
-- they happen to share a client. `firm_team` is the way to draw the
-- office, the way `org_team` draws a company.
--
-- ### Mutants
--
-- Four, restated into a built database and run against
-- `supabase/tests/firm_portfolio.sql`. **Two of them survived the
-- assertions as first written**, and both survivors were the same
-- mistake: an assertion about a person the mutation could not reach.
--
--   * the trigger dropped altogether, which is the state 0450 left --
--     killed by "and leaving the practice takes the client with it",
--     which read 1;
--   * suspension not treated as leaving -- killed by "and being
--     suspended ends it too". Somebody stood down pending a question is
--     exactly who should not be reading the books meanwhile;
--   * the revocation not scoped to the firm, so it takes away every
--     membership the leaver holds anywhere -- **survived**. The test
--     had a person who was both firm staff and a client's own invitee,
--     but that person never left, so the trigger never fired for them.
--     The mutation is only visible on somebody who leaves *and* holds a
--     row in their own right, so the leaver was given a company of
--     their own. It now dies on "nor anything the leaver held in their
--     own right";
--   * `firm_team` open to anybody rather than to the practice --
--     **survived**. Asserting that a partner sees the office says
--     nothing about who else does; the assertion added for it reads 0
--     as an outsider, and the mutant returns 3.
--
-- The two survivors are worth more than the two kills. An assertion
-- that names the right behaviour can still be pointed at the one
-- participant the change cannot touch.
-- ---------------------------------------------------------------------

create or replace function app.revoke_firm_access()
returns trigger
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_user uuid;
  v_firm uuid;
begin
  -- On an update this fires only when the person or their standing
  -- changed, and it is the *old* pairing whose access must end: a row
  -- moved from one person to another leaves the first with nothing.
  v_user := OLD.user_id;
  v_firm := OLD.firm_id;

  if v_user is null then
    return null;             -- an invitation nobody has accepted
  end if;

  if TG_OP = 'UPDATE'
     and NEW.user_id is not distinct from OLD.user_id
     and NEW.firm_id is not distinct from OLD.firm_id
     and NEW.status = 'active'
  then
    return null;             -- still here, still working
  end if;

  delete from public.org_members m
   where m.user_id = v_user
     and m.via_firm_id = v_firm;

  return null;
end;
$$;

create trigger revoke_firm_access
  after delete or update of user_id, firm_id, status on public.firm_members
  for each row execute function app.revoke_firm_access();

-- ---------------------------------------------------------------------
-- Who is at the practice
-- ---------------------------------------------------------------------
create or replace function public.firm_team(p_firm_id uuid)
returns table (
  member_id     uuid,
  user_id       uuid,
  email         text,
  full_name     text,
  role          app.firm_role,
  status        app.member_status,
  invited_email text,
  joined_at     timestamptz,
  created_at    timestamptz)
language sql stable security definer
set search_path = public, app, pg_temp
as $$
  select m.id, m.user_id, coalesce(p.email::text, m.invited_email::text),
         p.full_name, m.role, m.status, m.invited_email::text,
         m.joined_at, m.created_at
    from public.firm_members m
    left join public.profiles p on p.id = m.user_id
   where m.firm_id = p_firm_id
     and app.is_firm_member(p_firm_id)
   order by m.created_at;
$$;

revoke all on function public.firm_team(uuid) from public;
grant execute on function public.firm_team(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(to_regprocedure('app.revoke_firm_access()'));
begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'revoke_firm_access'
                    and tgrelid = 'public.firm_members'::regclass) then
    raise exception '0453: access still outlives the job';
  end if;

  -- The whole reason this is a trigger rather than a function.
  if not exists (
    select 1 from pg_trigger
     where tgname = 'revoke_firm_access'
       and tgrelid = 'public.firm_members'::regclass
       and (tgtype & 8) = 8)          -- fires on delete
  then
    raise exception '0453: a direct delete still leaves the access behind';
  end if;

  if position('m.via_firm_id = v_firm' in v_src) = 0 then
    raise exception
      '0453: leaving one practice takes away another practice''s access';
  end if;

  if position('app.is_firm_member(p_firm_id)' in pg_get_functiondef(
       to_regprocedure('public.firm_team(uuid)'))) = 0 then
    raise exception '0453: anybody may read a practice''s staff list';
  end if;
end
$do$;

comment on function app.revoke_firm_access() is
  'When somebody leaves a practice or is suspended at it, the client '
  'access the practice lent them ends with the job -- however the row '
  'goes away. Only rows borrowed from this firm; a membership held in '
  'the person''s own right stands. See 0453.';
