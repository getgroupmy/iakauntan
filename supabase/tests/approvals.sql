-- =====================================================================
-- iAkauntan :: approval workflow
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approvals.sql
--
-- An approval chain has one job — stopping a document reaching the
-- ledger before the right people have seen it — and four ways of
-- quietly not doing it.
--
--   1. **Being inert when it should bite.** A rule that exists and is
--      never consulted.
--   2. **Biting when it should be inert.** The worse failure: a
--      migration that holds up every company's invoices because
--      somebody shipped a default rule. Nothing here is required until a
--      rule is written, and that is asserted first.
--   3. **Letting the raiser sign their own.** The commonest way a chain
--      becomes decoration is the person raising the document also
--      holding the role that clears it.
--   4. **Being enforced in one posting path and not the others.** The
--      gate is a trigger on the table rather than a check inside a
--      posting routine, so it covers the paths nobody has written yet.
--
-- Runs inside a transaction that is rolled back at the end.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company with the add-on switched on.
--
-- `0170` made approvals a paid module, and `app.approval_required`
-- answers false without it. A fixture built on the bare `test_org`
-- would therefore assert that nothing needs approving and pass for
-- entirely the wrong reason — which is what happened to this file the
-- moment the module row landed.
create or replace function pg_temp.approvals_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'approvals', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;
  return v_org;
end $$;

do $$
declare
  v_org uuid; v_owner uuid; v_boss uuid; v_clerk uuid;
  v_c uuid; v_ac uuid; v_small uuid; v_big uuid; v_pr uuid; v_req uuid;
  v_state app.approval_status; v_inbox integer; v_steps integer;
begin
  v_org := pg_temp.approvals_org('Probe Approvals');
  v_owner := pg_temp.test_user();
  v_boss := pg_temp.another_user('boss@iakauntan.test');
  v_clerk := pg_temp.another_user('clerk@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss, 'admin'), (v_org, v_clerk, 'accountant')
  on conflict do nothing;

  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_ac from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group limit 1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CU', 'A customer', 'customer') returning id into v_c;

  -- ------------------------------------------------------------------
  -- 2 first: inert until a rule exists
  --
  -- Asserted before anything is configured, because a migration that
  -- holds up every company's invoicing is a worse outcome than one that
  -- approves too little, and this is the property that rules it out.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('no rule means nothing is required',
    not app.approval_required(v_org, 'sales_document', 'invoice', 999999));

  -- Invoices at or above RM5,000 need an admin.
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'sales_document', 'invoice', 5000, 1, 'admin');

  perform pg_temp.check_true('and once written, it is',
    app.approval_required(v_org, 'sales_document', 'invoice', 9000));
  perform pg_temp.check_true('but only at or above the amount',
    not app.approval_required(v_org, 'sales_document', 'invoice', 1000));
  perform pg_temp.check_true('and only for the type it names',
    not app.approval_required(v_org, 'sales_document', 'credit_note', 9000));
  perform pg_temp.check_true('and not for another kind of thing entirely',
    not app.approval_required(v_org, 'journal', 'manual', 9000));

  -- ------------------------------------------------------------------
  -- 1 and 4: under the threshold posts, over it does not
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', app.next_document_number_internal(v_org, 'invoice'),
          date '2026-02-01', date '2026-03-01', v_c, 'MYR', 1, 'draft')
  returning id into v_small;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_small, 1, 'item', 'Small', 1, 1000, v_ac, 0);

  -- The positive control on the whole file. If this ever stops posting,
  -- the gate has started catching documents it was never meant to.
  perform app.post_sales_document_internal(v_small);
  raise notice 'ok   an invoice under the threshold posts untouched';

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', app.next_document_number_internal(v_org, 'invoice'),
          date '2026-02-01', date '2026-03-01', v_c, 'MYR', 1, 'draft')
  returning id into v_big;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_big, 1, 'item', 'Big', 1, 9000, v_ac, 0);

  begin
    perform app.post_sales_document_internal(v_big);
    raise exception 'a document over the threshold posted without approval';
  exception when insufficient_privilege then
    raise notice 'ok   and one over it cannot post unapproved';
  end;

  -- ------------------------------------------------------------------
  -- The chain
  -- ------------------------------------------------------------------
  v_req := public.submit_for_approval('sales_document', v_big);
  select count(*) into v_steps from public.approval_steps
   where request_id = v_req;
  perform pg_temp.check_eq('one rule, one step', v_steps, 1);

  -- 3: the raiser cannot clear their own.
  begin
    perform public.decide_approval(v_req, true, 'me');
    raise exception 'the person who raised it approved it';
  exception when insufficient_privilege then
    raise notice 'ok   the raiser cannot approve their own document';
  end;

  -- Nor can somebody without the role.
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.decide_approval(v_req, true, 'sure');
    raise exception 'an accountant decided a step reserved for an admin';
  exception when insufficient_privilege then
    raise notice 'ok   and neither can somebody without the role';
  end;
  perform pg_temp.check_eq(
    'so it is not in their inbox either',
    (select count(*) from public.my_approvals(v_org)), 0);

  -- The admin can, and it is in their inbox.
  perform pg_temp.sign_in_as(v_boss);
  select count(*) into v_inbox from public.my_approvals(v_org);
  perform pg_temp.check_eq('it is on the admin''s desk', v_inbox, 1);

  v_state := public.decide_approval(v_req, true, 'Fine');
  perform pg_temp.check_true('one step, so approving it approves the whole',
    v_state = 'approved');
  perform pg_temp.check_eq('and their desk is clear',
    (select count(*) from public.my_approvals(v_org)), 0);

  -- And now it posts.
  perform pg_temp.sign_in_as(v_owner);
  perform app.post_sales_document_internal(v_big);
  raise notice 'ok   approved, it posts';

  -- ------------------------------------------------------------------
  -- Two steps, and a rejection
  --
  -- The clerk raises this one, and that is not incidental. Step 2 is
  -- held by the `owner` role, and the owner is who raised everything
  -- above; had they raised this too, every assertion below about
  -- *ordering* would have been answered by the self-approval rule
  -- instead and passed for the wrong reason.
  -- ------------------------------------------------------------------
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_user_id)
  values (v_org, 'purchase_document', 'purchase_request', 0, 1, v_boss);
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'purchase_document', 'purchase_request', 0, 2, 'owner');

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_request',
          app.next_document_number_internal(v_org, 'purchase_request'),
          date '2026-02-01', v_c, 'MYR', 1, 'draft')
  returning id into v_pr;

  -- A requisition of nothing still needs signing: the rule's threshold
  -- is zero, which is what "every requisition" means.
  perform pg_temp.sign_in_as(v_clerk);
  v_req := public.submit_for_approval('purchase_document', v_pr);
  select count(*) into v_steps from public.approval_steps where request_id = v_req;
  perform pg_temp.check_eq('two rules, two steps', v_steps, 2);

  -- The owner cannot jump the queue: step 2 is not decidable while step
  -- 1 is open, which is the entire point of having an order.
  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.decide_approval(v_req, true, 'skip ahead');
    raise exception 'step two was decided while step one was open';
  exception when insufficient_privilege then
    raise notice 'ok   steps are decided in order';
  end;

  perform pg_temp.sign_in_as(v_boss);
  v_state := public.decide_approval(v_req, true, 'ok from me');
  perform pg_temp.check_true('one of two leaves it pending',
    v_state = 'pending');

  -- The second approver rejects it, and the whole request falls.
  perform pg_temp.sign_in_as(v_owner);
  v_state := public.decide_approval(v_req, false, 'we do not need it');
  perform pg_temp.check_true('a rejection at any step ends it',
    v_state = 'rejected');
  perform pg_temp.check_true('and it is still not approved',
    not app.is_approved(v_org, 'purchase_document', v_pr));

  -- A rejected request may be sent round again; that is how a document
  -- gets fixed. The partial unique index allows it precisely because it
  -- only covers the pending ones.
  perform pg_temp.sign_in_as(v_clerk);
  v_req := public.submit_for_approval('purchase_document', v_pr);
  perform pg_temp.check_eq('and it can be resubmitted',
    (select count(*) from public.approval_requests
      where entity_id = v_pr and status = 'pending'), 1);

  raise notice 'approvals: gate holds, order holds, nobody signs their own';
end $$;

-- ---------------------------------------------------------------------
-- The entitlement fails open
--
-- `0170` sells this as an add-on, which makes the lapse case a real one
-- and an unusual one. Every other module fails closed: switch off
-- inventory and new stock movements are refused. This must fail *open*,
-- because the gate stops documents posting. A lapsed entitlement that
-- left the gate biting while taking away the screen that clears it
-- would leave a company whose card expired with every large invoice
-- permanently unpostable and no way in the product to release them.
--
-- So: on, refused. Off, posts. Back on, refused again — and the rules
-- survive all three, or renewing would hand back an empty screen.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_c uuid; v_ac uuid; v_big uuid;
begin
  -- Deliberately the bare `test_org`: this block switches the
  -- entitlement on and off itself.
  v_org := pg_temp.test_org('Probe Approvals Entitlement');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_ac from public.accounts
   where org_id = v_org and account_type = 'revenue' and not is_group limit 1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CU', 'A customer', 'customer') returning id into v_c;

  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'sales_document', 'invoice', 5000, 1, 'admin');

  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'approvals', true, now())
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.check_true('with the module on, the rule bites',
    app.approval_required(v_org, 'sales_document', 'invoice', 9000));

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', app.next_document_number_internal(v_org, 'invoice'),
          date '2026-02-01', date '2026-03-01', v_c, 'MYR', 1, 'draft')
  returning id into v_big;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (v_org, v_big, 1, 'item', 'Big', 1, 9000, v_ac, 0);

  begin
    perform app.post_sales_document_internal(v_big);
    raise exception 'the gate did not bite while the module was on';
  exception when insufficient_privilege then
    raise notice 'ok   and the document is held';
  end;

  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'approvals';

  perform pg_temp.check_true('the entitlement lapses and the gate releases',
    not app.approval_required(v_org, 'sales_document', 'invoice', 9000));
  perform pg_temp.check_eq('but the rules are kept, not deleted',
    (select count(*) from public.approval_rules where org_id = v_org), 1);

  -- The assertion the whole block exists for.
  perform app.post_sales_document_internal(v_big);
  raise notice 'ok   and the held document posts rather than being stranded';

  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'approvals';
  perform pg_temp.check_true('renewing restores the chain that was configured',
    app.approval_required(v_org, 'sales_document', 'invoice', 9000));
end $$;

rollback;
