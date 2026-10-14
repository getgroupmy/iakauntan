-- =====================================================================
-- iAkauntan :: a conversation is changed by its functions (0880)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/chat_by_its_functions.sql
--
-- One side of a direct conversation could turn it into a group and add
-- a third person to read it; a participant could change which company
-- they were in it as, or walk out of a direct conversation that cannot
-- be left. The two tables are changed by their functions now, and only
-- by them. Asked with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cf (org uuid, org2 uuid, alice uuid, amir uuid,
  aziz uuid, direct uuid, aziz_direct uuid, grp uuid);
grant all on t_cf to authenticated;

do $$
declare r t_cf;
begin
  r.alice := pg_temp.another_user('alice@cakap.test');
  r.amir  := pg_temp.another_user('amir@cakap.test');
  r.aziz  := pg_temp.another_user('aziz@cakap.test');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org  := pg_temp.test_org('Cakap Sdn Bhd');
  r.org2 := pg_temp.test_org('Cakap Lain Sdn Bhd');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.alice, 'admin', 'active'),
         (r.org, r.amir, 'accountant', 'active'),
         (r.org, r.aziz, 'accountant', 'active'),
         -- Somewhere else Aziz works, where chat is not switched on for him.
         (r.org2, r.aziz, 'accountant', 'active');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (r.org, 'chat', true)
  on conflict (org_id, module_code) do update set is_enabled = true, expires_at = null;
  perform public.chat_set_access(r.org, r.alice, true);
  perform public.chat_set_access(r.org, r.amir, true);
  perform public.chat_set_access(r.org, r.aziz, true);

  perform pg_temp.sign_in_as(r.alice);
  r.direct := public.chat_start_direct(r.org, r.amir, r.org);
  insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body)
  values (r.direct, r.alice, r.org, 'antara kita berdua');
  r.grp := public.chat_create_group(r.org, 'Bilik Projek',
    jsonb_build_array(jsonb_build_object('user_id', r.amir, 'org_id', r.org)));

  perform pg_temp.sign_in_as(r.aziz);
  r.aziz_direct := public.chat_start_direct(r.org, r.amir, r.org);
  insert into t_cf select r.*;
end $$;

-- ---------------------------------------------------------------------
-- One side of a direct conversation does not open it up
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select alice from t_cf));
set local role authenticated;

do $$
declare d t_cf;
begin
  select * into d from t_cf;
  perform pg_temp.check_refused('a direct conversation is not turned into a group',
    format('update public.chat_conversations set is_direct = false where id = %L', d.direct),
    'permission denied for table chat_conversations', '42501');
  perform pg_temp.check_refused('so it still takes no third person',
    format('select public.chat_add_participant(%L, %L, %L)', d.direct, d.aziz, d.org),
    'A direct conversation cannot take a third person', '22023');
  perform pg_temp.check_refused('nor is a conversation made past its functions',
    format('insert into public.chat_conversations (is_direct, created_by) values (false, %L)',
           d.alice),
    'permission denied for table chat_conversations', '42501');

  -- What the functions do is as before.
  perform public.chat_add_participant(d.grp, d.aziz, d.org);
  perform pg_temp.check_eq('a group still takes a third person, by its function',
    (select count(*) from public.chat_participants where conversation_id = d.grp)::int, 3);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('and the direct conversation is still the two of them',
    (select count(*) from public.chat_participants
      where conversation_id = (select direct from t_cf))::int, 2);
end $$;

-- ---------------------------------------------------------------------
-- A participant's own row is marked read, and nothing else
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select aziz from t_cf));
set local role authenticated;

do $$
declare d t_cf;
begin
  select * into d from t_cf;
  perform pg_temp.check_refused('a participant does not change the company they are in it as',
    format('update public.chat_participants set org_id = %L
             where conversation_id = %L and user_id = auth.uid()', d.org2, d.aziz_direct),
    'permission denied for table chat_participants', '42501');
  perform pg_temp.check_refused('nor walk out of a direct conversation',
    format('delete from public.chat_participants
             where conversation_id = %L and user_id = auth.uid()', d.aziz_direct),
    'permission denied for table chat_participants', '42501');
  perform pg_temp.check_refused('which its function refuses, as before',
    format('select public.chat_leave(%L)', d.aziz_direct),
    'A direct conversation cannot be left, only ignored', '22023');

  perform public.chat_mark_read(d.aziz_direct);
  perform public.chat_leave(d.grp);
end $$;

reset role;

do $$
declare d t_cf;
begin
  select * into d from t_cf;
  perform pg_temp.check_eq('he is still in it as the company he joined it as',
    (select org_id from public.chat_participants
      where conversation_id = d.aziz_direct and user_id = d.aziz), d.org);
  perform pg_temp.check_true('marking it read still moves his row',
    (select last_read_at from public.chat_participants
      where conversation_id = d.aziz_direct and user_id = d.aziz) > 'epoch');
  perform pg_temp.check_eq('and he leaves a group by its function',
    (select count(*) from public.chat_participants
      where conversation_id = d.grp and user_id = d.aziz)::int, 0);
end $$;

-- ---------------------------------------------------------------------
-- A message still moves the conversation up the list
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select amir from t_cf));
set local role authenticated;

do $$
declare d t_cf;
begin
  select * into d from t_cf;
  insert into public.chat_messages (conversation_id, sender_id, sender_org_id, body, created_at)
  values (d.direct, d.amir, d.org, 'baik', now() + interval '1 minute');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('a message still moves the conversation''s place in the list',
    (select last_message_at from public.chat_conversations
      where id = (select direct from t_cf))::text,
    (now() + interval '1 minute')::text);
end $$;

-- ---------------------------------------------------------------------
-- No client role writes either table, and no policy says it may
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('neither client role inserts, updates or deletes either table',
    (select string_agg(r || '.' || t || '.' || p, ', ' order by r, t, p)
       from unnest(array['anon', 'authenticated']) r,
            unnest(array['public.chat_conversations', 'public.chat_participants']) t,
            unnest(array['insert', 'update', 'delete']) p
      where has_table_privilege(r, t, p)
         or (p <> 'delete' and has_any_column_privilege(r, t, p))),
    null::text);
  perform pg_temp.check_eq('and no policy on either admits a write',
    (select count(*) from pg_policy
      where polrelid in ('public.chat_conversations'::regclass,
                         'public.chat_participants'::regclass)
        and polcmd in ('a', 'w', 'd', '*'))::int, 0);
end $$;

rollback;
