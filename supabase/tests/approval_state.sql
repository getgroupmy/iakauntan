-- =====================================================================
-- iAkauntan :: what the editor is told about an approval
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approval_state.sql
--
-- approvals.sql covers the engine: which rules bite, that steps are
-- decided in order, that nobody signs their own, that a rejection ends
-- it, and that a lapsed entitlement fails open. approval_state is the
-- read model on top -- what the document editor asks on every load --
-- and it was called by nothing.
--
-- Two of its columns are its own work rather than the engine's, and
-- both are the kind of thing that is wrong quietly:
--
--   awaiting_who   the next signature owed, as a sentence: a person's
--                  name when the step names a user, "an admin" when it
--                  names a role. It goes on the screen verbatim.
--
--   awaiting_me    whether the signed-in person is the one holding it
--                  up -- the difference between "waiting for approval"
--                  and "waiting for you". It is deliberately false for
--                  the raiser even when they hold the role, because
--                  decide_approval refuses a self-approval: a button
--                  offered here to somebody who will be refused is a
--                  button that always fails.
--
-- The third thing worth pinning is the empty return. A document the
-- caller may not see comes back as no row rather than an exception,
-- because the editor asks this on every load and an error banner is the
-- wrong answer to a permission question.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_boss   uuid;
  v_clerk  uuid;
  v_cust   uuid;
  v_ac     uuid;
  v_small  uuid;
  v_big    uuid;
  v_req    uuid;
  v_own_req uuid;
  v_mine   uuid;
  v_second uuid;
  r        record;
  v_rows   integer;
begin
  v_org := pg_temp.test_org('Probe Kelulusan');
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'approvals', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  v_boss  := pg_temp.another_user('boss@iakauntan.test');
  v_clerk := pg_temp.another_user('clerk@iakauntan.test');
  v_second := pg_temp.another_user('co-owner@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss, 'admin'), (v_org, v_clerk, 'accountant'),
         (v_org, v_second, 'owner')
  on conflict do nothing;

  select id into v_ac from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group limit 1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CU', 'A customer', 'customer') returning id into v_cust;

  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'sales_document', 'invoice', 5000, 1, 'admin');

  perform pg_temp.sign_in_as(v_owner);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', app.next_document_number_internal(v_org, 'invoice'),
          date '2026-02-01', date '2026-03-01', v_cust, 'MYR', 1, 'draft')
  returning id into v_small;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_small, 1, 'item', 'Small', 1, 1000, v_ac, 0);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', app.next_document_number_internal(v_org, 'invoice'),
          date '2026-02-01', date '2026-03-01', v_cust, 'MYR', 1, 'draft')
  returning id into v_big;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_big, 1, 'item', 'Big', 1, 9000, v_ac, 0);

  -- ==================================================================
  -- Below the threshold: nothing to say
  -- ==================================================================
  select * into r from public.approval_state('sales_document', v_small);
  perform pg_temp.check_true('a small invoice needs no approval',
    not r.is_required);
  perform pg_temp.check_true('and is not waiting on anybody',
    r.request_id is null and r.awaiting_who is null);
  perform pg_temp.check_true('nor on the reader', not r.awaiting_me);

  -- ==================================================================
  -- Above it, before anybody is asked
  -- ==================================================================
  select * into r from public.approval_state('sales_document', v_big);
  perform pg_temp.check_true('a large one does need approval', r.is_required);
  perform pg_temp.check_true('and has not got it', not r.is_approved);
  perform pg_temp.check_true('with nothing submitted yet',
    r.request_id is null);
  perform pg_temp.check_true('so nobody is holding it up', not r.awaiting_me);

  -- ==================================================================
  -- Submitted, and waiting on a role
  -- ==================================================================
  v_req := public.submit_for_approval('sales_document', v_big);

  select * into r from public.approval_state('sales_document', v_big);
  perform pg_temp.check_eq('the request is named', r.request_id, v_req);
  perform pg_temp.check_eq('and is pending', r.request_status::text, 'pending');
  perform pg_temp.check_eq('at the first step', r.awaiting_step, 1);
  -- A role, rendered as a sentence for the screen.
  perform pg_temp.check_eq('waiting on the role, spelled out',
    r.awaiting_who, 'an admin');

  -- The raiser holds no admin role here, so this is only half the test.
  perform pg_temp.check_true('and not on the person who raised it',
    not r.awaiting_me);

  -- The admin sees the same request as theirs to sign.
  perform pg_temp.sign_in_as(v_boss);
  select * into r from public.approval_state('sales_document', v_big);
  perform pg_temp.check_true('the admin is told it is waiting on them',
    r.awaiting_me);
  perform pg_temp.check_eq('and it is the same request',
    r.request_id, v_req);

  -- Somebody with neither the role nor the document is told it is
  -- waiting, but not on them.
  perform pg_temp.sign_in_as(v_clerk);
  select * into r from public.approval_state('sales_document', v_big);
  perform pg_temp.check_true('an accountant sees it is pending',
    r.request_status = 'pending');
  perform pg_temp.check_true('and that it is not theirs to sign',
    not r.awaiting_me);

  -- ==================================================================
  -- The raiser who also holds the role the step names
  --
  -- This is the case the column exists for, and it only tests anything
  -- if the raiser genuinely satisfies the step. The rule above names
  -- `admin` and the owner's membership is `owner`, so asserting against
  -- that document would come back false whether the exclusion were
  -- there or not -- true for the wrong reason.
  --
  -- So: a rule naming `owner`, on a document the owner raises
  -- themselves. They now match the step, and decide_approval will still
  -- refuse them. awaiting_me has to stay false, or the editor offers a
  -- button that cannot work.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_owner);
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'sales_document', 'credit_note', 0, 1, 'owner');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'credit_note',
          app.next_document_number_internal(v_org, 'credit_note'),
          date '2026-02-01', date '2026-03-01', v_cust, 'MYR', 1, 'draft')
  returning id into v_mine;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_mine, 1, 'item', 'Credited', 1, 500, v_ac, 0);

  v_own_req := public.submit_for_approval('sales_document', v_mine);

  perform pg_temp.check_true('the raiser holds the very role the step names',
    app.has_org_role(v_org, array['owner']::app.member_role[]));
  select * into r from public.approval_state('sales_document', v_mine);
  perform pg_temp.check_eq('the step is waiting on an owner',
    r.awaiting_who, 'an owner');
  perform pg_temp.check_true('but not on the owner who raised it',
    not r.awaiting_me);
  -- And the engine agrees, which is what makes the column right rather
  -- than merely consistent.
  begin
    perform public.decide_approval(v_own_req, true, 'mine');
    raise exception 'FAIL: the raiser approved their own document';
  exception when insufficient_privilege then
    raise notice 'ok   and decide_approval refuses them, as it says';
  end;

  -- The other owner-role holder is waiting on it, which proves the
  -- exclusion is about who raised it and not about the role itself.
  perform pg_temp.sign_in_as(v_second);
  select * into r from public.approval_state('sales_document', v_mine);
  perform pg_temp.check_true('another owner is waiting on it',
    r.awaiting_me);
  perform pg_temp.sign_in_as(v_owner);

  -- ==================================================================
  -- Once signed
  -- ==================================================================
  perform pg_temp.sign_in_as(v_boss);
  perform public.decide_approval(v_req, true, 'Fine');

  select * into r from public.approval_state('sales_document', v_big);
  perform pg_temp.check_true('an approved document says so', r.is_approved);
  perform pg_temp.check_true('is still one that needed approving',
    r.is_required);
  -- The pending join finds nothing once it is decided, so there is
  -- nobody left to name.
  perform pg_temp.check_true('with nobody left to sign',
    r.awaiting_who is null and r.awaiting_step is null);
  perform pg_temp.check_true('and nobody waiting', not r.awaiting_me);

  -- ==================================================================
  -- A document that is not the reader's to see
  --
  -- No row, not an exception. The editor asks this on every load, and
  -- an error banner is the wrong answer to a permission question.
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  select count(*) into v_rows
    from public.approval_state('sales_document', v_big);
  perform pg_temp.check_eq('a stranger is told nothing, quietly', v_rows, 0);

  select count(*) into v_rows
    from public.approval_state('sales_document', gen_random_uuid());
  perform pg_temp.check_eq('and so is anybody asking about nothing',
    v_rows, 0);

  perform pg_temp.sign_out();
end $$;

rollback;
