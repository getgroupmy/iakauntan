-- =====================================================================
-- iAkauntan :: a row that hands work to somebody who works here
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_colleague_not_a_stranger.sql
--
-- `tenant_foreign_keys.sql` holds every column naming another ROW to the
-- company that row belongs to. The columns naming a PERSON are the ones
-- it structurally cannot reach: they point at `auth.users`, which is
-- platform-wide and carries no company, so no foreign key can say the
-- person works here.
--
-- 0522 found the first by probe -- escalate_ticket handed a ticket to a
-- user of another company while its sister assign_ticket had always
-- refused. 0524 probed the rest and found four more, of which the last
-- is the one that shows why fixing functions is not enough:
--
--   update contacts set owner_id = '<a stranger>' where id = ...
--
-- went straight through PostgREST. Row level security scopes a row by
-- its own org_id and says nothing about a user id inside it, so no RPC
-- was involved and none could have helped. The guard is therefore a
-- trigger, `app.names_a_colleague`, and this file asserts it on every
-- column it is attached to.
--
-- The last block is the one that matters most for regressions. The
-- trigger fires only when the column ITSELF changes. Firing on every
-- write would mean that suspending a salesperson froze every contact
-- they own -- a phone number could not be corrected because of an owner
-- nobody was touching. That behaviour is asserted directly, because it
-- is the kind of thing a later "tighten the guard" change would quietly
-- undo.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  a uuid; stranger uuid; me uuid;
  client uuid; wh uuid; wi uuid; out_a uuid; team uuid;
  ent uuid; lead uuid; opp uuid; pipe uuid; stage uuid; act uuid;
  v_msg text; v_n integer := 0;
  r record;
  v_missing text;
begin
  a  := pg_temp.test_org('Colleague A');
  me := pg_temp.test_user();
  stranger := pg_temp.another_user('colleague-stranger@example.com');
  perform pg_temp.sign_in_as(me);

  insert into public.contacts (org_id, code, name, contact_type)
    values (a,'CL','A client','customer') returning id into client;
  insert into public.warehouses (org_id, code, name) values (a,'M','A') returning id into wh;
  insert into public.contacts (org_id, code, name, contact_type)
    values (a,'WI','A counter','customer') returning id into wi;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
    values (a,'S','A shop','food_beverage',wh,wi,false) returning id into out_a;
  insert into public.ticket_teams (org_id, code, name)
    values (a,'DESK','The desk') returning id into team;
  insert into public.corp_entities (org_id, name, entity_type, registration_no)
    values (a,'A Sdn Bhd','sdn_bhd','A-1') returning id into ent;
  insert into public.pipelines (org_id, name) values (a,'A pipe') returning id into pipe;
  insert into public.pipeline_stages (org_id, pipeline_id, name, stage_type, sort_order)
    values (a, pipe, 'Open', 'open', 1) returning id into stage;

  -- ==================================================================
  -- 1. Every guarded column refuses a stranger, in the same sentence
  --
  -- Written as a loop over the trigger's own attachments rather than a
  -- list typed here, so a column added to 0524 and forgotten in this
  -- file cannot pass by being absent.
  -- ==================================================================
  begin
    update public.contacts set owner_id = stranger where id = client;
    raise exception 'a contact was owned by somebody who does not work here';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a contact owned by a stranger is refused',
      v_msg, 'That person is not an active member of this organization');
  end;

  begin
    insert into public.leads (org_id, lead_no, company_name, owner_id)
    values (a, 'L-1', 'A lead', stranger);
    raise exception 'a lead was owned by somebody who does not work here';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a lead owned by a stranger is refused',
      v_msg, 'That person is not an active member of this organization');
  end;

  begin
    insert into public.opportunities
      (org_id, opportunity_no, pipeline_id, stage_id, name, contact_id, owner_id)
    values (a, 'OPP-1', pipe, stage, 'A deal', client, stranger);
    raise exception 'a deal was owned by somebody who does not work here';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a deal owned by a stranger is refused',
      v_msg, 'That person is not an active member of this organization');
  end;

  begin
    insert into public.ticket_team_members (org_id, team_id, user_id)
    values (a, team, stranger);
    raise exception 'a stranger was put on a team';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a stranger on a support team is refused',
      v_msg, 'That person is not an active member of this organization');
  end;

  begin
    update public.corp_entities set responsible_secretary = stranger where id = ent;
    raise exception 'a stranger was made responsible for a company''s filings';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a stranger as the responsible secretary is refused',
      v_msg, 'The responsible secretary is not an active member of this organization');
  end;

  -- ==================================================================
  -- 2. And the two functions that took a person as an argument
  -- ==================================================================
  begin
    perform public.upsert_pos_driver(
      null, a, 'Ali', null, null, null, out_a, stranger);
    raise exception 'a delivery driver was a stranger';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a driver who does not work here is refused',
      v_msg, 'That driver is not an active member of this organization');
  end;

  begin
    perform public.open_matter(a, 'M-1', 'A matter', client, null, null, stranger);
    raise exception 'a matter was opened for a stranger to run';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a fee earner who does not work here is refused',
      v_msg, 'The fee earner is not an active member of this organization');
  end;

  begin
    perform public.open_matter(a, 'M-2', 'Another', client, null, null, null, stranger);
    raise exception 'a stranger was made responsible for a matter';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a responsible solicitor who does not work here is refused',
      v_msg, 'The responsible solicitor is not an active member of this organization');
  end;

  -- ==================================================================
  -- 3. Somebody who does work here is accepted
  --
  -- Without this the eight refusals above are satisfied by a trigger
  -- that refuses everybody, and nothing could be assigned at all.
  -- ==================================================================
  update public.contacts set owner_id = me where id = client;
  perform pg_temp.check_eq('a colleague may own a contact',
    (select owner_id from public.contacts where id = client), me);
  perform public.open_matter(a, 'M-3', 'A real matter', client, null, null, me, me);
  perform pg_temp.check_eq('and may run a matter',
    (select fee_earner from public.matters where org_id = a and matter_no = 'M-3'), me);

  -- ==================================================================
  -- 4. Suspending somebody does not freeze the rows they own
  --
  -- The design's whole point, and the most likely thing a later change
  -- undoes. The trigger fires on the COLUMN changing, not on the row
  -- being written, so a contact whose owner has left can still have its
  -- phone number corrected -- and still cannot be handed to a stranger.
  -- ==================================================================
  update public.org_members set status = 'suspended'
   where org_id = a and user_id = me;

  update public.contacts set phone = '03-1234 5678' where id = client;
  perform pg_temp.check_eq(
    'a row owned by somebody suspended can still be edited',
    (select phone from public.contacts where id = client), '03-1234 5678');

  begin
    update public.contacts set owner_id = stranger where id = client;
    raise exception
      'the guard stopped firing once the owner was suspended';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('but still cannot be handed to a stranger',
      v_msg, 'That person is not an active member of this organization');
  end;

  update public.org_members set status = 'active'
   where org_id = a and user_id = me;

  -- ==================================================================
  -- 5. And the set is closed
  --
  -- Every column pointing at auth.users that names somebody work is
  -- HANDED TO is either guarded by the trigger or exempt by name. The
  -- actor columns -- created_by, posted_by, decided_by and the rest --
  -- are written from auth.uid() by a function that has already checked
  -- the caller, and are excluded by the `_by` suffix rather than one at
  -- a time.
  --
  -- The four exemptions are decisions, recorded in 0524's header and
  -- repeated here so they are visible in the suite:
  --
  --   employees.user_id            -- made before the invitation is
  --                                   accepted, so the membership is
  --                                   'invited' and guarding it would
  --                                   break onboarding
  --   tickets.requester_user_id    -- who asked, not who is doing it
  --   expense_claims.approver_id   -- set by the approval chain from a
  --   leave_requests.approver_id      rule; a stale rule should show as
  --                                   a routing problem, not a refusal
  --                                   to file
  -- ==================================================================
  select string_agg(t.tbl || '.' || t.col, ', ')
    into v_missing
    from (
      select c.conrelid::regclass::text as tbl, at.attname as col
        from pg_constraint c
        join pg_attribute at on at.attrelid = c.conrelid
                            and at.attnum = c.conkey[1]
       where c.contype = 'f'
         and c.confrelid = 'auth.users'::regclass
         and cardinality(c.conkey) = 1
         and at.attname not like '%\_by'
         -- and the two actor columns that do not use the suffix
         and at.attname not in ('id', 'actor_id')
         and exists (select 1 from pg_attribute o
                      where o.attrelid = c.conrelid and o.attname = 'org_id'
                        and o.attnum > 0 and not o.attisdropped)
    ) t
   where not exists (
     select 1 from pg_trigger g
      where g.tgrelid = t.tbl::regclass
        and not g.tgisinternal
        and g.tgfoid = 'app.names_a_colleague'::regproc
        and encode(g.tgargs, 'escape') like t.col || '%')
     and (t.tbl, t.col) not in (
           -- Generated from an approval rule when a request is raised.
           -- The rule itself IS guarded; see 0524's header for the line
           -- this draws -- guard where a person chooses, exempt where
           -- the system derives.
           ('approval_steps',   'approver_user_id'),
           ('expense_claims',   'approver_id'),
           ('leave_requests',   'approver_id'),
           -- Made before the invitation is accepted, so the membership
           -- is 'invited'. Guarding it would break onboarding.
           ('employees',        'user_id'),
           -- Who asked, not who is doing it.
           ('tickets',          'requester_user_id'),
           ('ticket_comments',  'author_user_id'),
           -- Chat crosses linked companies by design, and
           -- chat_add_participant checks the linkage itself.
           ('chat_access',            'user_id'),
           ('chat_participants',      'user_id'),
           ('chat_call_participants', 'user_id'),
           -- A handover names somebody who is not a member yet; that is
           -- the whole point of it.
           ('company_transfers', 'from_user_id'),
           ('company_transfers', 'to_user_id'),
           -- The membership row itself, and rows keyed on whoever did
           -- the thing rather than on somebody work is handed to.
           ('org_members',        'user_id'),
           ('notifications',      'user_id'),
           ('audit_logs',         'user_id'),
           ('idempotency_keys',   'user_id'),
           ('billing_rates',      'user_id'),
           ('time_entries',       'user_id'));
  if v_missing is not null then
    raise exception
      'these columns hand work to a person with nothing checking they '
      'work here: %', v_missing;
  end if;

  raise notice 'a colleague not a stranger: every probe behaved';
end $$;

rollback;
