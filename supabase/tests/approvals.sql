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
--   5. **Being enforced only where there IS a posting path.** Seven of
--      the fifteen document types never post at all -- a requisition,
--      an order, a quotation -- and for four years the only consumer
--      of an approval decision was the posting trigger. The rule
--      editor offered those types, the editor drew the banner, the
--      chain ran, somebody signed, and nothing asked. `0646` reads the
--      answer at the transfer as well, which is where a document that
--      does not post becomes an act.
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

-- ---------------------------------------------------------------------
-- 5: the documents that never post
--
-- `post_purchase_document_internal` accepts bill, purchase credit note
-- and purchase debit note, and refuses everything else by name. So a
-- purchase requisition cannot reach the posting trigger however large
-- it is -- which was the whole of the enforcement until `0646`.
--
-- The requisition is the clearest case because it is the document
-- whose ONLY purpose is to be approved. `doc_types.dart` says so:
-- "it posts nothing -- a request is not a liability -- which is
-- exactly why it needs an approval rule rather than a posting gate to
-- mean anything."
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_boss uuid; v_supp uuid;
  v_small uuid; v_big uuid; v_order uuid; v_req uuid; v_decision text;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.approvals_org('Probe Requisitions');
  v_boss := pg_temp.another_user('po-boss@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss, 'admin') on conflict do nothing;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SU', 'A supplier', 'supplier') returning id into v_supp;

  -- Requisitions at or above RM5,000 need an admin.
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'purchase_document', 'purchase_request', 5000, 1, 'admin');

  -- The requisition itself is inserted OUTSIDE the block that expects a
  -- refusal. An exception inside a plpgsql block rolls the block back,
  -- so a fixture built in the same `begin` as the call that must fail
  -- is gone by the time anything else looks for it -- which is exactly
  -- how the first version of this test reported "Document not found"
  -- from the assertion two lines below rather than from the one it was
  -- about.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_request',
          app.next_document_number_internal(v_org, 'purchase_request'),
          date '2026-02-01', v_supp, 'MYR', 1, 'draft')
  returning id into v_big;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price)
  values (v_org, v_big, 1, 'item', 'Twenty laptops', 20, 450);

  -- It cannot post, and that is not a bug -- it is the reason the rule
  -- had nothing to bite on.
  begin
    perform app.post_purchase_document_internal(v_big);
    raise exception 'a purchase requisition posted, which it must not';
  exception when raise_exception then
    if sqlerrm = 'a purchase requisition posted, which it must not' then
      raise;
    end if;
    raise notice 'ok   a requisition cannot post, so no posting gate reaches it';
  end;

  -- The negative control FIRST, as the rest of this file does: a
  -- requisition under the threshold goes forward untouched. If this
  -- ever stops working, the gate has started catching documents no
  -- rule covers, which is the worse failure.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_request',
          app.next_document_number_internal(v_org, 'purchase_request'),
          date '2026-02-01', v_supp, 'MYR', 1, 'draft')
  returning id into v_small;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price)
  values (v_org, v_small, 1, 'item', 'Two chairs', 2, 300);

  v_order := public.transfer_document(v_small, 'purchase_order');
  perform pg_temp.check_true('a requisition under the threshold becomes an order',
    v_order is not null);

  -- And the one the rule covers does not.
  begin
    perform public.transfer_document(v_big, 'purchase_order');
    raise exception 'an unapproved requisition became a purchase order';
  exception when insufficient_privilege then
    raise notice 'ok   and one over it cannot, unapproved';
  end;

  -- The chain runs exactly as it does for an invoice.
  v_req := public.submit_for_approval('purchase_document', v_big);
  perform pg_temp.check_eq('one rule, one step',
    (select count(*) from public.approval_steps where request_id = v_req), 1);

  -- Still refused while it is only PENDING. The gate reads
  -- `is_approved`, and a request somebody has looked at and not yet
  -- signed is not an approval -- which is the mistake a gate written
  -- against "has a request" would make.
  begin
    perform public.transfer_document(v_big, 'purchase_order');
    raise exception 'a requisition awaiting a signature became an order';
  exception when insufficient_privilege then
    raise notice 'ok   and a request that is only pending is not an approval';
  end;

  perform pg_temp.sign_in_as(v_boss);
  v_decision := public.decide_approval(v_req, true, 'Fine');
  perform pg_temp.check_eq('the admin signs it', v_decision, 'approved');

  perform pg_temp.sign_in_as(v_owner);
  v_order := public.transfer_document(v_big, 'purchase_order');
  perform pg_temp.check_true('and then it becomes a purchase order',
    v_order is not null);
  perform pg_temp.check_eq('carrying what was asked for',
    (select quantity from public.purchase_document_lines
      where document_id = v_order), 20);

  raise notice 'approvals: the seven that never post are gated at the transfer';
end $$;

-- ---------------------------------------------------------------------
-- And a rejection is not a lapse
--
-- The failure a gate written against `status <> 'rejected'` would have:
-- a rejected requisition is refused for the same reason an unsubmitted
-- one is -- nobody approved it -- and the sentence must not suggest
-- waiting.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_boss uuid; v_supp uuid;
  v_doc uuid; v_req uuid; v_decision text;
begin
  v_owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.approvals_org('Probe Refused Requisition');
  v_boss := pg_temp.another_user('po-refuser@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_boss, 'admin') on conflict do nothing;
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SU', 'A supplier', 'supplier') returning id into v_supp;

  -- No document type on the rule: "any purchase document over the
  -- amount". This is the configuration `0646` changes the behaviour of,
  -- so it is the one asserted.
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'purchase_document', null, 5000, 1, 'admin');

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'purchase_order',
          app.next_document_number_internal(v_org, 'purchase_order'),
          date '2026-02-01', v_supp, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price)
  values (v_org, v_doc, 1, 'item', 'A press', 1, 40000);

  perform pg_temp.check_true('a rule naming no type covers a purchase order',
    app.approval_required(v_org, 'purchase_document', 'purchase_order', 40000));

  v_req := public.submit_for_approval('purchase_document', v_doc);
  perform pg_temp.sign_in_as(v_boss);
  -- Its own statement, not an argument to `check_eq`. A volatile
  -- function in a plpgsql simple expression can be evaluated twice, and
  -- the second call would refuse with "that request was already
  -- rejected" -- an assertion failing on the strength of the assertion.
  v_decision := public.decide_approval(v_req, false, 'Not this quarter');
  perform pg_temp.check_eq('the admin refuses it', v_decision, 'rejected');

  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.transfer_document(v_doc, 'goods_received');
    raise exception 'a refused purchase order was received against';
  exception when insufficient_privilege then
    raise notice 'ok   a refused order cannot be received against either';
  end;
end $$;

-- ---------------------------------------------------------------------
-- decide_approval, rule by rule
--
-- A sweep of the function over this file and `approval_state.sql` left
-- ten mutants alive, and the one that matters most was the self-approval
-- guard: whoever raised a document in this file never held the role
-- that clears it, so the role check always refused them first and the
-- guard was never what spoke. The rest were refusals tried without
-- reading their words, and the record a decision leaves -- who, when,
-- what they said, and when the request itself was settled -- which
-- nothing read.
--
-- And one thing no mutant could find, because it was not there: a step
-- that names a PERSON was theirs even after they left the company. 0755.
-- ---------------------------------------------------------------------
create or replace function pg_temp.approval_invoice(p_org uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare v_c uuid; v_ac uuid; v_doc uuid;
begin
  select id into v_c from public.contacts where org_id = p_org and code = 'CU-RULES';
  if v_c is null then
    insert into public.contacts (org_id, code, name, contact_type)
    values (p_org, 'CU-RULES', 'Rules customer', 'customer') returning id into v_c;
  end if;
  select id into v_ac from public.accounts
   where org_id = p_org and account_type = 'revenue' and not is_group limit 1;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', app.next_document_number_internal(p_org, 'invoice'),
          date '2026-02-01', date '2026-03-01', v_c, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     unit_price, account_id, tax_rate)
  values (p_org, v_doc, 1, 'item', 'Work', 1, p_amount, v_ac, 0);
  return v_doc;
end $$;

do $$
declare
  v_org uuid; v_owner uuid; v_partner uuid; v_named uuid;
  v_req uuid; v_state app.approval_status; r record;
begin
  v_org := pg_temp.approvals_org('Kelulusan Peraturan Sdn Bhd');
  v_owner := pg_temp.test_user();
  v_partner := pg_temp.another_user('partner@kelulusan.test');
  v_named := pg_temp.another_user('named@kelulusan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_partner, 'owner'), (v_org, v_named, 'accountant');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- Invoices of 5,000 or more need an owner; of 50,000 or more, the
  -- named accountant.
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'sales_document', 'invoice', 5000, 1, 'owner');

  perform pg_temp.check_refused('a request that is not there says so',
    format('select public.decide_approval(%L, true)', gen_random_uuid()),
    '%No such approval request%', 'P0002');

  -- THE RAISER HOLDS THE ROLE. The owner raises it and is an owner; the
  -- role check lets them through, and the self-approval guard is what
  -- stops them.
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 9000));
  perform pg_temp.check_refused('whoever raised it cannot clear it, though they hold the role',
    format('select public.decide_approval(%L, true)', v_req),
    '%You raised this%', '42501');

  -- The other owner can. What the decision leaves behind.
  perform pg_temp.sign_in_as(v_partner);
  v_state := public.decide_approval(v_req, true, 'Checked against the quote');
  select * into r from public.approval_steps where request_id = v_req;
  perform pg_temp.check_eq('the step records who decided', r.decided_by, v_partner);
  perform pg_temp.check_eq('and when', r.decided_at::text, now()::text);
  perform pg_temp.check_eq('and what they said', r.note, 'Checked against the quote');
  perform pg_temp.check_eq('and the request is settled when its last step is',
    (select decided_at::text from public.approval_requests where id = v_req), now()::text);
  perform pg_temp.check_refused('a settled request says so',
    format('select public.decide_approval(%L, false)', v_req),
    '%already approved%', '22023');

  -- A refusal: the step says rejected and the request is dated.
  perform pg_temp.sign_in_as(v_owner);
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 7000));
  perform pg_temp.sign_in_as(v_partner);
  perform public.decide_approval(v_req, false, 'Wrong customer');
  perform pg_temp.check_eq('a refused step says it refused',
    (select status::text from public.approval_steps where request_id = v_req), 'rejected');
  perform pg_temp.check_eq('and the refusal is dated',
    (select decided_at::text from public.approval_requests where id = v_req), now()::text);

  -- Nothing left to decide, on a request still marked pending.
  perform pg_temp.sign_in_as(v_owner);
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 6000));
  update public.approval_steps set status = 'cancelled' where request_id = v_req;
  perform pg_temp.sign_in_as(v_partner);
  perform pg_temp.check_refused('a request with no step waiting says so',
    format('select public.decide_approval(%L, true)', v_req),
    '%Nothing left to decide%', '22023');

  -- A STEP THAT NAMES A PERSON, who then leaves.
  perform pg_temp.sign_in_as(v_owner);
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_user_id)
  values (v_org, 'sales_document', 'invoice', 50000, 2, v_named);
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 60000));
  perform pg_temp.sign_in_as(v_partner);
  perform public.decide_approval(v_req, true, 'Fine by the owners');
  perform pg_temp.sign_in_as(v_owner);
  delete from public.org_members where org_id = v_org and user_id = v_named;
  perform pg_temp.sign_in_as(v_named);
  perform pg_temp.check_refused('somebody named on a step who has left decides nothing',
    format('select public.decide_approval(%L, true)', v_req),
    '%no longer a member of this company%', '42501');
  perform pg_temp.check_eq('and the step still waits',
    (select status::text from public.approval_steps where request_id = v_req and step_no = 2),
    'pending');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- submit_for_approval, rule by rule
--
-- A sweep of `0167`'s definition left twelve mutants alive. Every
-- document submitted here matched exactly the rules there were, so
-- nothing said which rules make a step: not a retired one, not one for
-- another kind or type, not one whose amount this document does not
-- reach, and not two for the same step. And the refusals -- no such
-- document, somebody who may not write, nothing to approve, approved
-- already -- were never met.
--
-- One is EQUIVALENT: a request left with no steps. `approval_required`
-- filters the rules exactly as the step loop does, so a document it
-- says needs approval always has at least one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_partner uuid; v_viewer uuid;
  v_doc uuid; v_req uuid;
begin
  v_org := pg_temp.approvals_org('Hantar Peraturan Sdn Bhd');
  v_owner := pg_temp.test_user();
  v_partner := pg_temp.another_user('partner@hantar.test');
  v_viewer := pg_temp.another_user('auditor@hantar.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_partner, 'admin'), (v_org, v_viewer, 'auditor');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- Step 1 twice (an owner, then later an admin: the older one stands),
  -- a step 2 that only a larger invoice reaches, a retired step 3, and
  -- steps for credit notes and for purchases.
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role, created_at)
  values (v_org, 'sales_document', 'invoice', 5000, 1, 'owner', now() - interval '1 day'),
         (v_org, 'sales_document', 'invoice', 5000, 1, 'admin', now());
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role, is_active)
  values (v_org, 'sales_document', 'invoice', 50000, 2, 'admin', true),
         (v_org, 'sales_document', 'invoice', 0, 3, 'admin', false),
         (v_org, 'sales_document', 'credit_note', 0, 4, 'admin', true),
         (v_org, 'purchase_document', null, 0, 5, 'admin', true);

  perform pg_temp.check_refused('a document that is not there says so',
    format('select public.submit_for_approval(%L, %L)', 'sales_document', gen_random_uuid()),
    '%No such document%', 'P0002');
  perform pg_temp.check_refused('a document no rule covers is not sent up',
    format('select public.submit_for_approval(%L, %L)', 'sales_document',
           pg_temp.approval_invoice(v_org, 100)),
    '%Nothing needs approving here%', '22023');

  v_doc := pg_temp.approval_invoice(v_org, 9000);
  perform pg_temp.sign_in_as(v_viewer);
  perform pg_temp.check_refused('somebody who may not write may not send it up',
    format('select public.submit_for_approval(%L, %L)', 'sales_document', v_doc),
    '%You may not submit this%', '42501');
  perform pg_temp.sign_in_as(v_owner);
  v_req := public.submit_for_approval('sales_document', v_doc);
  perform pg_temp.check_eq('the request carries the document''s amount',
    (select amount from public.approval_requests where id = v_req), 9000);
  perform pg_temp.check_eq('and only the steps whose rules this document meets',
    (select string_agg(step_no || ':' || approver_role, ',' order by step_no)
       from public.approval_steps where request_id = v_req), '1:owner');

  -- Approved, it is not sent up again.
  perform pg_temp.sign_in_as(v_partner);
  update public.org_members set role = 'owner' where org_id = v_org and user_id = v_partner;
  perform public.decide_approval(v_req, true);
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_refused('an approved document is not sent up again',
    format('select public.submit_for_approval(%L, %L)', 'sales_document', v_doc),
    '%already been approved%', '22023');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- my_approvals, rule by rule
--
-- A sweep of `0169`'s definition killed one mutant of nine: the inbox
-- was only ever read where it held exactly the one request the reader
-- could decide. So nothing said a stranger is refused, that another
-- company's requests, a settled request's leftover steps, a step
-- further down a chain, a step named for somebody else or a document
-- the reader raised themselves stay off it.
--
-- Two are EQUIVALENT, by the tables: a decided step cannot be listed,
-- because the inbox takes the lowest PENDING step number and step
-- numbers are unique per request; and a named step is never listed for
-- a role, because a rule names exactly one approver
-- (`approval_rules_one_approver`) and a step copies it, so a named
-- step's role is null and no role check passes on null.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_other uuid; v_owner uuid; v_partner uuid; v_clerk uuid;
  v_req uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.approvals_org('Meja Kelulusan Sdn Bhd');
  v_owner := pg_temp.test_user();
  v_partner := pg_temp.another_user('partner@meja.test');
  v_clerk := pg_temp.another_user('clerk@meja.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_partner, 'owner'), (v_org, v_clerk, 'admin');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- Invoices of 1,000 or more: an admin first, then an owner. Of 20,000
  -- or more, the clerk by name instead of the role at step 3.
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_org, 'sales_document', 'invoice', 1000, 1, 'admin'),
         (v_org, 'sales_document', 'invoice', 1000, 2, 'owner');
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_user_id)
  values (v_org, 'sales_document', 'invoice', 20000, 3, v_clerk);

  -- Waiting at step 1, the admin's: the owners' step 2 is further down.
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 2000));
  perform pg_temp.sign_in_as(v_partner);
  perform pg_temp.check_eq('a step further down the chain is not on my desk yet',
    (select count(*) from public.my_approvals(v_org)), 0);

  -- Refused at step 1: its step 2 is still pending, and stays off desks.
  perform pg_temp.sign_in_as(v_clerk);
  perform public.decide_approval(v_req, false, 'No');
  perform pg_temp.sign_in_as(v_partner);
  perform pg_temp.check_eq('nor a refused request''s leftover step',
    (select count(*) from public.my_approvals(v_org)), 0);

  -- Step 3 names the clerk; the owners do not see it as theirs. Raised
  -- by the other owner, so it is not hidden from the partner for being
  -- their own.
  perform pg_temp.sign_in_as(v_owner);
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 25000));
  perform pg_temp.sign_in_as(v_clerk);
  perform public.decide_approval(v_req, true);
  perform pg_temp.sign_in_as(v_partner);
  perform public.decide_approval(v_req, true);
  perform pg_temp.check_eq('a step named for somebody else is not on my desk',
    (select count(*) from public.my_approvals(v_org)), 0);

  -- My own document is never on my desk, though I hold the role it asks.
  perform pg_temp.sign_in_as(v_partner);
  v_req := public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_org, 3000));
  perform pg_temp.sign_in_as(v_clerk);
  perform public.decide_approval(v_req, true);
  perform pg_temp.sign_in_as(v_partner);
  perform pg_temp.check_eq('my own document is not on my desk',
    (select count(*) from public.my_approvals(v_org)), 0);
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('while it is on the other owner''s',
    (select count(*) from public.my_approvals(v_org) a where a.request_id = v_req), 1);

  -- Another company, where the partner is an owner too, with a request
  -- waiting for an owner: not on this company's desk.
  v_other := pg_temp.approvals_org('Meja Jiran Sdn Bhd');
  insert into public.org_members (org_id, user_id, role) values (v_other, v_partner, 'owner');
  perform public.create_fiscal_year(v_other, date '2026-01-01');
  insert into public.approval_rules
    (org_id, entity_kind, doc_type, min_amount, step_no, approver_role)
  values (v_other, 'sales_document', 'invoice', 0, 1, 'owner');
  perform public.submit_for_approval('sales_document', pg_temp.approval_invoice(v_other, 500));
  perform pg_temp.sign_in_as(v_partner);
  perform pg_temp.check_eq('another company''s requests are not on this company''s desk',
    (select count(*) from public.my_approvals(v_org) a
      where a.request_id in (select id from public.approval_requests where org_id = v_other)), 0);

  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@meja.test'));
  perform pg_temp.check_refused('a stranger is told it is not their company',
    format('select * from public.my_approvals(%L)', v_org), '%Not your company%', '42501');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- No approval rules on manual journals (0756)
--
-- A journal posts when it is saved and has no draft state (0633), so a
-- rule on journals could never be met: the posting gate refused the
-- journal unapproved, and it could not be sent for approval before it
-- existed. The rule stopped every journal it covered from posting at
-- all. It is refused where rules are written, with the reason.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_rule uuid;
begin
  v_org := pg_temp.approvals_org('Jurnal Tanpa Kelulusan Sdn Bhd');
  perform pg_temp.check_refused('a rule on manual journals is refused, and says why',
    format($q$insert into public.approval_rules
      (org_id, entity_kind, min_amount, step_no, approver_role)
      values (%L, 'journal', 1000, 1, 'admin')$q$, v_org),
    '%posts the moment it is saved%', '23514');

  insert into public.approval_rules
    (org_id, entity_kind, min_amount, step_no, approver_role)
  values (v_org, 'purchase_document', 1000, 1, 'admin')
  returning id into v_rule;
  perform pg_temp.check_true('while a rule on purchases is written as ever', v_rule is not null);
  perform pg_temp.check_refused('and cannot be moved onto journals afterwards',
    format('update public.approval_rules set entity_kind = %L where id = %L', 'journal', v_rule),
    '%posts the moment it is saved%', '23514');
end $$;

rollback;
