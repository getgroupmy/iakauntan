-- =====================================================================
-- Two defaults is the same as none
-- =====================================================================
--
-- `0742` then closed what 0741's header said it was leaving open: a
-- CHECK on `warehouses` and `pipelines` that a row cannot be default
-- while inactive, so that `where is_default` and
-- `where is_default and is_active` select the same rows and the thirteen
-- readers that omit `is_active` become correct without any of them being
-- rewritten. Asserted at the bottom of this file.
--
-- `0741` gave eight tables the partial unique index that `0092` gave
-- `contact_addresses` and `contact_persons`: bank_accounts, branches,
-- payment_terms, pipelines, price_levels, tax_codes, warehouses and
-- work_shifts. The index is on `(org_id) where is_default and is_active`.
--
-- `pos_modifiers` is not among them, and the reason is an assertion that
-- already existed: `pos_fnb.sql` requires that "a group that takes two
-- takes two defaults, and not a third", because the limit there is the
-- group's `max_select` -- a rule in another table, which a partial
-- unique index cannot express. It is asserted there, not here.
--
-- Until it did, seventeen functions picked "the default" with
--
--   where org_id = ... and is_default [and is_active]
--   order by created_at limit 1
--
-- and `created_at` defaults to `now()`, which is the TRANSACTION
-- timestamp -- so two rows written together carry the same value and the
-- limit picks by physical row order. One org, two active warehouses
-- inserted in one transaction: the first call returned W1, and merely
-- rewriting W1's name made the next call return W2. Nothing about the
-- ORDER BY changed. Among the things that decides are where a group
-- payment's money lands and which warehouse a POS sale depletes.
--
-- Three kinds of assertion here, because an index can be wrong in three
-- directions and only the first is obvious:
--
--   * too weak or absent -- a second default is accepted. Asserted by
--     attempting the second insert and requiring 23505.
--   * too tight -- scoped to the table rather than the company, so the
--     second company in the database cannot have a default at all.
--     Asserted by giving two orgs a default each.
--   * right shape, wrong predicate -- `where is_default` without
--     `and is_active`, which forbids a CLOSED account from holding a
--     stale default beside an open one. That state is not a mess to be
--     forbidden: `money_names_the_account.sql` builds it on purpose,
--     because what it tests is that the readers skip it. Asserted here
--     too, so the predicate cannot quietly tighten again.
--
-- And then the thing the index exists for: with the default NOT the
-- oldest row, `app.default_warehouse` returns the default. That
-- assertion is the one that distinguishes "is_default decided" from
-- "created_at decided", which a fixture whose default is also its oldest
-- row cannot do -- the twelfth way in docs/widget-tests.md.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/one_default_per_company.sql
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on
begin;
\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A second default is refused, on every one of the nine
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_bank1 uuid;
  v_bank2 uuid;
  t       text;
  v_cols  text;
  v_vals  text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Satu Sahaja Sdn Bhd', array['inventory', 'pos',
    'accounting', 'crm', 'hr']);

  -- Two bank accounts, neither default to begin with: `p_default =>
  -- false` because the helper otherwise makes the first ACTIVE one the
  -- default, and the refusal below has to come from the index rather
  -- than from a state the helper arranged.
  v_bank1 := pg_temp.test_bank_account(v_org, 'Maybank 001',
                                       p_default => false);
  v_bank2 := pg_temp.test_bank_account(v_org, 'CIMB 002',
                                       p_default => false);

  foreach t in array array['branches', 'payment_terms', 'price_levels',
                           'tax_codes', 'warehouses']
  loop
    execute format(
      'insert into public.%I (org_id, code, name, is_default)
         values ($1, ''D1'', ''Yang pertama'', true)', t) using v_org;
    perform pg_temp.check_refused(
      format('%s refuses a second default for one company', t),
      format('insert into public.%I (org_id, code, name, is_default)
                values (%L, ''D2'', ''Yang kedua'', true)', t, v_org),
      '%duplicate key%', '23505');
  end loop;

  -- pipelines has no code column.
  insert into public.pipelines (org_id, name, is_default)
  values (v_org, 'Jualan', true);
  perform pg_temp.check_refused(
    'pipelines refuses a second default for one company',
    format('insert into public.pipelines (org_id, name, is_default)
              values (%L, ''Pembelian'', true)', v_org),
    '%duplicate key%', '23505');

  -- work_shifts needs its hours.
  insert into public.work_shifts
    (org_id, code, name, start_time, end_time, is_default)
  values (v_org, 'PAGI', 'Syif pagi', '09:00', '18:00', true);
  perform pg_temp.check_refused(
    'work_shifts refuses a second default for one company',
    format('insert into public.work_shifts
              (org_id, code, name, start_time, end_time, is_default)
              values (%L, ''MLM'', ''Syif malam'', ''18:00'', ''02:00'', true)',
           v_org),
    '%duplicate key%', '23505');

  -- bank_accounts: both rows real, so the refusal is the index rather
  -- than a missing account_id.
  update public.bank_accounts set is_default = true where id = v_bank1;
  perform pg_temp.check_refused(
    'bank_accounts refuses a second default for one company',
    format('update public.bank_accounts set is_default = true where id = %L',
           v_bank2),
    '%duplicate key%', '23505');

  -- A retired row may keep a stale default beside an active one. The
  -- first version of 0741 indexed `where is_default` alone and forbade
  -- this; `money_names_the_account.sql` failed, because the closed
  -- account still flagged default is how it proves the readers skip it.
  update public.bank_accounts set is_active = false where id = v_bank2;
  update public.bank_accounts set is_default = true where id = v_bank2;
  perform pg_temp.check_eq(
    'a closed account may keep a stale default beside the open one',
    (select count(*)::integer from public.bank_accounts
      where org_id = v_org and is_default), 2);
  perform pg_temp.check_eq(
    'and only one of them is the live default',
    (select count(*)::integer from public.bank_accounts
      where org_id = v_org and is_default and is_active), 1);
end $$;

-- ---------------------------------------------------------------------
-- Two companies, a default each: the index is scoped, not global
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid;
  v_b uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.test_org('Dua Syarikat A Sdn Bhd', array['inventory']);
  v_b := pg_temp.test_org('Dua Syarikat B Sdn Bhd', array['inventory']);
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_a, 'WA', 'Gudang A', true), (v_b, 'WB', 'Gudang B', true);
  perform pg_temp.check_eq(
    'each company keeps its own default warehouse',
    (select count(*)::integer from public.warehouses
      where org_id in (v_a, v_b) and is_default), 2);
end $$;

-- ---------------------------------------------------------------------
-- What the index is FOR: is_default decides, not created_at
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_older uuid;
  v_deflt uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Bukan Yang Tertua Sdn Bhd', array['inventory']);

  -- The ordinary warehouse FIRST, the default SECOND, and then the two
  -- given different timestamps -- because every row a single transaction
  -- inserts shares one `created_at` and `order by created_at` would
  -- otherwise order nothing. With these two days apart the orderings
  -- disagree, so an implementation that reads created_at and one that
  -- reads is_default give different answers.
  insert into public.warehouses (org_id, code, name, is_default, is_active)
  values (v_org, 'TUA', 'Gudang tua', false, true) returning id into v_older;
  insert into public.warehouses (org_id, code, name, is_default, is_active)
  values (v_org, 'UTAMA', 'Gudang utama', true, true) returning id into v_deflt;
  update public.warehouses set created_at = now() - interval '2 days'
   where id = v_older;
  update public.warehouses set created_at = now() - interval '1 day'
   where id = v_deflt;

  perform pg_temp.check_true(
    'the default is not the oldest, so the two orderings disagree',
    (select created_at from public.warehouses where id = v_deflt)
      > (select created_at from public.warehouses where id = v_older));
  perform pg_temp.check_eq(
    'default_warehouse returns the DEFAULT, not the oldest active one',
    app.default_warehouse(v_org), v_deflt);

  -- And with no default at all, the oldest active one -- the second tier
  -- of the same function, which is why it needs its own assertion.
  update public.warehouses set is_default = false where id = v_deflt;
  perform pg_temp.check_eq(
    'and with no default, the OLDEST active warehouse, not the newest',
    app.default_warehouse(v_org), v_older);
end $$;

-- ---------------------------------------------------------------------
-- 0742: a closed warehouse is nobody's default
-- ---------------------------------------------------------------------
--
-- The point is not the constraint, it is what the constraint buys:
-- thirteen functions pick a default warehouse or pipeline with
-- `where is_default limit 1` and no `is_active`. If a closed row could
-- hold the flag, those thirteen could deplete stock from a warehouse
-- that was shut. The last assertion here is the one that would catch a
-- regression -- that the two predicates cannot disagree.
do $$
declare
  v_org uuid;
  v_wh  uuid;
  v_pl  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Gudang Tutup Sdn Bhd', array['inventory', 'crm']);
  insert into public.warehouses (org_id, code, name, is_default, is_active)
  values (v_org, 'W1', 'Gudang', true, true) returning id into v_wh;
  insert into public.pipelines (org_id, name, is_default, is_active)
  values (v_org, 'Jualan', true, true) returning id into v_pl;

  perform pg_temp.check_refused(
    'a warehouse cannot be retired while it is still the default',
    format('update public.warehouses set is_active = false where id = %L',
           v_wh),
    '%warehouses_default_is_active%', '23514');
  perform pg_temp.check_refused(
    'nor a pipeline',
    format('update public.pipelines set is_active = false where id = %L',
           v_pl),
    '%pipelines_default_is_active%', '23514');

  -- And the way the app does it -- both columns together, which is what
  -- `retireWarehouse` writes -- is accepted.
  update public.warehouses set is_active = false, is_default = false
   where id = v_wh;
  perform pg_temp.check_true('retiring it and clearing the flag together works',
    (select not is_active and not is_default
       from public.warehouses where id = v_wh));

  -- The consequence, stated as the thirteen readers would observe it.
  -- A fresh default is inserted first, because with the only warehouse
  -- retired both counts are zero and `0 = 0` is not an assertion -- the
  -- twelfth entry in docs/widget-tests.md, which this file's own header
  -- cites. The non-zero check below is what stops it passing that way.
  insert into public.warehouses (org_id, code, name, is_default, is_active)
  values (v_org, 'W2', 'Gudang baharu', true, true);
  perform pg_temp.check_eq(
    'so `where is_default` and `where is_default and is_active` agree',
    (select count(*)::integer from public.warehouses
      where org_id = v_org and is_default),
    (select count(*)::integer from public.warehouses
      where org_id = v_org and is_default and is_active));
  perform pg_temp.check_eq(
    'and they agree on ONE row, not on zero of them',
    (select count(*)::integer from public.warehouses
      where org_id = v_org and is_default and is_active), 1);
end $$;

rollback;
