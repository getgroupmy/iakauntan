-- =====================================================================
-- iAkauntan :: what was said on a ticket stays said (0851)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ticket_comments_kept.sql
--
-- A ticket's comments are made by `add_ticket_comment` and
-- `reply_to_shared_ticket`. Before `0851` anybody who could work
-- tickets could also write the table directly: put words in the
-- customer's mouth, rewrite or delete the customer's reply and a
-- colleague's, and make an internal note public. Asked as the owner with
-- the role `authenticated`, as the ticket screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ts_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid; v_team uuid; v_pol uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'ticketing', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.ticket_teams (org_id, code, name, is_default)
  values (v_org, 'SVC', 'Service Desk', true) returning id into v_team;
  insert into public.sla_policies
    (org_id, code, name, business_hours_only, is_default, time_zone)
  values (v_org, 'STD', 'Standard', false, true, 'Asia/Kuala_Lumpur')
  returning id into v_pol;
  insert into public.sla_targets
    (org_id, policy_id, priority, response_minutes, resolution_minutes)
  values (v_org, v_pol, 'p3', 240, 2880);
  return v_org;
end $$;


create temporary table t_tk (org uuid, tkt uuid, cust uuid, internal uuid, said uuid,
  reply uuid, token text);
grant select on t_tk to authenticated;

do $$
declare r t_tk; v_colleague uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.ts_org('Kata Kekal Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C1', 'Puan Aminah', 'customer') returning id into r.cust;
  r.tkt := public.create_ticket(r.org, 'The printer is offline',
    'It stopped this morning', null, 'p3', null, 'email', null, r.cust);
  r.internal := public.add_ticket_comment(r.tkt, 'Customer is difficult; quote high', true);

  v_colleague := pg_temp.another_user('rakan@katakekal.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (r.org, v_colleague, 'sales', 'active', now());
  perform pg_temp.sign_in_as(v_colleague);
  r.said := public.add_ticket_comment(r.tkt, 'There is no call-out fee', false);

  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.token := public.share_ticket(r.tkt, 30, 'aminah@example.test');
  perform pg_temp.sign_out();
  perform public.reply_to_shared_ticket(r.token, 'I do NOT agree to any call-out fee');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select id into r.reply from public.ticket_comments
   where ticket_id = r.tkt and author_contact_id is not null;
  insert into t_tk select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_tk; v_mine uuid;
begin
  select * into d from t_tk;
  perform pg_temp.check_true('the owner, asking as a client who works tickets',
    current_user = 'authenticated' and app.can_write_module(d.org, 'ticketing'));

  -- What was measured.
  perform pg_temp.check_refused('a comment is not put in the customer''s mouth',
    format($q$insert into public.ticket_comments
                (org_id, ticket_id, body, is_internal, author_contact_id, channel)
              values (%L, %L, 'I agree to the RM800 call-out fee', false, %L, 'web')$q$,
           d.org, d.tkt, d.cust),
    'permission denied for table ticket_comments', '42501');
  perform pg_temp.check_refused('nor the customer''s reply rewritten',
    format($q$update public.ticket_comments set body = 'I agree' where id = %L$q$, d.reply),
    'permission denied for table ticket_comments', '42501');
  perform pg_temp.check_refused('nor a colleague''s',
    format($q$update public.ticket_comments set body = 'The call-out fee is RM800' where id = %L$q$, d.said),
    'permission denied for table ticket_comments', '42501');
  perform pg_temp.check_refused('nor an internal note shown to the customer',
    format('update public.ticket_comments set is_internal = false where id = %L', d.internal),
    'permission denied for table ticket_comments', '42501');
  perform pg_temp.check_refused('nor the customer''s reply deleted',
    format('delete from public.ticket_comments where id = %L', d.reply),
    'permission denied for table ticket_comments', '42501');
  perform pg_temp.check_eq('so what was said stands',
    (select body from public.ticket_comments where id = d.reply) || ' / ' ||
    (select body from public.ticket_comments where id = d.said) || ' / ' ||
    (select is_internal::text from public.ticket_comments where id = d.internal),
    'I do NOT agree to any call-out fee / There is no call-out fee / true');

  -- What the ticket screen does is as before, and is signed by whoever
  -- said it.
  v_mine := public.add_ticket_comment(d.tkt, 'The technician comes on Thursday', false);
  perform pg_temp.check_eq('an agent still comments, as themselves',
    (select body || ' / ' || (author_user_id = auth.uid())::text
       from public.ticket_comments where id = v_mine),
    'The technician comes on Thursday / true');
end $$;

reset role;

-- And the customer still replies through the link.
do $$
declare d t_tk; v_out jsonb;
begin
  select * into d from t_tk;
  perform pg_temp.sign_out();
  v_out := public.reply_to_shared_ticket(d.token, 'Thursday is fine');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('the customer still replies through the link',
    (v_out ->> 'state') || ' / ' ||
    (select count(*)::text from public.ticket_comments
      where ticket_id = d.tkt and author_contact_id = d.cust),
    'open / 2');
end $$;

rollback;
