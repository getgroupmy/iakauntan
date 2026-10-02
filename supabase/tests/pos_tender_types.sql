-- =====================================================================
-- iAkauntan :: a shop says how it can be paid
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_tender_types.sql
--
-- `0732`. `pos_tender_types` has had a write policy since `0208` and no
-- screen until now, which is why every row in production had a null
-- `bank_account_id`: nobody could set one. `upsert_pos_tender_type` and
-- `delete_pos_tender_type` are what the screen calls, and the rules
-- they carry are the ones a form must not be the only thing enforcing.
--
-- What has to be true:
--
--   * WHERE THE MONEY LANDS is filled in when it is not given, by
--     `app.tender_type_settlement_account` -- the drawer for cash, the
--     bank for a card -- and KEPT when an amendment does not mention
--     it, because the trigger would fill it again anyway.
--   * THE TWO KINDS THAT TAKE NO MONEY -- on account, points -- are
--     refused an account outright and left null by the trigger. An
--     account on either would say money reached a bank.
--   * EVERY REFUSAL, by message, each paired with the write that still
--     succeeds. N refusals are satisfied by a function that refuses
--     everything.
--   * AND A TENDER THAT HAS TAKEN MONEY DOES NOT GO. `pos_tenders`
--     references it `on delete restrict` on purpose, so the refusal
--     has to say what to do instead.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A shop with a till, a drawer and a bank account, which is the state
-- every assertion below starts from.
--
-- The outlet, register and shift are here only because `pos_tenders`
-- needs a sale and a sale needs all three. The last block uses them;
-- nothing else does.
create or replace function pg_temp.tt_org(p_name text)
returns uuid language plpgsql as $$
declare
  v_org uuid; v_wh uuid; v_walkin uuid; v_outlet uuid; v_reg uuid;
begin
  v_org := pg_temp.test_org(p_name);
  -- Kuala Lumpur, not the session's zone: `current_date` is UTC and
  -- from 16:00 UTC they are different days, which `check_test_clock.py`
  -- pins so a new fixture cannot add to the drift.
  perform public.create_fiscal_year(
    v_org,
    date_trunc('year', (now() at time zone 'Asia/Kuala_Lumpur')::date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, 'pos', true
  on conflict (org_id, module_code) do update set is_enabled = true;

  -- The bank first, then the drawer: `test_bank_account` makes the
  -- FIRST active account the default, and the rule prefers the default
  -- for a card while a drawer tender looks for one of type `cash`.
  perform pg_temp.test_bank_account(v_org, 'Maybank semasa');
  perform pg_temp.a_till(v_org);

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer')
  returning id into v_walkin;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter one') returning id into v_reg;
  return v_org;
end;
$$;

-- The sale a tender row has to hang on, and nothing more than that.
create or replace function pg_temp.tt_sale(p_org uuid)
returns uuid language plpgsql as $$
declare v_reg uuid; v_outlet uuid; v_shift uuid; v_id uuid;
begin
  select r.id, r.outlet_id into v_reg, v_outlet
    from public.pos_registers r where r.org_id = p_org limit 1;
  v_shift := public.open_pos_shift(v_reg, 0);
  -- PARKED, not completed. `pos_sales_documents_ck` requires a
  -- completed sale to have an invoice and either a receipt or to be
  -- wholly on account -- rightly, since a completed counter sale is a
  -- document pair. A parked bill with money already on it is a real
  -- state (the tender sheet takes part-payment), and what the refusal
  -- below reads is the COUNT of `pos_tenders` rows, which is the same
  -- either way.
  insert into public.pos_sales
    (org_id, shift_id, register_id, outlet_id, sale_no, status)
  values (p_org, v_shift, v_reg, v_outlet,
          'POS-TT-' || substr(gen_random_uuid()::text, 1, 8), 'parked')
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- A new tender knows where its money goes and what its kind does
-- ---------------------------------------------------------------------
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_till  uuid;
  v_bank  uuid;
  v_cash  uuid;
  v_card  uuid;
  v_acct  uuid;
begin
  v_org := pg_temp.tt_org('Kedai Bayar Sdn Bhd');
  perform pg_temp.sign_in_as(v_me);

  select b.id into v_till from public.bank_accounts b
   where b.org_id = v_org and b.account_type = 'cash';
  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.account_type = 'current';

  v_cash := public.upsert_pos_tender_type(
    null, v_org, 'tunai', 'Tunai', 'cash'::app.pos_tender_kind, '01');
  v_card := public.upsert_pos_tender_type(
    null, v_org, 'kad', 'Kad', 'card'::app.pos_tender_kind, '03');

  perform pg_temp.check_true('cash lands in the drawer',
    (select bank_account_id = v_till from public.pos_tender_types
      where id = v_cash));
  perform pg_temp.check_true('a card settles into the bank',
    (select bank_account_id = v_bank from public.pos_tender_types
      where id = v_card));

  -- The code is what a report groups by, so it is normalised rather
  -- than taken as typed. Two codes differing only in case are one
  -- column that reads as two.
  perform pg_temp.check_eq('the code is upper-cased',
    (select code from public.pos_tender_types where id = v_cash), 'TUNAI');

  -- `0208` holds these as columns rather than inferring them from the
  -- kind, because a shop that takes cheques over the counter puts them
  -- in the drawer. So they are DEFAULTS, and a new cash tender gets
  -- the habits cash has.
  perform pg_temp.check_true('cash counts, gives change and opens the drawer',
    (select counts_in_drawer and gives_change and opens_drawer
       from public.pos_tender_types where id = v_cash));
  perform pg_temp.check_true('and a card does none of the three',
    (select not counts_in_drawer and not gives_change and not opens_drawer
       from public.pos_tender_types where id = v_card));

  -- Buttons appear in `sort_order`, and a shop adding its fourth
  -- tender should not have to say where it goes.
  perform pg_temp.check_true('each new one sorts after the last',
    (select t2.sort_order > t1.sort_order
       from public.pos_tender_types t1, public.pos_tender_types t2
      where t1.id = v_cash and t2.id = v_card));

  -- ------------------------------------------------------------------
  -- An amendment that says nothing about the account keeps it
  -- ------------------------------------------------------------------
  perform public.upsert_pos_tender_type(
    v_card, v_org, 'KAD', 'Kad kredit', 'card'::app.pos_tender_kind, '03');
  perform pg_temp.check_true('an amendment leaves the account alone',
    (select bank_account_id = v_bank and name = 'Kad kredit'
       from public.pos_tender_types where id = v_card));

  -- And one that names another account moves it, which is the whole
  -- reason this function exists: "or into another account where one is
  -- defined" was unreachable before.
  perform public.upsert_pos_tender_type(
    v_card, v_org, 'KAD', 'Kad kredit', 'card'::app.pos_tender_kind, '03',
    v_till);
  perform pg_temp.check_true('and a named one is used',
    (select bank_account_id = v_till from public.pos_tender_types
      where id = v_card));

  -- ------------------------------------------------------------------
  -- The two kinds where no money arrives
  -- ------------------------------------------------------------------
  v_acct := public.upsert_pos_tender_type(
    null, v_org, 'AKAUN', 'Akaun', 'on_account'::app.pos_tender_kind);
  perform pg_temp.check_true('on account banks nowhere',
    (select bank_account_id is null from public.pos_tender_types
      where id = v_acct));

  perform pg_temp.check_refused(
    'and will not take an account even when one is named',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'AKAUN2', 'Akaun dua',
                 'on_account'::app.pos_tender_kind, null, %L) $q$,
           v_org, v_till),
    '%takes no money%');

  perform pg_temp.check_refused(
    'nor on points, which come off the basket',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'MATA', 'Mata', 'loyalty'::app.pos_tender_kind,
                 null, %L) $q$, v_org, v_till),
    '%takes no money%');

  -- An on-account tender that HAD an account -- which only a hand
  -- written row can be now -- is cleared rather than kept, because the
  -- trigger leaves these two alone and a `coalesce` would hold a stale
  -- one.
  update public.pos_tender_types set bank_account_id = v_till
   where id = v_acct;
  perform public.upsert_pos_tender_type(
    v_acct, v_org, 'AKAUN', 'Akaun', 'on_account'::app.pos_tender_kind);
  perform pg_temp.check_true('and an account on one is cleared',
    (select bank_account_id is null from public.pos_tender_types
      where id = v_acct));
end $$;

-- ---------------------------------------------------------------------
-- What it refuses, each with the write that still works
-- ---------------------------------------------------------------------
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_other uuid := pg_temp.another_user('kedai-lain@tt.test');
  v_org   uuid;
  v_them  uuid;
  v_theirs uuid;
  v_ok    uuid;
begin
  v_org := pg_temp.tt_org('Kedai Enggan Sdn Bhd');
  perform pg_temp.sign_in_as(v_me);

  perform pg_temp.check_refused('a tender with no name is refused',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'X', '  ', 'cash'::app.pos_tender_kind) $q$, v_org),
    '%on the button%');

  perform pg_temp.check_refused('and one with no code',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, '', 'Tunai', 'cash'::app.pos_tender_kind) $q$,
           v_org),
    '%short code%');

  v_ok := public.upsert_pos_tender_type(
    null, v_org, 'TUNAI', 'Tunai', 'cash'::app.pos_tender_kind);

  -- The duplicate names the tender that already has the code, because
  -- "already taken" without saying by what sends somebody looking.
  perform pg_temp.check_refused('a code already in use is refused by name',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'tunai', 'Tunai lain',
                 'cash'::app.pos_tender_kind) $q$, v_org),
    '%already Tunai''s%');

  -- And amending the tender that holds the code is not a duplicate.
  perform public.upsert_pos_tender_type(
    v_ok, v_org, 'TUNAI', 'Tunai kaunter', 'cash'::app.pos_tender_kind);
  perform pg_temp.check_eq('while amending the one that holds it is fine',
    (select name from public.pos_tender_types where id = v_ok),
    'Tunai kaunter');

  perform pg_temp.check_refused('a payment mode LHDN does not publish',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'KAD', 'Kad', 'card'::app.pos_tender_kind,
                 '99') $q$, v_org),
    '%no LHDN payment mode%');

  -- Somebody else's bank account. `0519`'s composite key refuses this
  -- too, with a message about a constraint rather than about the shop.
  perform pg_temp.allow_many_companies();
  v_them := pg_temp.tt_org('Kedai Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_me);
  select b.id into v_theirs from public.bank_accounts b
   where b.org_id = v_them limit 1;

  perform pg_temp.check_refused('another company''s bank account is refused',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'KAD', 'Kad', 'card'::app.pos_tender_kind,
                 null, %L) $q$, v_org, v_theirs),
    '%not this company''s%');

  -- Somebody who may not write this company's POS module at all.
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused('and a stranger writes nothing',
    format($q$ select public.upsert_pos_tender_type(
                 null, %L, 'KAD', 'Kad', 'card'::app.pos_tender_kind) $q$,
           v_org),
    '%not permitted%');

  -- The control for all six: the same call with everything right still
  -- goes through, so none of the above is a function that refuses
  -- everything.
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.check_true('and a good one still goes in',
    public.upsert_pos_tender_type(
      null, v_org, 'KAD', 'Kad', 'card'::app.pos_tender_kind, '03')
    is not null);
end $$;

-- ---------------------------------------------------------------------
-- A tender that has taken money stays on the books
-- ---------------------------------------------------------------------
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_used  uuid;
  v_spare uuid;
  v_sale  uuid;
begin
  v_org := pg_temp.tt_org('Kedai Simpan Sdn Bhd');
  perform pg_temp.sign_in_as(v_me);

  v_used := public.upsert_pos_tender_type(
    null, v_org, 'TUNAI', 'Tunai', 'cash'::app.pos_tender_kind, '01');
  v_spare := public.upsert_pos_tender_type(
    null, v_org, 'KAD', 'Kad', 'card'::app.pos_tender_kind, '03');

  -- A tender row of its own rather than a whole sale: what the
  -- refusal reads is `pos_tenders`, and building a basket to get one
  -- would be asserting `complete_pos_sale` instead of this.
  v_sale := pg_temp.tt_sale(v_org);
  insert into public.pos_tenders
    (org_id, sale_id, tender_type_id, kind, amount)
  values (v_org, v_sale, v_used, 'cash', 10.00);

  perform pg_temp.check_refused(
    'one that has taken money is kept, and says to switch it off',
    format($q$ select public.delete_pos_tender_type(%L) $q$, v_used),
    '%Switch it off instead%');
  perform pg_temp.check_eq('so it is still there',
    (select count(*)::numeric from public.pos_tender_types
      where id = v_used), 1);

  -- Which is what a shop actually means by "remove this".
  perform public.upsert_pos_tender_type(
    v_used, v_org, 'TUNAI', 'Tunai', 'cash'::app.pos_tender_kind, '01',
    null, null, null, null, null, false);
  perform pg_temp.check_true('switching it off does work',
    (select not is_active from public.pos_tender_types where id = v_used));

  -- The control: one that has never been used goes.
  perform pg_temp.check_true('and an unused one is removed',
    public.delete_pos_tender_type(v_spare));
  perform pg_temp.check_eq('leaving nothing behind',
    (select count(*)::numeric from public.pos_tender_types
      where id = v_spare), 0);

  -- A tender that is not there is false rather than an error: a second
  -- tap on a row somebody already removed is not a fault.
  perform pg_temp.check_true('and an id that names none is false',
    not public.delete_pos_tender_type(gen_random_uuid()));

  raise notice 'pos_tender_types.sql: all assertions passed';
end $$;

rollback;
