-- =====================================================================
-- iAkauntan :: branches, and groups of companies
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/branches_and_groups.sql
--
-- Two shops sharing an SSM number are one company with two branches, and
-- keep one ledger. Two shops with their own registrations are two
-- companies, each filing its own return, and what they share is an owner
-- — a group. The distinction is not a modelling preference: it is what
-- SSM and LHDN think, and the books have to agree with them.
--
-- What is asserted here is the seam between the two. A branch belongs to
-- exactly one company and cannot be borrowed by another; a group lets a
-- person see the companies in it that they are *already* a member of and
-- not one company more.
--
-- Everything that touches a policy runs as `authenticated`: the
-- connection is a superuser and a superuser bypasses row level security.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.supplier(p_org uuid, p_code text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, p_code, 'Pembekal', 'supplier') returning id into v_id;
  return v_id;
end; $$;

-- ---------------------------------------------------------------------
-- A branch belongs to one company
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid := pg_temp.test_org('Cawangan A Sdn Bhd');
  v_b uuid := pg_temp.test_org('Cawangan B Sdn Bhd');
  v_branch uuid;
begin
  insert into public.branches (org_id, code, name)
  values (v_a, 'KL', 'Kuala Lumpur') returning id into v_branch;

  -- No handler. This asserts the insert SUCCEEDS, and a handler that
  -- turned any error into `v_ok := false` reported a failing insert as
  -- the branch rule working -- including a column renamed out from
  -- under it. Unhandled, the real error stops the file and names
  -- itself.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount,
     branch_id)
  values (v_a, 'bill', 'B-OWN', pg_temp.supplier(v_a, 'S-1'), current_date,
          'draft', 0, v_branch);
  raise notice 'ok   a document may name its own company''s branch';

  -- The one that matters. Without the guard this succeeds, the document
  -- is invisible on every branch screen, and every report by branch is
  -- quietly wrong.
  -- And the refusal, on its words. `23514` is a check constraint and
  -- this file could raise one for half a dozen reasons.
  perform pg_temp.check_refused('and not another company''s',
    format($q$ insert into public.purchase_documents
                 (org_id, doc_type, doc_no, contact_id, doc_date, status,
                  total_amount, branch_id)
               values (%L, 'bill', 'B-BORROWED', %L, current_date,
                       'draft', 0, %L) $q$,
           v_b, pg_temp.supplier(v_b, 'S-1'), v_branch),
    '%branch belongs to another company%', '23514');

  -- The control: a document with no branch is the ordinary case and has
  -- to stay ordinary, or this migration would have broken every company
  -- that never opens a second shop.
  -- Success again, so again no handler: a branch is optional, and this
  -- says so by the insert simply working.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status, total_amount)
  values (v_b, 'bill', 'B-NONE', pg_temp.supplier(v_b, 'S-2'), current_date,
          'draft', 0);
  raise notice 'ok   a document with no branch is still fine';
end $$;

-- ---------------------------------------------------------------------
-- A group shows the companies you are already in, and no more
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_a uuid := pg_temp.test_org('Kumpulan Satu Sdn Bhd');
  v_b uuid := pg_temp.test_org('Kumpulan Dua Sdn Bhd');
  v_c uuid := pg_temp.test_org('Kumpulan Tiga Sdn Bhd');
  v_outsider uuid := pg_temp.another_user('outsider@kumpulan.test');
  v_group uuid;
  v_seen int;
begin
  insert into public.company_groups (name, created_by)
  values ('Kumpulan Ujian', v_owner) returning id into v_group;

  perform pg_temp.sign_in_as(v_owner);
  perform public.join_company_group(v_a, v_group);
  perform public.join_company_group(v_b, v_group);

  select count(*) into v_seen from public.my_group_companies(v_a);
  perform pg_temp.check_eq('the group shows both companies', v_seen, 2);

  -- A company outside the group is not in it, however many the owner has.
  select count(*) into v_seen from public.my_group_companies(v_c);
  perform pg_temp.check_eq('and a company in no group shows none', v_seen, 0);

  -- Somebody who belongs to none of it sees none of it.
  perform pg_temp.sign_in_as(v_outsider);
  select count(*) into v_seen from public.my_group_companies(v_a);
  perform pg_temp.check_eq('a stranger sees nothing of the group', v_seen, 0);

  -- And cannot attach a company to it, nor to one they do not administer.
  perform pg_temp.check_refused(
    'a stranger cannot move a company into a group',
    format($q$ select public.join_company_group(%L, %L) $q$, v_c, v_group),
    '%Only an administrator can move a company%', '42501');
end $$;

-- ---------------------------------------------------------------------
-- The group is a name, not a key to the books
--
-- Worth pinning down, because "these companies are related" is exactly
-- the kind of statement that quietly turns into "so you may read them
-- both". Every other policy still asks `is_org_member` of the company
-- whose rows are being read, and grouping changes none of them.
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid := (select id from public.organizations
                where name = 'Kumpulan Satu Sdn Bhd');
  v_b uuid := (select id from public.organizations
                where name = 'Kumpulan Dua Sdn Bhd');
  v_stranger uuid := pg_temp.another_user('only-in-one@kumpulan.test');
  v_sees int;
  v_role text;
begin
  -- A member of one company in the group, and nothing else.
  insert into public.org_members (org_id, user_id, role)
  values (v_a, v_stranger, 'accountant');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_b, 'C-SECRET', 'Pelanggan B', 'customer');

  perform pg_temp.sign_in_as(v_stranger);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_sees from public.contacts where org_id = v_b;
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq(
    'being in the group is not being in the other company''s books',
    v_sees, 0);
end $$;

rollback;
