-- =====================================================================
-- iAkauntan :: one company cannot see another's rows
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/no_tenant_sees_another.sql
--
-- Every table in this schema that belongs to a company carries `org_id`
-- and an RLS policy scoping it. Thirty-odd assertion files exercise
-- that policy for the feature each of them is about. Nothing asked the
-- question in general: **for every table that has an org_id, can a
-- member of one company read another company's rows?**
--
-- It is the worst failure this product could have and the least likely
-- to be noticed, because a leak looks like data.
--
-- ---------------------------------------------------------------------
-- Why this is not a grep
--
-- Asking `pg_policy` whether each expression mentions `org_id` finds
-- nine policies that do not, and all nine are fine: `false` on
-- `approval_requests` and `approval_steps`, which are reached only
-- through SECURITY DEFINER functions; `user_id = auth.uid()` on
-- `chat_participants`, which is narrower; `app.is_chat_participant(...)`,
-- which scopes through a helper; and `app.is_platform_admin()` on the
-- three `org_*` tables, where seeing across companies is the point.
--
-- So the text of a policy answers nothing. This file reads rows instead,
-- as `authenticated`, with the JWT of somebody who is a member of one
-- company and not the other.
--
-- ---------------------------------------------------------------------
-- And why it cannot be allowed to go vacuous
--
-- "No rows of the other company are visible" is also true of a table
-- with no rows in it, and a sweep over 250 empty tables would pass
-- forever while proving nothing. `0395` shipped an assertion with that
-- fault -- "nobody is away", asserted by a caller who could see nothing
-- -- and it survived its own mutant.
--
-- So the tables are counted twice. As the owner, to find which ones the
-- other company actually has rows in; then as the member, to see how
-- many of those are visible. Only the tables in the first set are
-- asserted, the size of that set is reported, and a floor under it
-- fails the file if the fixture ever stops populating.
--
-- ---------------------------------------------------------------------
-- What mutation testing said about it
--
-- Made `audit_logs`' select policy `using (true)` and this file fails
-- with "audit_logs (232 of 232)" -- another company's entire history of
-- who changed what, which is the single worst row a leak could return.
--
-- Made `contacts`' select policy `using (true)` and **nothing
-- happened**, which is worth writing down because it is not a weakness
-- of this file. `contacts` carries two policies: `contacts_select` is
-- permissive, and `module_gate_select` is *restrictive* and scopes by
-- `app.can_read_module(org_id, 'contacts')`. Restrictive policies AND,
-- so widening the permissive one alone cannot open the table.
--
-- That is the difference this sweep exists to see. A module-gated table
-- is scoped twice; `audit_logs` is scoped once, and one is all it takes
-- for a single wrong policy to hand a competitor the lot.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_two (mine uuid, theirs uuid, me uuid);
grant select on t_two to authenticated;

create temporary table t_theirs (tbl text primary key, n bigint);
grant select on t_theirs to authenticated;

-- ---------------------------------------------------------------------
-- Two companies, and one of them does a day's business
-- ---------------------------------------------------------------------
do $$
declare
  v_mine uuid; v_theirs uuid;
  v_owner uuid := pg_temp.test_user();
  v_me uuid;
  v_cust uuid; v_item uuid; v_doc uuid; v_line uuid;
  v_emp uuid; v_period uuid; v_cat uuid; v_asset uuid; v_revenue uuid;
begin
  -- Theirs first, and everything below is put in it. The company under
  -- test owns nothing at all, which is deliberate: a policy that leaked
  -- by returning *everything* and one that leaked by ignoring `org_id`
  -- look the same from a company that has its own rows to see.
  v_theirs := pg_temp.test_org('Syarikat Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  perform public.create_fiscal_year(v_theirs, date_trunc('year', current_date)::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_theirs, 'C-1', 'Pelanggan Jiran', 'customer') returning id into v_cust;
  insert into public.items (org_id, code, name, item_type)
  values (v_theirs, 'I-1', 'Barang Jiran', 'stock') returning id into v_item;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_theirs, 'invoice', 'INV-J1', current_date, v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_theirs, v_doc, 1, 'Barang', 3, 250) returning id into v_line;
  perform public.post_sales_document(v_doc);

  select a.id into v_cat from public.accounts a
   where a.org_id = v_theirs and not a.is_group and a.is_active
     and a.account_type = 'expense' order by a.code limit 1;
  insert into public.expenses
    (org_id, expense_no, expense_date, description, amount, tax_amount,
     total_amount, currency, exchange_rate, account_id)
  values (v_theirs, 'EXP-J1', current_date, 'Elektrik', 320, 0, 320,
          'MYR', 1, v_cat);

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_theirs, 'E1', 'Puan Siti', date '2021-03-01', 4200,
          date '1992-07-04', 'citizen') returning id into v_emp;
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_theirs, '2026-08', date '2026-08-01', date '2026-08-31',
          date '2026-08-31') returning id into v_period;

  -- And the company doing the looking. A member of this one and of
  -- nothing else.
  v_me := pg_temp.another_user('jiran@example.test');
  insert into public.organizations (name, slug, entity_type, base_currency,
                                    created_by)
  values ('Syarikat Saya Sdn Bhd',
          'syarikat-saya-' || gen_random_uuid(), 'sdn_bhd', 'MYR', v_owner)
  returning id into v_mine;
  perform app.seed_chart_of_accounts(v_mine);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_mine, pm.code, true from public.platform_modules pm
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.org_members (org_id, user_id, role, status)
  values (v_mine, v_me, 'owner', 'active');

  insert into t_two values (v_mine, v_theirs, v_me);
end $$;

-- Which tables the other company actually has rows in. Read as the
-- owner, so RLS is not what is being measured here -- this is the list
-- of questions worth asking, not an answer to any of them.
do $$
declare r record; v_n bigint;
begin
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid
     where n.nspname = 'public' and c.relkind = 'r'
       and a.attname = 'org_id' and a.attnum > 0 and not a.attisdropped
     order by 1
  loop
    execute format(
      'select count(*) from public.%I where org_id = $1', r.relname)
      into v_n using (select theirs from t_two);
    if v_n > 0 then
      insert into t_theirs values (r.relname, v_n);
    end if;
  end loop;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select me from t_two),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  c record; r record; v_n bigint;
  v_leaks text := null; v_asked int := 0;
begin
  select * into c from t_two;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('this member is in one company',
    exists (select 1 from public.org_members m
             where m.user_id = c.me and m.org_id = c.mine
               and m.status = 'active'));
  perform pg_temp.check_true('and is not in the other',
    not exists (select 1 from public.org_members m
                 where m.user_id = c.me and m.org_id = c.theirs));
  perform pg_temp.check_true('and is not a platform administrator',
    not app.is_platform_admin());

  for r in select tbl, n from t_theirs order by tbl loop
    v_asked := v_asked + 1;
    execute format(
      'select count(*) from public.%I where org_id = $1', r.tbl)
      into v_n using c.theirs;
    if v_n > 0 then
      v_leaks := coalesce(v_leaks || ', ', '')
              || r.tbl || ' (' || v_n || ' of ' || r.n || ')';
    end if;
  end loop;

  if v_leaks is not null then
    raise exception
      'FAIL: a member of one company can read another company''s rows in %',
      v_leaks;
  end if;

  -- The floor. Without it this file passes by asking nothing, which is
  -- exactly how it would fail if the fixture above ever stopped
  -- populating -- and it would go on passing for years.
  if v_asked < 12 then
    raise exception
      'FAIL: only % tables had any of the other company''s rows to hide, '
      'which is too few for this file to mean anything. The fixture has '
      'stopped populating.', v_asked;
  end if;

  raise notice
    'ok   none of the other company''s rows are visible, across % tables '
    'that have some', v_asked;
end $$;

-- ---------------------------------------------------------------------
-- The positive control
-- ---------------------------------------------------------------------
-- Every count above would also be zero if this member could see nothing
-- at all -- a broken JWT, a policy that denies everyone, a role change
-- that silently failed. So: their own company is visible, and the
-- tables the sweep asked about are ones they can genuinely read in
-- their own.
do $$
declare c record; v_n bigint;
begin
  select * into c from t_two;
  perform pg_temp.check_true('this member can see their own company',
    exists (select 1 from public.organizations o where o.id = c.mine));
  select count(*) into v_n from public.accounts where org_id = c.mine;
  perform pg_temp.check_true('and their own chart of accounts', v_n > 0);
  perform pg_temp.check_eq('and none of the other company''s accounts',
    (select count(*) from public.accounts where org_id = c.theirs), 0);
  perform pg_temp.check_eq('nor the other company itself',
    (select count(*) from public.organizations where id = c.theirs), 0);
end $$;

reset role;

rollback;
