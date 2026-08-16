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

rollback;
