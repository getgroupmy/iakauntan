-- Demo tenants say so on the row, and there is one guarded way to remove
-- them.
--
-- The demo data is rebuilt from time to time — the module catalogue grows
-- and the seeded books stop showing half of it. Until now "rebuild the
-- demo" meant hand-written `delete` statements against the hosted
-- project, working out which company was demo by recognising its name.
-- That is precisely the operation you do not want to get wrong: this
-- deployment now carries a real tenant alongside the demo ones, and a
-- `delete from organizations` with a slightly wrong `where` clause is not
-- recoverable.
--
-- So: the flag is explicit, and the teardown refuses rather than guesses.
--
-- ## What counts as demo
--
-- `organizations.is_demo`, set here for the companies whose every member
-- is a demo auth user, and false for everything else by default. A real
-- company can only become demo if somebody deliberately sets the column,
-- which is a different and much more visible act than mistyping a name.
--
-- ## The guard that matters
--
-- `app.demo_teardown()` deletes only `is_demo` companies, and **refuses
-- outright if any of them has a member who is not a demo auth user.**
-- That is the check that protects a real tenant: flagging one by accident
-- is survivable, because the first real person in it stops the deletion
-- and names them in the error.
--
-- It is `security definer` because it reaches into `auth.users`, and it
-- is granted to nobody. `service_role` reaches it by bypassing grants;
-- `anon` and `authenticated` cannot call it at all. There is no reason
-- for a browser to be able to invoke this.
--
-- ## Not everything cascades
--
-- 165 of the 170 foreign keys pointing at `organizations` are
-- `on delete cascade`, so deleting the row takes the tenant with it.
-- Three are not, and they would block the delete rather than follow it:
--
--     chat_messages.sender_org_id   no action
--     chat_calls.started_by_org     no action
--     platform_invoices.org_id      restrict
--
-- Cleared explicitly first. The chat columns are worth reading twice:
-- they name the *sender's* company rather than an owning one, because a
-- conversation can span two tenants — so neither table has an `org_id`
-- at all, and a teardown written against the obvious column name would
-- fail on a missing column rather than quietly do the wrong thing.
--
-- The two `set null` ones — `contacts.linked_org_id` and
-- `organizations.parent_org_id` — are correct as they are: a contact
-- pointing at a deleted company should lose the link and keep the
-- contact.
--
-- ## What this does not touch
--
-- `superadmin@iakauntan.my`. It is not flagged demo and it is not deleted
-- here, because it is the platform operator rather than a scoped demo
-- login, and an operator account is not something a seed script should be
-- creating and destroying. It needs its password rotated by hand — see
-- the note in `app/lib/src/features/auth/demo_accounts.dart`.

alter table public.organizations
  add column if not exists is_demo boolean not null default false;

comment on column public.organizations.is_demo is
  'True for seeded demo companies, which app.demo_teardown() may delete. '
  'False for every real tenant. Setting this on a company with a real '
  'member does not make it deletable — the teardown refuses and names '
  'the member.';

create index if not exists organizations_is_demo_idx
  on public.organizations (is_demo) where is_demo;

-- ---------------------------------------------------------------------
-- Mark what is already demo
--
-- Every member a demo user, and at least one member — so a company with
-- no members at all is not swept in by an `exists` that is vacuously
-- true.
-- ---------------------------------------------------------------------
update public.organizations o
   set is_demo = true
 where exists (
         select 1 from public.org_members m
           join auth.users u on u.id = m.user_id
          where m.org_id = o.id
            and coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true')
   and not exists (
         select 1 from public.org_members m
           join auth.users u on u.id = m.user_id
          where m.org_id = o.id
            and coalesce(u.raw_app_meta_data ->> 'demo', '') <> 'true');

-- ---------------------------------------------------------------------
-- The teardown
-- ---------------------------------------------------------------------
create or replace function app.demo_teardown()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_orgs   uuid[];
  v_real   text;
  v_users  integer;
  v_names  text;
begin
  select array_agg(id), string_agg(name, ', ' order by name)
    into v_orgs, v_names
    from public.organizations where is_demo;

  if v_orgs is null then
    return 'Nothing is marked is_demo; nothing removed.';
  end if;

  -- The guard. A real person inside a company marked demo means the flag
  -- is wrong, and the right response is to stop and say whose account it
  -- is — not to delete their books and report success.
  select string_agg(distinct o.name || ' (' || u.email || ')', ', ')
    into v_real
    from public.organizations o
    join public.org_members m on m.org_id = o.id
    join auth.users u on u.id = m.user_id
   where o.id = any (v_orgs)
     and coalesce(u.raw_app_meta_data ->> 'demo', '') <> 'true';

  if v_real is not null then
    raise exception
      'Refusing to tear down: a company marked is_demo has real members. '
      'Clear is_demo on it, or remove the member first. Found: %', v_real
      using errcode = '42501';
  end if;

  -- The three that will not follow the organization out. Note the column
  -- names: chat rows point at the *sender's* company, not at an owning
  -- one, because a conversation can span two tenants.
  delete from public.chat_messages     where sender_org_id  = any (v_orgs);
  delete from public.chat_calls        where started_by_org = any (v_orgs);
  delete from public.platform_invoices where org_id         = any (v_orgs);

  delete from public.organizations where id = any (v_orgs);

  -- Demo auth users left belonging to nothing. Scoped to demo-flagged
  -- accounts, so a real user who happened to be in no company is never
  -- a candidate.
  with gone as (
    delete from auth.users u
     where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
       and not exists (select 1 from public.org_members m where m.user_id = u.id)
    returning 1)
  select count(*) into v_users from gone;

  return format('Removed %s demo company(ies) [%s] and %s demo user(s).',
                array_length(v_orgs, 1), v_names, v_users);
end $$;

comment on function app.demo_teardown() is
  'Deletes every organization flagged is_demo, and the demo auth users '
  'left with no membership. Refuses if a flagged company has a member '
  'who is not a demo user.';

-- Granted to nobody. service_role bypasses grants; a browser must not
-- reach this under any role.
revoke all on function app.demo_teardown() from public, anon, authenticated;
