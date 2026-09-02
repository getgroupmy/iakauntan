-- =====================================================================
-- iAkauntan :: attachments are a module, and reading them is not
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/attachments_module.sql
--
-- `0323` makes attaching a document something a company buys. The whole
-- gate is one line inside `app.can_attach_to`, which every writer
-- already asks — the attachment row, the file in storage, and deleting
-- either. What is asserted here is that the line is load-bearing in
-- both directions:
--
--   * without the module nobody can add a document, however senior;
--   * with it, everybody who could before still can, including the
--     claimant who is not staff;
--   * and either way, a document already filed stays readable.
--
-- That last one is the one worth being careful about. A module that
-- withdrew access to a receipt attached to a claim two years ago would
-- be taking away somebody's records rather than selling them a feature,
-- and the auditor asking for it has no module.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The module exists and is sold, rather than being a code nobody offers
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('the module is in the catalogue',
    (select count(*)::int from public.platform_modules
      where code = 'attachments' and is_active), 1);

  -- Not core. A core module is one every company has by definition, and
  -- registering this one as core would make the whole migration a
  -- rename.
  perform pg_temp.check_true('and is an add-on rather than core',
    not (select is_core from public.platform_modules
          where code = 'attachments'));
end $$;

-- ---------------------------------------------------------------------
-- Without it, nobody writes
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_owner uuid := pg_temp.test_user();
  v_contact uuid;
  v_ok boolean;
begin
  -- Every module except this one, so the refusal below is about the
  -- module and not about a company with nothing switched on.
  v_org := pg_temp.test_org('Tanpa Lampiran');
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'attachments';

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_contact;

  perform pg_temp.check_true('the owner may write to the books',
    app.can_write(v_org));
  perform pg_temp.check_true('and still may not file a document',
    not app.can_attach_to(v_org, 'contacts', v_contact));

end $$;

-- ---------------------------------------------------------------------
-- And every door actually asks it
--
-- `pg_temp.sign_in_as` sets the JWT claim; it does not become the
-- `authenticated` role, so the policies do not run for the superuser
-- these files execute as. Asserting a refused insert here would assert
-- nothing — it would pass whether or not the policy asked anything.
--
-- So the guard is checked by calling it, above, and the doors are
-- checked by reading them: which policies exist on the attachment row
-- and on the file behind it, and that each one asks either
-- `can_attach_to` — which now carries the module — or the module
-- itself. A policy that stopped asking would be a way in past the gate,
-- and nothing at runtime would say so.
-- ---------------------------------------------------------------------
do $$
declare v_def text; v_name text;
begin
  -- Adding and removing an attachment row, and the file in storage.
  foreach v_name in array array['attachments_insert', 'attachments_delete']
  loop
    select coalesce(pg_get_expr(polqual, polrelid),
                    pg_get_expr(polwithcheck, polrelid))
      into v_def
      from pg_policy
     where polrelid = 'public.attachments'::regclass and polname = v_name;
    perform pg_temp.check_true(format('%s asks the guard', v_name),
      v_def like '%can_attach_to%');
  end loop;

  foreach v_name in array array['attachments_write', 'attachments_delete']
  loop
    select coalesce(pg_get_expr(polqual, polrelid),
                    pg_get_expr(polwithcheck, polrelid))
      into v_def
      from pg_policy
     where polrelid = 'storage.objects'::regclass and polname = v_name;
    perform pg_temp.check_true(format('storage %s asks the guard', v_name),
      v_def like '%can_attach_to%');
  end loop;

  -- Renaming a row and moving a file go through `app.can_write`, the
  -- ordinary bookkeeping permission, which must not learn what an
  -- attachment is — so these two carry the module check themselves.
  select pg_get_expr(polqual, polrelid) into v_def
    from pg_policy
   where polrelid = 'public.attachments'::regclass
     and polname = 'attachments_update';
  perform pg_temp.check_true('renaming a row asks the module',
    v_def like '%attachments%' and v_def like '%has_module%');

  select pg_get_expr(polqual, polrelid) into v_def
    from pg_policy
   where polrelid = 'storage.objects'::regclass
     and polname = 'attachments_move';
  perform pg_temp.check_true('moving a file asks the module',
    v_def like '%has_module%');

  -- And reading does not, in either place. This is the assertion that
  -- keeps somebody's records theirs.
  select pg_get_expr(polqual, polrelid) into v_def
    from pg_policy
   where polrelid = 'public.attachments'::regclass
     and polname = 'attachments_select';
  perform pg_temp.check_true('reading a row does not ask the module',
    v_def not like '%has_module%');

  select pg_get_expr(polqual, polrelid) into v_def
    from pg_policy
   where polrelid = 'storage.objects'::regclass
     and polname = 'attachments_read';
  perform pg_temp.check_true('nor reading the file',
    v_def not like '%has_module%');
end $$;

-- ---------------------------------------------------------------------
-- With it, everything that worked before still works
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_owner uuid := pg_temp.test_user();
  v_contact uuid;
  v_att uuid;
begin
  v_org := pg_temp.test_org('Dengan Lampiran');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_contact;

  perform pg_temp.check_true('the owner may file a document',
    app.can_attach_to(v_org, 'contacts', v_contact));

  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'contacts', v_contact, 'invois.pdf',
          v_org || '/contacts/' || v_contact || '/invois.pdf')
  returning id into v_att;
  perform pg_temp.check_true('and the row goes in', v_att is not null);

  -- And it comes back off again, which is the delete policy asking the
  -- same guard.
  delete from public.attachments where id = v_att;
  perform pg_temp.check_eq('and can be taken away again',
    (select count(*)::int from public.attachments where id = v_att), 0);
end $$;

-- ---------------------------------------------------------------------
-- Switching it off does not take away what is already filed
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_owner uuid := pg_temp.test_user();
  v_contact uuid;
  v_att uuid;
  v_ok boolean;
begin
  v_org := pg_temp.test_org('Berhenti Melanggan');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_contact;
  insert into public.attachments
    (org_id, entity_table, entity_id, file_name, storage_path)
  values (v_org, 'contacts', v_contact, 'resit.pdf',
          v_org || '/contacts/' || v_contact || '/resit.pdf')
  returning id into v_att;

  -- The company stops paying for it.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'attachments';

  perform pg_temp.check_eq('the document filed before is still readable',
    (select count(*)::int from public.attachments where id = v_att), 1);
  perform pg_temp.check_true('and reading is not asked the module at all',
    app.can_read_attachment(v_org, 'contacts', v_contact));

  -- But nothing more goes in, and what is there cannot be renamed or
  -- removed — the delete and update policies both ask the module now.
  perform pg_temp.check_true('while nothing more may be filed',
    not app.can_attach_to(v_org, 'contacts', v_contact));

end $$;

-- ---------------------------------------------------------------------
-- The claimant who is not staff is gated by the module too
--
-- `app.can_attach_to` exists because the person holding the receipt for
-- an expense claim is the claimant, and a claimant is not staff. That
-- path has to close with the module like every other, or the guard has
-- a hole shaped like the case it was written for.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_owner uuid := pg_temp.test_user();
  v_staff uuid := pg_temp.another_user('claimant@iakauntan.test');
  v_employee uuid;
  v_claim uuid;
begin
  v_org := pg_temp.test_org('Tuntutan Berlampiran');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id)
  values (v_org, 'E1', 'Puan Siti', date '2020-01-01', 8000,
          date '1985-01-01', 'citizen', v_staff)
  returning id into v_employee;
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, title, total_amount, status)
  values (v_org, 'C1', v_employee, current_date, 'Teksi', 42, 'draft')
  returning id into v_claim;

  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_true('the claimant may file their own receipt',
    app.can_attach_to(v_org, 'expense_claims', v_claim));

  perform pg_temp.sign_in_as(v_owner);
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'attachments';

  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_true('and not once the module is off',
    not app.can_attach_to(v_org, 'expense_claims', v_claim));
  perform pg_temp.sign_in_as(v_owner);
end $$;

-- ---------------------------------------------------------------------
-- No customer was granted it, and every demo tenant was
--
-- Asked for explicitly: every company, old and new, has to have it
-- switched on. Asserted because the alternative — a backfill somebody
-- adds later out of sympathy for the support queue — would make the
-- module invisible to exactly the customers it is meant to be sold to,
-- and would do it silently.
--
-- The demo tenants are the exception, and `0324` is the migration that
-- makes it. They are not customers: they exist so a visitor can see
-- what the product does, and a demonstration with the paperwork missing
-- from every bill misrepresents what is for sale. `demo_rebuild.sql`
-- asserts the whole of that rule — no active module without a demo
-- tenant to show it in — and caught `0323` leaving this one out.
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  perform pg_temp.check_eq('no customer is given it by the migration',
    (select count(*)::int
       from public.org_modules om
       join public.organizations o on o.id = om.org_id
      where om.module_code = 'attachments' and om.is_enabled
        and not o.is_demo
        and o.name not like '%Lampiran%'
        and o.name not like '%Melanggan%'
        and o.name not like '%Tuntutan%'), 0);

  -- And a demo rebuild keeps giving it to the demo tenants. Structural
  -- because the tenants themselves are made at runtime by
  -- `app.demo_rebuild`, which this file does not run — the behaviour is
  -- asserted where the tenants exist, in `demo_rebuild.sql`. What is
  -- checked here is the coupling that file depends on: unlike every
  -- other module it lists, this one is not detected from rows, because
  -- attachments hang off records rather than having a subject of their
  -- own.
  select prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_modules_in_use';
  perform pg_temp.check_true('a rebuilt demo tenant still shows it',
    v_src like '%attachments%');
  perform pg_temp.check_true('and gets it for being a demo, not for data',
    v_src ~ 'select id, ''attachments'' from public.organizations');
end $$;

-- ---------------------------------------------------------------------
-- A company's own paperwork, filed against its own invoice
--
-- Attachments were offered on purchase documents only, on the reasoning
-- that a bill is evidence somebody else produced where an invoice is
-- evidence this company produced and already holds. True of an invoice
-- raised here; false of the case people actually have — a company
-- moving onto this system types last year's invoices in, and the PDF it
-- issued at the time is the only record of what it looked like.
--
-- The permission was always there. These assert it, so a later
-- narrowing of `can_attach_to` cannot quietly take the screen's
-- capability away again.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_doc  uuid;
  v_cust uuid;
  v_emp  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kertas Jualan Sdn Bhd');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Pelanggan', 'customer') returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-OLD-1', app.today(), v_cust, 'MYR', 1,
          'posted')
  returning id into v_doc;

  perform pg_temp.check_true(
    'a sales invoice can carry the paper it was issued on',
    app.can_attach_to(v_org, 'sales_documents', v_doc));
  perform pg_temp.check_true('and whoever keeps the books can read it',
    app.can_read_attachment(v_org, 'sales_documents', v_doc));

  -- The same rule as everything else on a sales document: somebody with
  -- no write permission does not get to file paper against the
  -- company's own invoices.
  v_emp := pg_temp.another_user('emp-invoice@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_emp, 'employee', 'active', now());
  perform pg_temp.sign_in_as(v_emp);
  perform pg_temp.check_true('but an employee does not',
    not app.can_attach_to(v_org, 'sales_documents', v_doc));
end $$;

rollback;
