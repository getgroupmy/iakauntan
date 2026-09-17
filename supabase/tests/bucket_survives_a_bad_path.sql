-- =====================================================================
-- iAkauntan :: one badly named file does not close the bucket
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bucket_survives_a_bad_path.sql
--
-- `0405`. Four storage policies read the organization out of the first
-- segment of an object's path with a hard `::uuid` cast instead of
-- `app.uuid_or_null`, which every other policy in the schema uses. A
-- cast that raises does not deny a row -- it fails the statement, and a
-- policy is evaluated per row, so **one** object whose path does not
-- begin with a uuid made the whole bucket unreadable for everybody.
--
-- Measured before the fix, as a member listing their own company's
-- files: one file visible, then a row named `inbox/...` inserted the
-- way a service-role writer would leave it, and the same query by the
-- same member came back `22P02 invalid input syntax for type uuid:
-- "inbox"`. Their own attachments, behind an error naming a path they
-- have never heard of.
--
-- ---------------------------------------------------------------------
-- The bad row is inserted as the owner, on purpose
--
-- A client cannot make one: the *write* policy carries the same cast
-- and raises before the row lands. The writers that can are the edge
-- functions holding the service role, which are outside RLS entirely --
-- so the fixture writes as the owner because that is who could really
-- do it, not to get round anything.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bucket (org uuid, me uuid, mine text);
grant select on t_bucket to authenticated;

do $$
declare v_org uuid; v_me uuid := pg_temp.test_user(); v_mine text;
begin
  v_org := pg_temp.test_org('Bakul Fail Sdn Bhd');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_me, 'owner', 'active') on conflict do nothing;

  insert into storage.buckets (id, name) values ('mail', 'mail')
    on conflict do nothing;

  -- One well-formed object, the shape `mail_files.ts` writes:
  -- `<org_id>/<email_id>/<n>-<name>`.
  v_mine := v_org || '/11111111-1111-1111-1111-111111111111/1-invois.pdf';
  insert into storage.objects (bucket_id, name, owner)
  values ('mail', v_mine, v_me);

  insert into t_bucket values (v_org, v_me, v_mine);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select me from t_bucket),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_n bigint;
begin
  select * into c from t_bucket;
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  select count(*) into v_n from storage.objects where bucket_id = 'mail';
  perform pg_temp.check_eq('the member can see their own attachment', v_n, 1);
end $$;

reset role;

-- The row a service-role writer could leave: a first segment that is
-- present, and is not a uuid.
insert into storage.objects (bucket_id, name, owner)
values ('mail', 'inbox/22222222-2222-2222-2222-222222222222/1-lain.pdf',
        (select me from t_bucket));

set local role authenticated;

do $$
declare c record; v_n bigint;
begin
  select * into c from t_bucket;

  -- The whole point. Before `0405` this raised 22P02 and the member
  -- could list nothing at all.
  begin
    select count(*) into v_n from storage.objects where bucket_id = 'mail';
  exception when others then
    raise exception
      'FAIL: one badly named object closed the bucket for a member who '
      'has nothing to do with it -- % %', sqlstate, sqlerrm;
  end;

  perform pg_temp.check_eq(
    'their own attachment is still listed beside the bad row', v_n, 1);
  perform pg_temp.check_eq('and it is theirs, not the other one',
    (select name from storage.objects where bucket_id = 'mail'), c.mine);
end $$;

reset role;

-- The same question of the chat bucket, which carries three of the four.
insert into storage.buckets (id, name) values ('chat', 'chat')
  on conflict do nothing;
insert into storage.objects (bucket_id, name, owner)
values ('chat', 'general/33333333-3333-3333-3333-333333333333/note.m4a',
        (select me from t_bucket));

set local role authenticated;

do $$
declare v_n bigint;
begin
  begin
    select count(*) into v_n from storage.objects where bucket_id = 'chat';
  exception when others then
    raise exception
      'FAIL: a badly named object closed the chat bucket -- % %',
      sqlstate, sqlerrm;
  end;
  perform pg_temp.check_eq(
    'a badly named chat file is invisible rather than fatal', v_n, 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- And no policy anywhere casts a path segment
-- ---------------------------------------------------------------------
-- The four were found by asking the catalogue, so the catalogue is
-- asked again here rather than the four being named. A fifth written
-- next year fails this.
do $$
declare v_left text;
begin
  select string_agg(n.nspname || '.' || c.relname || '.' || p.polname, ', '
                    order by n.nspname, c.relname, p.polname)
    into v_left
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where coalesce(pg_get_expr(p.polqual, p.polrelid), '') ~ '::uuid'
      or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') ~ '::uuid';
  if v_left is not null then
    raise exception
      'FAIL: % casts a path segment to uuid inside a policy. A cast that '
      'raises does not deny a row, it fails the statement. Use '
      'app.uuid_or_null.', v_left;
  end if;
  raise notice 'ok   no policy casts a path segment to uuid';
end $$;

-- ---------------------------------------------------------------------
-- The positive control
-- ---------------------------------------------------------------------
-- Every count above would also be safe if the policies simply denied
-- everything, so: the helpers still refuse a null, and still admit a
-- real member.
do $$
declare c record;
begin
  select * into c from t_bucket;
  perform pg_temp.check_true('a null organization is still refused',
    not app.is_org_member(null));
  perform pg_temp.check_true('and a null conversation',
    not app.is_chat_participant(null));
  perform pg_temp.check_true('and a path that is not a uuid reads as null',
    app.uuid_or_null('inbox') is null);
  perform pg_temp.check_true('while an empty one does too',
    app.uuid_or_null('') is null);
  perform pg_temp.check_eq('and a real one reads as itself',
    app.uuid_or_null(c.org::text), c.org);
end $$;

rollback;
