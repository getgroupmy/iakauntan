-- =====================================================================
-- iAkauntan :: the counter sale nobody paid for yet
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_on_account.sql
--
-- `app.pos_tender_kind` has had `on_account` since `0208`, and until
-- `0357` `complete_pos_sale` treated it as one more kind of not-cash.
-- The sale raised its invoice, then wrote and posted a receipt for the
-- whole basket, so the receivable the invoice had just created was
-- cleared by a payment nobody had made — into the current account,
-- because an on-account tender has no bank account and
-- `post_receipt_internal` falls through to `1120`.
--
-- The failure is entirely silent. The journal balances, the sale
-- completes, the till reconciles. What is wrong is only visible by
-- asking a question nothing asked: is the customer still down as owing
-- this? So that is the question below, and it is asked of the invoice's
-- balance rather than of the screen.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_regular uuid;
  v_item   uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;
  v_acct   uuid;
  v_bank   uuid;
  v_sale   uuid;
  v_a      numeric;
  v_b      numeric;
  v_refused boolean;
begin
  v_org := pg_temp.test_org('Kedai Akaun Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  -- The regular whose account the shop runs. A different row from the
  -- walk-in on purpose: the whole point of an account is that it
  -- belongs to somebody.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'PUAN-S', 'Puan Salmah', 'customer') returning id into v_regular;

  -- Priced with no tax, so every figure below can be checked by hand.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'BERAS', 'Beras 5kg', 'stock', false, 'C62', 20.00, 12.00)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, true);

  -- A named bank account for the cash tender, so the mixed sale below
  -- can assert the money went somewhere chosen rather than to the
  -- fallback.
  insert into public.bank_accounts
    (org_id, account_id, name, account_type, currency)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1110'),
          'Cash in hand', 'cash', 'MYR')
  returning id into v_bank;

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, bank_account_id,
     counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', v_bank, true, true)
  returning id into v_cash;
  -- No bank account, and none is possible: nothing was banked.
  insert into public.pos_tender_types
    (org_id, code, name, kind, counts_in_drawer, gives_change)
  values (v_org, 'ACCT', 'On account', 'on_account', false, false)
  returning id into v_acct;

  v_shift := public.open_pos_shift(v_reg, 0.00);

  -- ------------------------------------------------------------------
  -- The whole basket on the account
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg, v_regular);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 20.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_acct, 'amount', 20.00)),
    v_regular);

  perform pg_temp.check_true('a sale on account is a completed sale',
    (select s.status = 'completed' from public.pos_sales s where s.id = v_sale));
  perform pg_temp.check_eq('and records what went on the account',
    (select s.on_account_amount from public.pos_sales s where s.id = v_sale), 20.00);

  -- The assertion the whole file exists for.
  perform pg_temp.check_true('with no receipt behind it, because no money '
    'was taken',
    (select s.receipt_id is null from public.pos_sales s where s.id = v_sale));
  perform pg_temp.check_eq(
    'so the invoice still says the customer owes twenty ringgit',
    (select d.balance_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    20.00);

  -- And in the ledger, which is the version an auditor reads. The
  -- receivable is debited once and never credited back; before 0357 the
  -- invented receipt credited it straight out again and the net was
  -- zero.
  select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0) into v_a
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
    join public.gl_entries g on g.id = l.entry_id
   where a.code = '1210' and g.org_id = v_org;
  perform pg_temp.check_eq('the debtors account is up by that much, and '
    'stays up', v_a, 20.00);

  -- Nothing reached the bank at all. A default that lands an account
  -- sale in the current account is exactly the thing being fixed.
  select coalesce(sum(l.debit), 0) into v_b
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
    join public.gl_entries g on g.id = l.entry_id
   where a.code in ('1110', '1120') and g.org_id = v_org;
  perform pg_temp.check_eq('and nothing was banked', v_b, 0);

  -- ------------------------------------------------------------------
  -- Half now, half on the account
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg, v_regular);
  perform public.add_pos_sale_line(v_sale, v_item, 2, 20.00);
  perform public.complete_pos_sale(
    v_sale,
    jsonb_build_array(
      -- The account tender first, deliberately: the receipt used to
      -- take its bank account from whichever tender came first, and
      -- that one has none.
      jsonb_build_object('type', v_acct, 'amount', 25.00),
      jsonb_build_object('type', v_cash, 'amount', 15.00)),
    v_regular);

  perform pg_temp.check_eq('a split sale banks only what was handed over',
    (select r.amount from public.receipts r
      join public.pos_sales s on s.receipt_id = r.id where s.id = v_sale),
    15.00);
  perform pg_temp.check_true('into the account the cash tender names, not '
    'the fallback',
    (select r.bank_account_id = v_bank from public.receipts r
      join public.pos_sales s on s.receipt_id = r.id where s.id = v_sale));
  perform pg_temp.check_eq('and leaves the rest owing',
    (select d.balance_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    25.00);

  -- ------------------------------------------------------------------
  -- An account nobody named
  -- ------------------------------------------------------------------
  -- The outlet's walk-in contact would otherwise absorb it: one row
  -- every anonymous sale is billed to, growing a receivable balance
  -- belonging to nobody that nobody would ever be chased for.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 20.00);
  v_refused := false;
  begin
    perform public.complete_pos_sale(
      v_sale,
      jsonb_build_array(jsonb_build_object('type', v_acct, 'amount', 20.00)));
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true(
    'putting a bill on nobody''s account is refused', v_refused);

  -- The control: the same basket paid in cash goes through, so the
  -- refusal above is about the tender rather than about the sale.
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 20.00)));
  perform pg_temp.check_eq('and the same basket paid in cash owes nothing',
    (select d.balance_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    0);

  perform pg_temp.sign_out();
end $$;

rollback;
