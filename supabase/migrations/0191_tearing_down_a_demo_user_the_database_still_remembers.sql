-- Tearing down a demo user the rest of the database still remembers.
--
-- `app.demo_teardown()` deletes the demo companies and then the demo
-- auth users. That second step works only for as long as every reference
-- to those users sits inside a company that was just deleted — and there
-- are 106 foreign keys into `auth.users` that do not cascade.
--
-- Ninety-seven of them are on org-scoped tables and go out with the
-- organization, so they are not the problem. Nine are on tables with no
-- organization at all:
--
--     chat_calls.started_by            not null
--     chat_messages.sender_id          not null
--     chat_conversations.created_by    nullable
--     chat_links.requested_by          nullable
--     chat_links.decided_by            nullable
--     company_groups.created_by        nullable
--     organizations.created_by         nullable
--     platform_admins.granted_by       nullable
--     platform_settings.updated_by     nullable
--
-- Any one of them holding a row would make the delete fail with a raw
-- foreign key error naming a constraint, in the middle of a rebuild,
-- after the companies were already gone.
--
-- ## The list is derived, not written down
--
-- The nine above are what the catalogue says today. The failure this
-- guards against is not really those nine — it is the tenth, added in
-- six months by somebody putting a `created_by` on a new table who has
-- never heard of the demo teardown. So the pass reads the foreign keys
-- out of `pg_constraint` at run time rather than carrying a list that
-- has to be maintained by hand.
--
-- What it does with each one follows from the column, not from a
-- judgement about the table:
--
--   * **nullable** — set it to null. The row survives; the demo identity
--     on it does not, which is the point of erasing a demo user.
--   * **not null** — delete the row. A message with no author is not a
--     row that can exist, and the author is being removed.
--
-- It reports what it touched, per table, so a teardown that quietly
-- deleted something is not a thing that can happen.
--
-- ## Two guards, and they are mirrors of each other
--
-- The existing guard refuses when a company marked demo has a real
-- member: the flag disagrees with reality, and the answer is a person,
-- not a delete.
--
-- The same disagreement runs the other way and was not guarded. A
-- visitor signed in as `demo@` can create a company; that company is not
-- flagged demo, so the demo user is a member of a real company. Today
-- the teardown leaves that user alone — it only removes demo users with
-- no membership at all — and reports success. The next rebuild then
-- fails on the unique email index, having already deleted everything
-- else, and the error says nothing about a company anybody created.
--
-- So it refuses, and names the person and the company.

create or replace function app.demo_teardown()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_orgs   uuid[];
  v_users  uuid[];
  v_real   text;
  v_owned  text;
  v_names  text;
  v_n      integer;
  v_count  integer;
  v_swept  text := null;
  r        record;
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

  -- And the same disagreement the other way round. A demo login that
  -- has joined a real company cannot be deleted without taking a
  -- decision about that company, so it is not a decision this function
  -- takes.
  select string_agg(distinct u.email || ' in ' || o.name, ', ')
    into v_owned
    from auth.users u
    join public.org_members m on m.user_id = u.id
    join public.organizations o on o.id = m.org_id
   where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
     and not o.is_demo;

  if v_owned is not null then
    raise exception
      'Refusing to tear down: a demo login is a member of a company that '
      'is not marked demo. Somebody created it while signed in as the '
      'demo. Remove the membership, or mark the company demo, and run '
      'this again. Found: %', v_owned
      using errcode = '42501';
  end if;

  -- The three that will not follow the organization out. Note the column
  -- names: chat rows point at the *sender's* company, not at an owning
  -- one, because a conversation can span two tenants.
  delete from public.chat_messages     where sender_org_id  = any (v_orgs);
  delete from public.chat_calls        where started_by_org = any (v_orgs);
  delete from public.platform_invoices where org_id         = any (v_orgs);

  delete from public.organizations where id = any (v_orgs);

  -- Who is actually going. After the companies are gone, and given the
  -- guard above, this is every demo login.
  select array_agg(u.id) into v_users
    from auth.users u
   where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
     and not exists (select 1 from public.org_members m where m.user_id = u.id);

  if v_users is not null then
    -- Everything still pointing at them, read from the catalogue rather
    -- than from a list somebody has to remember to update. Restricted to
    -- `public`: the `auth` schema's own references cascade, and this is
    -- not the place to reach into them.
    for r in
      select n.nspname as sch, cl.relname as tbl, a.attname as col, a.attnotnull as nn
        from pg_constraint c
        join pg_class cl on cl.oid = c.conrelid
        join pg_namespace n on n.oid = cl.relnamespace
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f'
         and c.confrelid = 'auth.users'::regclass
         and c.confdeltype in ('a', 'r')
         -- Single-column only. A composite key into auth.users would
         -- need a decision this loop is not equipped to make, and
         -- silently reading its first column would be worse than not
         -- touching it.
         and array_length(c.conkey, 1) = 1
         and n.nspname = 'public'
       order by cl.relname, a.attname
    loop
      if r.nn then
        execute format('delete from %I.%I where %I = any($1)', r.sch, r.tbl, r.col)
          using v_users;
      else
        execute format('update %I.%I set %I = null where %I = any($1)',
                       r.sch, r.tbl, r.col, r.col)
          using v_users;
      end if;

      get diagnostics v_n = row_count;
      if v_n > 0 then
        v_swept := concat_ws(', ', v_swept,
          format('%s.%s %s %s row(s)', r.tbl, r.col,
                 case when r.nn then 'deleted' else 'cleared' end, v_n));
      end if;
    end loop;

    delete from auth.users u where u.id = any (v_users);
    get diagnostics v_count = row_count;
  else
    v_count := 0;
  end if;

  return format('Removed %s demo company(ies) [%s] and %s demo user(s).%s',
                array_length(v_orgs, 1), v_names, v_count,
                case when v_swept is null then ''
                     else ' Also released: ' || v_swept || '.' end);
end $$;

comment on function app.demo_teardown() is
  'Deletes every organization flagged is_demo and the demo auth users. '
  'Refuses if a flagged company has a real member, or if a demo login '
  'belongs to a company that is not flagged. Clears or deletes anything '
  'still referencing those users, reading the foreign keys from the '
  'catalogue so a table added later is covered without being listed.';

revoke all on function app.demo_teardown() from public, anon, authenticated;
