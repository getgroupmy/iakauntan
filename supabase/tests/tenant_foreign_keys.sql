-- A row may not point at another company's bank account or GL account.
--
-- Row level security scopes a row by its own `org_id` and says nothing
-- about the ids it carries in its foreign key columns. Before `0160`
-- this was accepted:
--
--   insert into receipts (org_id, bank_account_id, …)
--   values ('<my company>', '<somebody else's bank account>', …);
--
-- and `post_receipt` would then move the other company's recorded
-- balance, because it updates `bank_accounts` by the id on the receipt.
-- The same shape reached the ledger: `create_gl_entry_internal` writes
-- `gl_lines` with the caller's `org_id` and whatever `account_id` it was
-- handed, and the `apply_balance` trigger moves that account.
--
-- The refusals are asserted directly rather than by reading
-- `pg_constraint`, because a constraint that exists but is `NOT VALID`,
-- or that a later migration dropped and did not replace, still reads as
-- present.
--
-- The fixture is built here rather than found. A test that goes looking
-- for two companies in whatever data happens to be in the database is a
-- test whose meaning changes with the seed.

-- Runs inside a transaction that is rolled back at the end, like every
-- other file here. That also keeps the deferred `assert_balanced`
-- trigger out of it: probe 3 deliberately leaves a one-sided line, and
-- a rollback never reaches the commit that would check it.

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org_a   uuid;
  v_org_b   uuid;
  v_bank_b  uuid;
  v_acct_b  uuid;
  v_acct_a  uuid;
  v_contact uuid;
  v_entry   uuid;
  v_refused integer := 0;
  v_tried   integer := 0;
  v_state   text;
begin
  v_org_a := pg_temp.test_org('FK Boundary A');
  v_org_b := pg_temp.test_org('FK Boundary B');

  -- Something in B worth pointing at, and the pieces a probe in A needs.
  select id into v_acct_b from public.accounts
   where org_id = v_org_b and code = '1120' limit 1;
  select id into v_acct_a from public.accounts
   where org_id = v_org_a and code = '1120' limit 1;
  if v_acct_a is null or v_acct_b is null then
    raise exception
      'the seeded chart has no 1120 in one of the fixtures (a=%, b=%)',
      v_acct_a, v_acct_b;
  end if;

  insert into public.bank_accounts (org_id, account_id, name)
  values (v_org_b, v_acct_b, 'B''s current account')
  returning id into v_bank_b;

  insert into public.contacts (org_id, code, name)
  values (v_org_a, 'FKTEST', 'A customer of A')
  returning id into v_contact;

  insert into public.gl_entries (org_id, entry_no, entry_date)
  values (v_org_a, 'FKTEST-JV', current_date)
  returning id into v_entry;

  -- 1. A receipt in A naming B's bank account.
  v_tried := v_tried + 1;
  begin
    insert into public.receipts
      (org_id, receipt_no, receipt_date, contact_id, bank_account_id, amount)
    values (v_org_a, 'FKTEST-1', current_date, v_contact, v_bank_b, 1.00);
    raise exception
      'a receipt in one company was allowed to name another company''s '
      'bank account';
  exception
    when foreign_key_violation then v_refused := v_refused + 1;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state = 'P0001' then raise; end if;
      raise exception
        'the receipt probe failed before it could test the rule: % %',
        v_state, sqlerrm;
  end;

  -- 2. A journal line in A debiting B's account. This one stands for
  --    every posting routine at once: they all end at `gl_lines`.
  v_tried := v_tried + 1;
  begin
    insert into public.gl_lines
      (org_id, entry_id, line_no, account_id, description, debit, credit)
    values (v_org_a, v_entry, 1, v_acct_b, 'FKTEST-2', 1.00, 0);
    raise exception
      'a journal line in one company was allowed to debit another '
      'company''s account';
  exception
    when foreign_key_violation then v_refused := v_refused + 1;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if v_state = 'P0001' then raise; end if;
      raise exception
        'the gl_lines probe failed before it could test the rule: % %',
        v_state, sqlerrm;
  end;

  -- 3. The same line, in its own company, still goes in. Without this
  --    the two refusals above are satisfied by a constraint that refuses
  --    everything, and the ledger would be unable to post at all.
  v_tried := v_tried + 1;
  begin
    insert into public.gl_lines
      (org_id, entry_id, line_no, account_id, description, debit, credit)
    values (v_org_a, v_entry, 2, v_acct_a, 'FKTEST-3', 1.00, 0);
    v_refused := v_refused + 1;   -- counted as "behaved correctly"
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    raise exception
      'the new constraint refuses a line posted to its own company''s '
      'account: % %', v_state, sqlerrm;
  end;

  -- The positive control. Two `exception when foreign_key_violation`
  -- blocks that were never entered would leave this green while
  -- asserting nothing at all.
  if v_refused <> v_tried then
    raise exception 'tenant_foreign_keys: % probes ran, % behaved',
      v_tried, v_refused;
  end if;
  if v_tried < 3 then
    raise exception
      'tenant_foreign_keys ran only % probe(s); it is not testing what '
      'it claims to', v_tried;
  end if;

  raise notice
    'tenant boundaries: 2 cross-company writes refused, 1 same-company '
    'write allowed';
end $$;

-- ---------------------------------------------------------------------
-- And an employee belongs to one company too
--
-- The same shape as the bank account above, on the HR side. 0507 found
-- it through `submit_leave_request`: `leave_requests.leave_type_id` had
-- been held to the organization by a composite key since it was written
-- and `employee_id` had not, so HR in one company could file leave
-- naming another company's employee and open a balance row against
-- them. 0507, 0508 and 0509 closed all twenty-six columns.
--
-- Two probes, because the columns come in two shapes: the subject of the
-- row, which is NOT NULL, and the "who did it" column, which is
-- nullable and therefore unenforced by MATCH SIMPLE when it names
-- nobody. A row that names somebody has to name somebody here.
--
-- 0510 did the same for `warehouses`, 0512 for `contacts`, 0513 for
-- `items`, 0514 for `accounts`, 0515 for `gl_entries`, 0516 for
-- `sales_documents`, 0517 for `pos_outlets`, 0518 for `tax_codes`,
-- `purchase_documents` and `pos_sales`, and 0519 for `bank_accounts`,
-- `branches`, `corp_entities`, `corp_persons`, `departments`,
-- `einvoice_documents` and `pos_registers`; and 0520 for the nineteen
-- parents with three or four references each. All thirty-seven parents
-- are probed or covered in the one block below.
-- `contacts` is the widest and the one where a wrong id is money: an
-- invoice raised in this company against another company's customer
-- reads as an ordinary invoice, and only the aged receivable shows the
-- debt sitting on books it does not belong to.
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid; v_b uuid;
  v_emp_a uuid; v_emp_b uuid;
  v_wh_a uuid; v_wh_b uuid; v_wh_a2 uuid;
  v_con_a uuid; v_con_b uuid;
  v_item_a uuid; v_item_b uuid; v_doc_a uuid;
  v_acc_a uuid; v_acc_b uuid;
  v_ent_a uuid; v_ent_b uuid;
  v_doc_b uuid;
  v_out_a uuid; v_out_b uuid;
  v_tax_b uuid; v_bill_a uuid; v_bill_b uuid;
  v_ent2_a uuid; v_per_a uuid; v_per_b uuid;
  v_tkt_b uuid;
  v_tried integer := 0; v_refused integer := 0;
  v_uncovered text;
begin
  v_a := pg_temp.test_org('Employee Boundary A');
  v_b := pg_temp.test_org('Employee Boundary B');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_a, 'EB-A', 'A''s employee', current_date - 400, 'active')
  returning id into v_emp_a;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_b, 'EB-B', 'B''s employee', current_date - 400, 'active')
  returning id into v_emp_b;

  -- 1. An attendance record in A for B's employee: the subject of the
  -- row, and NOT NULL, so the composite key is always enforced.
  v_tried := v_tried + 1;
  begin
    insert into public.attendance_records (org_id, employee_id, work_date)
    values (v_a, v_emp_b, current_date);
    raise exception 'a day in A was recorded against B''s employee';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 2. A department in A headed by B's employee: the nullable kind.
  v_tried := v_tried + 1;
  begin
    insert into public.departments (org_id, code, name, head_employee_id)
    values (v_a, 'OPS', 'Operations', v_emp_b);
    raise exception 'a department in A was headed by B''s employee';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 3. The positive control: A''s own employee, and a department with no
  -- head at all, both go in. Without this the two blocks above could be
  -- refusing for some reason that has nothing to do with the boundary.
  v_tried := v_tried + 1;
  begin
    insert into public.departments (org_id, code, name, head_employee_id)
    values (v_a, 'FIN', 'Finance', v_emp_a);
    insert into public.departments (org_id, code, name, head_employee_id)
    values (v_a, 'ADM', 'Admin', null);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a department headed by its own employee, or '
      'one headed by nobody: %', sqlerrm;
  end;

  -- 4. And the warehouse pairing, which is 0510. A transfer names two
  -- stores; the one that goes wrong quietly is a van leaving this
  -- company's store and arriving in somebody else's, because both ends
  -- read as valid warehouses and the stock simply lands elsewhere.
  --
  -- The stores are created OUTSIDE the probe: a `begin ... exception`
  -- block rolls back everything it did when it raises, so warehouses
  -- created inside it would be gone by the time the next probe used
  -- them, and the failure would read as the boundary key when it was
  -- really a dangling id.
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_a, 'WA', 'A''s store', true) returning id into v_wh_a;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_b, 'WB', 'B''s store', true) returning id into v_wh_b;
  insert into public.warehouses (org_id, code, name)
  values (v_a, 'WA2', 'A''s second store') returning id into v_wh_a2;

  v_tried := v_tried + 1;
  begin
    insert into public.stock_transfers
      (org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id)
    values (v_a, 'TR-CROSS', current_date, v_wh_a, v_wh_b);
    raise exception 'a transfer left A''s store and arrived in B''s';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 5. Its own two stores, which is the ordinary case.
  v_tried := v_tried + 1;
  begin
    insert into public.stock_transfers
      (org_id, transfer_no, transfer_date, from_warehouse_id, to_warehouse_id)
    values (v_a, 'TR-OWN', current_date, v_wh_a, v_wh_a2);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a transfer between two of its own stores: %',
      sqlerrm;
  end;

  -- 5. And a contact, which is 0512. An invoice is the NOT NULL case:
  -- `sales_documents.contact_id` is who owes the money, and an invoice
  -- raised in A against B's customer puts A's receivable on a name that
  -- is not on A's books.
  insert into public.contacts (org_id, contact_type, code, name)
  values (v_a, 'customer', 'C-A', 'A''s customer') returning id into v_con_a;
  insert into public.contacts (org_id, contact_type, code, name)
  values (v_b, 'customer', 'C-B', 'B''s customer') returning id into v_con_b;

  v_tried := v_tried + 1;
  begin
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, contact_id)
    values (v_a, 'invoice', 'INV-X', current_date, v_con_b);
    raise exception 'an invoice in A was raised against B''s customer';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 6. The nullable case on the same parent, and the positive control:
  -- an asset bought from B's supplier is refused, one bought from A's
  -- own and one with no supplier at all both go in.
  v_tried := v_tried + 1;
  begin
    insert into public.fixed_assets
      (org_id, asset_no, name, acquisition_date, cost,
       useful_life_months, supplier_id)
    values (v_a, 'FA-X', 'Van', current_date - 30, 90000, 60, v_con_b);
    raise exception 'an asset in A was bought from B''s supplier';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.fixed_assets
      (org_id, asset_no, name, acquisition_date, cost,
       useful_life_months, supplier_id)
    values (v_a, 'FA-OWN', 'Lori', current_date - 30, 90000, 60, v_con_a);
    insert into public.fixed_assets
      (org_id, asset_no, name, acquisition_date, cost,
       useful_life_months, supplier_id)
    values (v_a, 'FA-NONE', 'Meja', current_date - 30, 900, 60, null);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse an asset from its own supplier, or one from '
      'no supplier at all: %', sqlerrm;
  end;

  -- 7. And an item, which is 0513. A stock movement is the NOT NULL
  -- case and the one that costs money twice over: the quantity moves
  -- against the item named, so a movement written in A against B's item
  -- takes stock off B's shelf and values it on A's balance sheet.
  insert into public.items
    (org_id, code, name, item_type, uom_code, track_inventory)
  values (v_a, 'IT-A', 'A''s item', 'stock', 'EA', true)
  returning id into v_item_a;
  insert into public.items
    (org_id, code, name, item_type, uom_code, track_inventory)
  values (v_b, 'IT-B', 'B''s item', 'stock', 'EA', true)
  returning id into v_item_b;

  v_tried := v_tried + 1;
  begin
    insert into public.stock_movements
      (org_id, movement_no, movement_date, movement_type, item_id,
       warehouse_id, quantity, unit_cost, total_cost, balance_quantity,
       balance_value, average_cost_after)
    values (v_a, 'SM-X', current_date, 'purchase_receipt', v_item_b, v_wh_a,
            5, 10, 50, 5, 50, 10);
    raise exception 'a movement in A moved B''s item';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 8. The nullable case on the same parent: an invoice line. A line
  -- may carry no item at all -- that is what line_type 'description'
  -- is -- so MATCH SIMPLE leaves it alone, and a line that DOES name
  -- an item has to name one of this company's.
  --
  -- The self-reference `items.parent_item_id` is deliberately not the
  -- probe here, though it is the obvious one. `app.items_variant_guard`
  -- from 0211 already refuses a variant of another company's style and
  -- raises before the key is ever reached, so a probe on it would pass
  -- whether or not 0513 exists. The coverage query below is what proves
  -- that key is there.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id)
  values (v_a, 'invoice', 'INV-ITEM', current_date, v_con_a)
  returning id into v_doc_a;

  v_tried := v_tried + 1;
  begin
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description, item_id,
       quantity, unit_price, line_subtotal, line_total)
    values (v_a, v_doc_a, 1, 'item', 'B''s item', v_item_b,
            1, 10, 10, 10);
    raise exception 'an invoice line in A sold B''s item';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description, item_id,
       quantity, unit_price, line_subtotal, line_total)
    values (v_a, v_doc_a, 2, 'item', 'A''s item', v_item_a,
            1, 10, 10, 10);
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, description, item_id,
       quantity, unit_price, line_subtotal, line_total)
    values (v_a, v_doc_a, 3, 'description', 'Terima kasih', null,
            0, 0, 0, 0);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a line for its own item, or a line with no '
      'item at all: %', sqlerrm;
  end;

  -- 9. And an account, which is 0514. This one closes a different
  -- shape of failure from the four above. `gl_lines.account_id` has
  -- been held to the organization since 0160, so a wrong account never
  -- reached the ledger; what it did was stop the posting. An item
  -- pointed at an account outside this company's chart types fine,
  -- sells fine, and then fails at the moment somebody presses post,
  -- with a foreign key error naming a constraint they cannot act on.
  -- 0514 refuses it where the person can see what they did.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_a, '4999', 'A''s sales', 'revenue', 'sales')
  returning id into v_acc_a;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_b, '4999', 'B''s sales', 'revenue', 'sales')
  returning id into v_acc_b;

  v_tried := v_tried + 1;
  begin
    update public.items set sales_account_id = v_acc_b where id = v_item_a;
    raise exception 'A''s item was pointed at B''s sales account';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 10. The self-reference: the chart is a tree, and a branch of A's
  -- chart may not hang off B's.
  v_tried := v_tried + 1;
  begin
    insert into public.accounts
      (org_id, code, name, account_type, account_subtype, parent_id)
    values (v_a, '4999-1', 'A''s sub-account', 'revenue', 'sales', v_acc_b);
    raise exception 'A''s account hung off B''s';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    update public.items set sales_account_id = v_acc_a where id = v_item_a;
    insert into public.accounts
      (org_id, code, name, account_type, account_subtype, parent_id)
    values (v_a, '4999-2', 'A''s own sub-account', 'revenue', 'sales', v_acc_a);
    insert into public.accounts
      (org_id, code, name, account_type, account_subtype, parent_id)
    values (v_a, '4998', 'A''s top-level', 'revenue', 'sales', null);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse an item pointed at its own account, or a '
      'top-level account with no parent: %', sqlerrm;
  end;

  -- 11. And a journal, which is 0515. `gl_lines.entry_id` is the one
  -- column in this whole programme that is NOT NULL on the child and
  -- names the parent as its own identity: a line IS part of a journal.
  -- So the key is enforced on every row rather than only the ones that
  -- name somebody, and a line written into another company's journal
  -- is a line on their trial balance.
  --
  -- The block leaves one-sided journals behind on purpose; the file
  -- header explains why that is safe here (the deferred
  -- `assert_balanced` trigger is never reached, because this
  -- transaction rolls back).
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, total_debit, total_credit)
  values (v_a, 'JV-A', current_date, 'manual', 0, 0)
  returning id into v_ent_a;
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, total_debit, total_credit)
  values (v_b, 'JV-B', current_date, 'manual', 0, 0)
  returning id into v_ent_b;

  v_tried := v_tried + 1;
  begin
    insert into public.gl_lines
      (org_id, entry_id, line_no, account_id, debit, credit)
    values (v_a, v_ent_b, 1, v_acc_a, 100, 0);
    raise exception 'a line in A was written into B''s journal';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 12. The self-reference: a reversal in A cancelling an entry in B.
  v_tried := v_tried + 1;
  begin
    insert into public.gl_entries
      (org_id, entry_no, entry_date, source, total_debit, total_credit,
       is_reversal, reversed_entry_id)
    values (v_a, 'JV-A-REV', current_date, 'manual', 0, 0, true, v_ent_b);
    raise exception 'a reversal in A cancelled B''s journal';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.gl_lines
      (org_id, entry_id, line_no, account_id, debit, credit)
    values (v_a, v_ent_a, 1, v_acc_a, 100, 0);
    insert into public.gl_entries
      (org_id, entry_no, entry_date, source, total_debit, total_credit,
       is_reversal, reversed_entry_id)
    values (v_a, 'JV-A-REV', current_date, 'manual', 0, 0, true, v_ent_a);
    insert into public.gl_entries
      (org_id, entry_no, entry_date, source, total_debit, total_credit)
    values (v_a, 'JV-A2', current_date, 'manual', 0, 0);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a line in its own journal, a reversal of its '
      'own entry, or a journal that reverses nothing: %', sqlerrm;
  end;

  -- 13. And an invoice, which is 0516. The share link is the probe
  -- worth having, because it is the one that leaves the building: it
  -- is the token a customer with no account follows to see a document,
  -- and it is read with that token rather than a session, so RLS is no
  -- help. A link in A pointing at B's invoice shows B's invoice to
  -- somebody who was never meant to see it.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id)
  values (v_b, 'invoice', 'INV-B', current_date, v_con_b)
  returning id into v_doc_b;

  v_tried := v_tried + 1;
  begin
    insert into public.document_share_links
      (org_id, document_id, token_hash, expires_at)
    values (v_a, v_doc_b, 'hash-x', now() + interval '7 days');
    raise exception 'a share link in A pointed at B''s invoice';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 14. The self-reference that would move money: a credit note in A
  -- naming B's invoice as the one it cancels.
  v_tried := v_tried + 1;
  begin
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, original_invoice_id)
    values (v_a, 'credit_note', 'CN-X', current_date, v_con_a, v_doc_b);
    raise exception 'a credit note in A cancelled B''s invoice';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.document_share_links
      (org_id, document_id, token_hash, expires_at)
    values (v_a, v_doc_a, 'hash-own', now() + interval '7 days');
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, original_invoice_id)
    values (v_a, 'credit_note', 'CN-OWN', current_date, v_con_a, v_doc_a);
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, original_invoice_id)
    values (v_a, 'invoice', 'INV-A2', current_date, v_con_a, null);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a link to its own invoice, a credit note '
      'against its own invoice, or an invoice that cancels nothing: %',
      sqlerrm;
  end;

  -- 15. And an outlet, which is 0517, and which has a history worth
  -- stating. The 0505 audit cleared `merge_pos_sales`, `move_pos_sale`
  -- and `seat_table` on the grounds that each refuses two different
  -- outlets, and an outlet belongs to one company. That was right about
  -- the functions and rested on a fact the schema did not enforce:
  -- nothing stopped a register in A naming B's outlet in the first
  -- place. The guard held because the data happened to be right.
  --
  -- Sixteen of the seventeen columns are NOT NULL, so these keys bite
  -- on nearly every row rather than only the ones that name somebody.
  insert into public.pos_outlets (org_id, code, name, business_type)
  values (v_a, 'OUT-A', 'A''s shop', 'retail') returning id into v_out_a;
  insert into public.pos_outlets (org_id, code, name, business_type)
  values (v_b, 'OUT-B', 'B''s shop', 'retail') returning id into v_out_b;

  v_tried := v_tried + 1;
  begin
    insert into public.pos_registers (org_id, outlet_id, code, name)
    values (v_a, v_out_b, 'REG-X', 'Kaunter');
    raise exception 'a register in A was put in B''s outlet';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.pos_registers (org_id, outlet_id, code, name)
    values (v_a, v_out_a, 'REG-OWN', 'Kaunter A');
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a register in its own outlet: %', sqlerrm;
  end;

  -- 16. A tax code, a bill and its self-reference, which is 0518.
  --
  -- The tax code is the one that reaches a statutory return.
  -- tax_codes' own accounts were held to the organization by 0514, so
  -- the account a tax collects INTO is already right; what was not is
  -- the code named on the line. A line pointing at another company's
  -- tax code takes their rate and their registration into this
  -- company's SST return.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to)
  values (v_b, 'SR-B', 'B''s standard rate', '01', 8, 'both')
  returning id into v_tax_b;

  v_tried := v_tried + 1;
  begin
    update public.sales_document_lines set tax_code_id = v_tax_b
     where org_id = v_a and document_id = v_doc_a and line_no = 2;
    raise exception 'a line in A was charged at B''s tax code';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  -- 17. The buy side of 0516, and its self-reference: a debit note in A
  -- naming B's bill as the one it cancels.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, total_amount,
     base_total_amount, balance_amount)
  values (v_a, 'bill', 'BILL-A', current_date, v_con_a, 100, 100, 100)
  returning id into v_bill_a;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, total_amount,
     base_total_amount, balance_amount)
  values (v_b, 'bill', 'BILL-B', current_date, v_con_b, 100, 100, 100)
  returning id into v_bill_b;

  v_tried := v_tried + 1;
  begin
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, total_amount,
       base_total_amount, balance_amount, original_bill_id)
    values (v_a, 'purchase_debit_note', 'DN-X', current_date, v_con_a,
            100, 100, 100, v_bill_b);
    raise exception 'a debit note in A cancelled B''s bill';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, total_amount,
       base_total_amount, balance_amount, original_bill_id)
    values (v_a, 'purchase_debit_note', 'DN-OWN', current_date, v_con_a,
            100, 100, 100, v_bill_a);
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, total_amount,
       base_total_amount, balance_amount, original_bill_id)
    values (v_a, 'bill', 'BILL-A2', current_date, v_con_a,
            100, 100, 100, null);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a debit note against its own bill, or a bill '
      'that cancels nothing: %', sqlerrm;
  end;

  -- 18. An officer, which is 0519. The register of directors and
  -- secretaries is what SSM is told, so a person from another
  -- company's register appearing on this one's board is a filing that
  -- names the wrong human being.
  --
  -- The corporate secretarial module looked like it ought to cross the
  -- boundary, since a practice handles other people's companies. It
  -- does not: a `corp_entities` row is the PRACTICE's record of a
  -- company it acts for and carries the practice's own org_id, and
  -- every officer, charge and share event hangs off that record inside
  -- the same practice. That was checked against the hosted data before
  -- the keys were written, not assumed.
  --
  -- `corp_share_events` would be the better probe -- it names TWO
  -- people, the pairing shape of probe 4 -- but it cannot be used:
  -- a trigger refuses a transfer when the holder has no shares, and it
  -- fires before the foreign key is reached, so the probe would pass
  -- whether or not 0519 exists. Both its columns are left to the
  -- coverage query, which reads the catalogue and cannot be fooled that
  -- way. This is the third time in this programme an existing guard has
  -- shadowed a probe; the pattern is now expected rather than
  -- surprising.
  insert into public.corp_entities (org_id, name, entity_type, status)
  values (v_a, 'A''s client company', 'sdn_bhd', 'incorporated')
  returning id into v_ent2_a;
  insert into public.corp_persons (org_id, kind, full_name)
  values (v_a, 'individual', 'Encik A') returning id into v_per_a;
  insert into public.corp_persons (org_id, kind, full_name)
  values (v_b, 'individual', 'Encik B') returning id into v_per_b;

  v_tried := v_tried + 1;
  begin
    insert into public.corp_officers
      (org_id, entity_id, person_id, role, appointed_on)
    values (v_a, v_ent2_a, v_per_b, 'director', current_date - 30);
    raise exception 'B''s person was appointed to A''s board';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.corp_officers
      (org_id, entity_id, person_id, role, appointed_on)
    values (v_a, v_ent2_a, v_per_a, 'director', current_date - 30);
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse A''s own person on A''s own board: %', sqlerrm;
  end;

  -- 19. A ticket share link, which is 0520, and the third thing in this
  -- programme that leaves the building -- after `document_share_links`
  -- in 0516 and the customer portal. A person with no account follows a
  -- token to see a ticket, and the token is what authorises the read,
  -- not a session. RLS is no help at all: a link in A pointing at B's
  -- ticket shows B's ticket, with everything written on it, to somebody
  -- who was never meant to see it.
  insert into public.tickets
    (org_id, ticket_no, subject, ticket_type, priority, status, channel,
     opened_at, requester_contact_id)
  values (v_b, 'TKT-B', 'B''s problem', 'incident', 'p3', 'open', 'email',
          now(), v_con_b)
  returning id into v_tkt_b;

  v_tried := v_tried + 1;
  begin
    insert into public.ticket_share_links
      (org_id, ticket_id, token_hash, expires_at)
    values (v_a, v_tkt_b, 'tkt-hash-x', now() + interval '7 days');
    raise exception 'a share link in A pointed at B''s ticket';
  exception when foreign_key_violation then
    v_refused := v_refused + 1;
  end;

  v_tried := v_tried + 1;
  begin
    insert into public.tickets
      (org_id, ticket_no, subject, ticket_type, priority, status, channel,
       opened_at, requester_contact_id)
    values (v_a, 'TKT-A', 'A''s problem', 'incident', 'p3', 'open',
            'email', now(), v_con_a);
    insert into public.ticket_share_links
      (org_id, ticket_id, token_hash, expires_at)
    select v_a, id, 'tkt-hash-own', now() + interval '7 days'
      from public.tickets where org_id = v_a and ticket_no = 'TKT-A';
    v_refused := v_refused + 1;
  exception when others then
    raise exception
      'the new keys refuse a link to A''s own ticket: %', sqlerrm;
  end;

  if v_refused <> v_tried or v_tried < 29 then
    raise exception 'employee and warehouse boundary: % probes ran, % behaved',
      v_tried, v_refused;
  end if;

  -- And the set is closed -- not for a list of parents, but for the
  -- schema.
  --
  -- Every earlier version of this query named the parents it covered,
  -- and said so deliberately: listing a parent before its migration
  -- would have made this file fail for work that had not been done,
  -- which is a worse signal than not asserting it yet. 0521 finished
  -- the work, so the list is gone. What is asserted now is the rule
  -- itself: if a table carries its own `org_id` and names a row in
  -- another table that carries one too, it has to say WHICH company's
  -- row it means.
  --
  -- That is the assertion the whole programme was for. It holds for
  -- tables nobody has written yet: a new one gets the same treatment on
  -- the day it is added, and this fails then rather than on the day
  -- somebody notices a figure on the wrong books.
  --
  -- Two columns are exempt, both named below, both on
  -- `purchase_documents`, both inter-company billing, and both found by
  -- the SQL suite rather than by reading the schema.
  select string_agg(
           c.confrelid::regclass::text || ' <- ' ||
           c.conrelid::regclass::text || '.' || a.attname, ', ')
    into v_uncovered
    from pg_constraint c
    join unnest(c.conkey) k(attnum) on true
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
   where c.contype = 'f'
     and cardinality(c.conkey) = 1
     and exists (select 1 from pg_attribute o
                  where o.attrelid = c.conrelid and o.attname = 'org_id'
                    and o.attnum > 0 and not o.attisdropped)
     -- The parent has to carry org_id too, or a same-org key is not
     -- expressible. Twenty-two parents are in that position -- the
     -- reference tables, and `organizations` itself.
     and exists (select 1 from pg_attribute o2
                  where o2.attrelid = c.confrelid and o2.attname = 'org_id'
                    and o2.attnum > 0 and not o2.attisdropped)
     and not exists (
       select 1 from pg_constraint c2
        where c2.contype = 'f' and c2.conrelid = c.conrelid
          and c2.confrelid = c.confrelid and cardinality(c2.conkey) > 1
          and k.attnum = any (c2.conkey))
     -- `source_sales_document_id` (0516) is the link from the buyer's
     -- bill to the seller's invoice: pointing at the other company's
     -- document IS the feature.
     --
     -- `payment_term_id` (0520) is subtler and cost two wrong turns.
     -- 0439 made `accept_intercompany_bill` copy the seller's due date
     -- onto the buyer's bill, because `report_ap_aging` buckets on
     -- `coalesce(due_date, doc_date)` and a null aged the bill from the
     -- day it was raised. It copied the TERM alongside the date and
     -- asserted it, in an assertion whose own title says why: "and the
     -- terms it was raised on, not only the date they produce". The
     -- first wrong turn was adding the constraint; the second was
     -- reading that failure as an implementation accident and changing
     -- the function, which failed the same file again.
     --
     -- They are named here rather than filtered out silently, so they
     -- read as decisions. That the exemption is exactly two columns
     -- wide is checked by dropping
     -- `purchase_documents_contact_same_org` and watching this fail.
     and (c.conrelid, a.attname) not in (
           ('public.purchase_documents'::regclass,
            'source_sales_document_id'),
           ('public.purchase_documents'::regclass,
            'payment_term_id'));
  if v_uncovered is not null then
    raise exception
      'these columns name a row without saying which company''s: %',
      v_uncovered;
  end if;

  -- ------------------------------------------------------------------
  -- And the class the query above cannot see
  --
  -- The filter says the table must carry `org_id`. A table with none
  -- at all is therefore skipped rather than reported -- and a join
  -- table holding two foreign keys and nothing else is exactly that
  -- shape. It names a row from one company's configuration and a row
  -- from anybody's catalogue, with nothing on the row to hold the two
  -- together.
  --
  -- Four such tables existed when 0522 was written. Three were the POS
  -- scope tables, and the consequence was not theoretical: one company
  -- could put another company's dish on a schedule that was shut and
  -- take it off the other company's own menu, because
  -- `app.pos_item_off` matched schedule rows by item alone. The fourth
  -- was `organizations`, whose own org_id is called `id`.
  --
  -- This is the query that would have found them. `organizations` is
  -- excluded from the LEFT of it, not the right: it is the one table
  -- whose tenant column is `id`, so it is covered by the query above's
  -- rule under a different name, and 0522 gave it both keys.
  select string_agg(t.relname || '.' || a.attname || ' -> ' ||
                    f.confrelid::regclass::text, ', ')
    into v_uncovered
    from pg_class t
    join pg_namespace n on n.oid = t.relnamespace
    join pg_constraint f on f.conrelid = t.oid and f.contype = 'f'
                        and cardinality(f.conkey) = 1
    join pg_attribute a on a.attrelid = t.oid and a.attnum = f.conkey[1]
   where n.nspname = 'public' and t.relkind = 'r'
     and t.relname <> 'organizations'
     and not exists (select 1 from pg_attribute o
                      where o.attrelid = t.oid and o.attname = 'org_id'
                        and o.attnum > 0 and not o.attisdropped)
     -- Only where the parent has a company, so a link to a reference
     -- table is not reported.
     and exists (select 1 from pg_attribute o2
                  where o2.attrelid = f.confrelid and o2.attname = 'org_id'
                    and o2.attnum > 0 and not o2.attisdropped)
     -- Two or more such columns is what makes it a join table: one
     -- alone cannot disagree with anything.
     and (select count(*) from pg_constraint f2
           where f2.conrelid = t.oid and f2.contype = 'f'
             and cardinality(f2.conkey) = 1
             and exists (select 1 from pg_attribute o3
                          where o3.attrelid = f2.confrelid
                            and o3.attname = 'org_id'
                            and o3.attnum > 0 and not o3.attisdropped)) >= 2;
  if v_uncovered is not null then
    raise exception
      'these tables name two companies'' rows with no company of their '
      'own to hold them together: %', v_uncovered;
  end if;

  raise notice
    'the whole schema: 18 cross-company writes refused, 18 same-company '
    'writes allowed, 0 columns uncovered anywhere, 0 join tables without '
    'a company, 2 exempt by name';
end $$;

-- Deleting a row somebody else names has to empty the reference, not
-- raise.
--
-- A composite key with `on delete set null` and no column list nulls
-- EVERY referencing column, and the first of ours is always `org_id`,
-- which is NOT NULL -- so the delete failed with 23502 instead of
-- clearing the reference. 0511 re-added the twenty affected keys naming
-- only the child column.
--
-- The ticketing probe is the one that mattered. `employees.manager_id`
-- also had the defect but its delete succeeded anyway, because the
-- plain single-column key beside it nulls the column first and the
-- composite key then matches nothing -- trigger firing order standing
-- in for a correct constraint. `ticket_categories.team_id` has no plain
-- sibling, so nothing rescued it and the delete raised. Both are probed
-- here: one for the failure that was real, one for the near miss.

do $$
declare
  v_org  uuid;
  v_team uuid;
  v_cat  uuid;
  v_boss uuid;
  v_kaki uuid;
  v_bad  text;
begin
  v_org := pg_temp.test_org('Buang Ketua Sdn Bhd', array['ticketing']);

  -- 1. The one that raised. A category names a team; deleting the team
  -- has to leave the category with no team, not refuse.
  insert into public.ticket_teams (org_id, code, name)
  values (v_org, 'SOK', 'Sokongan') returning id into v_team;
  insert into public.ticket_categories (org_id, code, name, team_id)
  values (v_org, 'AM', 'Am', v_team) returning id into v_cat;

  begin
    delete from public.ticket_teams where id = v_team;
  exception when others then
    raise exception
      'deleting a ticket team raised instead of emptying the reference: '
      '% / %', sqlstate, sqlerrm;
  end;

  if not exists (select 1 from public.ticket_categories where id = v_cat) then
    raise exception 'deleting the team took the category with it';
  end if;
  if (select team_id from public.ticket_categories where id = v_cat)
     is not null then
    raise exception 'the category kept a team that was deleted';
  end if;

  -- 2. The near miss, and the self-reference besides: a reporting line
  -- and a department head, both pointing at the same person.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status)
  values (v_org, 'BK-1', 'Ketua', current_date - 400, 'active')
  returning id into v_boss;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status, manager_id)
  values (v_org, 'BK-2', 'Kaki', current_date - 400, 'active', v_boss)
  returning id into v_kaki;
  insert into public.departments (org_id, code, name, head_employee_id)
  values (v_org, 'OPS', 'Operations', v_boss);

  begin
    delete from public.employees where id = v_boss;
  exception when others then
    raise exception
      'deleting a manager raised instead of emptying the reference: % / %',
      sqlstate, sqlerrm;
  end;

  if not exists (select 1 from public.employees where id = v_kaki) then
    raise exception 'deleting the manager took the subordinate with it';
  end if;
  if (select manager_id from public.employees where id = v_kaki)
     is not null then
    raise exception 'the reporting line survived the manager';
  end if;
  if (select head_employee_id from public.departments
       where org_id = v_org and code = 'OPS') is not null then
    raise exception 'the department kept a head who was deleted';
  end if;

  -- The two probes reach three of the twenty. This reaches all of them,
  -- and any composite key a later migration adds: a `set null` rule
  -- with no column list, or one that names a NOT NULL column, is the
  -- defect 0511 fixed, and reads the same from `pg_constraint` whether
  -- or not a test happens to delete through it. It is deliberately not
  -- restricted to `%_same_org` -- the ticketing keys are not named that
  -- way and were the ones actually failing.
  select string_agg(c.conrelid::regclass::text || '.' || c.conname, ', ')
    into v_bad
    from pg_constraint c
   where c.contype = 'f'
     and cardinality(c.conkey) > 1
     and c.confdeltype = 'n'
     and (c.confdelsetcols is null
          or exists (
            select 1 from pg_attribute a
             where a.attrelid = c.conrelid
               and a.attnum = any (c.confdelsetcols)
               and a.attnotnull));
  if v_bad is not null then
    raise exception
      'these keys null a NOT NULL column on delete instead of the '
      'reference: %', v_bad;
  end if;

  raise notice
    'deleting a named row: 2 references emptied, 0 rows lost, '
    '0 keys null a NOT NULL column';
end $$;

rollback;
