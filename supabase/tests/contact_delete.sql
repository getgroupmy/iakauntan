-- =====================================================================
-- iAkauntan :: deleting a contact nothing points at
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_delete.sql
--
-- `0654`. Asked for as "delete the contact only if there is no
-- transaction data related to it", and the interesting half is not the
-- delete. It is the nineteen foreign keys on `contacts.id` declared
-- ON DELETE SET NULL -- `gl_lines.contact_id` among them.
--
-- Those do not refuse. A plain `delete from contacts` against a
-- customer whose only history is in the ledger SUCCEEDS, silently
-- detaching every posted line from the party it was posted against,
-- and the books still balance afterwards. So the assertion with teeth
-- is the one against a set-null table: it is the case where "it was not
-- deleted" is a fact about this function rather than about Postgres.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cd_contact(
  p_org uuid, p_code text, p_name text,
  p_type app.contact_type default 'customer')
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, p_name, p_type)
  returning id into v_id;
  return v_id;
end $$;

-- Whether the contact is still there, as a word rather than a boolean,
-- so a failure says which one it was.
create or replace function pg_temp.cd_alive(p_id uuid)
returns text language sql stable as $$
  select case when exists (select 1 from public.contacts where id = p_id)
           then 'there' else 'gone' end;
$$;


-- ---------------------------------------------------------------------
-- A contact nothing points at
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_id uuid;
  v_out jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Buang Kenalan Sdn Bhd');
  v_id := pg_temp.cd_contact(v_org, 'C-2026-00001', 'Nobody Owes Us');

  perform pg_temp.check_eq('nothing points at a contact just created',
    app.contact_blockers(v_id)::text, '{}');

  v_out := public.delete_contact(v_id);
  perform pg_temp.check_eq('so it deletes', v_out ->> 'deleted', 'true');
  perform pg_temp.check_eq('and says which one it was',
    v_out ->> 'name', 'Nobody Owes Us');
  perform pg_temp.check_eq('and it is gone', pg_temp.cd_alive(v_id), 'gone');

  -- Twice, which is two tabs rather than an attack. Absent is said as
  -- absent: "you may not" would send somebody hunting for a permission
  -- they already have.
  perform pg_temp.check_refused('deleting it again says it has gone',
    format('select public.delete_contact(%L)', v_id),
    '%already been deleted%', 'P0002');
end $$;


-- ---------------------------------------------------------------------
-- A contact a document points at -- the case Postgres refuses anyway
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_id uuid;
  v_doc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Ada Invois Sdn Bhd');
  v_id := pg_temp.cd_contact(v_org, 'C-2026-00001', 'Kedai Besi Maju');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-1', app.today(), v_id, 'MYR', 1,
          100, 100, 100, 'draft')
  returning id into v_doc;

  perform pg_temp.check_eq('the invoice is counted',
    app.contact_blockers(v_id) ->> 'sales_documents', '1');

  -- Named, and counted, which is the difference between a refusal
  -- somebody can act on and one they can only be annoyed by.
  perform pg_temp.check_refused('and the delete is refused by name',
    format('select public.delete_contact(%L)', v_id),
    '%Kedai Besi Maju cannot be deleted while it still has '
    '1 sales document%', '23503');
  perform pg_temp.check_eq('and the contact is still there',
    pg_temp.cd_alive(v_id), 'there');

  -- Plural, because "1 sales documents" is the kind of thing that gets
  -- read as a fault in the product.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-2', app.today(), v_id, 'MYR', 1,
          50, 50, 50, 'draft');
  perform pg_temp.check_refused('two of them are counted and named as two',
    format('select public.delete_contact(%L)', v_id),
    '%2 sales documents%', '23503');

  -- And once the documents are gone it deletes, so this is a refusal
  -- about the data rather than a contact that can never be removed.
  delete from public.sales_documents where org_id = v_org;
  perform pg_temp.check_eq('with the invoices gone it deletes',
    public.delete_contact(v_id) ->> 'deleted', 'true');
end $$;


-- ---------------------------------------------------------------------
-- A contact only the LEDGER points at -- the case that used to succeed
-- ---------------------------------------------------------------------
--
-- `gl_lines.contact_id` is ON DELETE SET NULL. Without
-- `delete_contact`, this delete goes through without a word and every
-- posted line quietly loses the party it was posted against. Nothing
-- fails afterwards: the ledger still balances, the trial balance is
-- unchanged, and the only symptom is an aged receivable that no longer
-- has a customer on it.
do $$
declare
  v_org uuid;
  v_id uuid;
  v_entry uuid;
  v_debit uuid;
  v_credit uuid;
  v_before int;
  v_after int;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Lejar Sahaja Sdn Bhd');
  v_id := pg_temp.cd_contact(v_org, 'C-2026-00001', 'Syarikat Lama');

  select id into v_debit from public.accounts
   where org_id = v_org and not is_group order by code limit 1;
  select id into v_credit from public.accounts
   where org_id = v_org and not is_group and id <> v_debit
   order by code desc limit 1;

  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, status, description)
  values (v_org, 'JV-1', app.today(), 'manual', 'posted', 'An old balance')
  returning id into v_entry;
  insert into public.gl_lines
    (org_id, entry_id, account_id, contact_id, debit, credit, line_no)
  values (v_org, v_entry, v_debit, v_id, 100, 0, 1),
         (v_org, v_entry, v_credit, null, 0, 100, 2);

  perform pg_temp.check_eq('the ledger line is counted',
    app.contact_blockers(v_id) ->> 'gl_lines', '1');
  perform pg_temp.check_refused(
    'and a contact with only ledger history is refused',
    format('select public.delete_contact(%L)', v_id),
    '%1 ledger line%', '23503');

  -- The control, and the reason this block exists rather than a
  -- comment. A plain delete is what the app would have issued, and it
  -- is NOT refused -- it succeeds and takes the contact off the line.
  select count(*) into v_before
    from public.gl_lines where contact_id = v_id;
  delete from public.contacts where id = v_id;
  select count(*) into v_after
    from public.gl_lines where contact_id = v_id;

  perform pg_temp.check_eq('a plain delete had a line to detach',
    v_before::text, '1');
  perform pg_temp.check_eq(
    'and Postgres let it through, detaching the line in silence',
    v_after::text, '0');
  perform pg_temp.check_eq('which is why the delete is a function',
    pg_temp.cd_alive(v_id), 'gone');
end $$;


-- ---------------------------------------------------------------------
-- The contact's own belongings go with it
-- ---------------------------------------------------------------------
--
-- Seven keys are declared ON DELETE CASCADE, and those are read as the
-- contact's own -- its addresses, its people. They must not be counted
-- as blockers, or a contact could never be deleted once somebody typed
-- an address on it, which is every contact.
do $$
declare
  v_org uuid;
  v_id uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Alamat Sendiri Sdn Bhd');
  v_id := pg_temp.cd_contact(v_org, 'C-2026-00001', 'Ada Alamat');

  insert into public.contact_addresses
    (org_id, contact_id, label, address_line1, city, state_code, postcode)
  values (v_org, v_id, 'Office', '1 Jalan Satu', 'Ipoh', '08', '30000');
  insert into public.contact_persons (org_id, contact_id, name)
  values (v_org, v_id, 'Puan Aminah');

  perform pg_temp.check_eq('an address is not transaction data',
    app.contact_blockers(v_id)::text, '{}');
  perform pg_temp.check_eq('and the contact deletes',
    public.delete_contact(v_id) ->> 'deleted', 'true');
  perform pg_temp.check_eq('taking its addresses with it',
    (select count(*)::text from public.contact_addresses
      where contact_id = v_id), '0');
  perform pg_temp.check_eq('and its people',
    (select count(*)::text from public.contact_persons
      where contact_id = v_id), '0');
end $$;


-- ---------------------------------------------------------------------
-- Who may do it
-- ---------------------------------------------------------------------
--
-- The function is SECURITY DEFINER, so the table's own policies do not
-- apply to the delete inside it. Both guards have to be asked in the
-- body, and a version that forgot either would be a way round RLS
-- callable by every signed-in user on the deployment.
do $$
declare
  v_org uuid;
  v_id uuid;
  v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kebenaran Sdn Bhd');
  v_id := pg_temp.cd_contact(v_org, 'C-2026-00001', 'Someone Else''s');

  v_other := pg_temp.another_user('orang@example.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'a stranger to the company may not delete its contacts',
    format('select public.delete_contact(%L)', v_id),
    '%permission%', '42501');

  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('and it is still there afterwards',
    pg_temp.cd_alive(v_id), 'there');

  -- The module gate is the second `if` in the function, and it CANNOT
  -- be exercised from here: `contacts` is a core module, so
  -- `app.module_access` waves it through whatever `org_modules` says,
  -- and switching the row off changes nothing. Asserted rather than
  -- pretended -- a test that turned the row off and watched the delete
  -- succeed would read as the guard being missing.
  perform pg_temp.check_true('contacts is a core module, so the module '
    'gate cannot refuse it here',
    (select is_core from public.platform_modules where code = 'contacts'));
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'contacts';
  perform pg_temp.check_eq(
    'and switching the row off does not change that',
    public.delete_contact(v_id) ->> 'deleted', 'true');
end $$;


-- ---------------------------------------------------------------------
-- The catalogue read, which is where this is easiest to get wrong
-- ---------------------------------------------------------------------
--
-- `app.contact_blockers` finds its tables in `pg_constraint` rather
-- than from a list. The failure it is written against is `conkey[1]`:
-- `0511` gives most of these tables a two-column key referencing
-- `(org_id, id)`, so the naive read counts rows BY ORGANIZATION and
-- answers "nothing points at this contact" for every contact in a
-- company that has any documents at all.
do $$
declare
  v_org uuid;
  v_keep uuid;
  v_go uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kunci Berganding Sdn Bhd');
  v_keep := pg_temp.cd_contact(v_org, 'C-2026-00001', 'Has A Bill');
  v_go := pg_temp.cd_contact(v_org, 'C-2026-00002', 'Has Nothing');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-1', app.today(), v_keep, 'MYR', 1,
          10, 10, 10, 'draft');

  -- The assertion `conkey[1]` fails. Both contacts are in a company
  -- that has an invoice; only one of them is on it.
  perform pg_temp.check_eq('the one with the invoice is blocked',
    app.contact_blockers(v_keep) ->> 'sales_documents', '1');
  perform pg_temp.check_eq(
    'and the one beside it, in the same company, is not',
    app.contact_blockers(v_go)::text, '{}');
  perform pg_temp.check_eq('so it deletes',
    public.delete_contact(v_go) ->> 'deleted', 'true');
  perform pg_temp.check_eq('and the other one is untouched',
    pg_temp.cd_alive(v_keep), 'there');
end $$;

rollback;
