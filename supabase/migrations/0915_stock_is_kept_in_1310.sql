-- =====================================================================
-- iAkauntan :: 0915 stock is kept in 1310
--
-- An item carries an `inventory_account_id`, and three paths honour
-- it: `app.post_purchase_document_internal` and
-- `app.post_goods_received_internal` receive into it, and
-- `post_stock_adjustment` adjusts it. The other eight that move stock
-- post to 1310 by its number -- selling
-- (`app.post_sales_document_internal`), `send_stock_transfer` and
-- `receive_stock_transfer`, `post_manufacturing_order`,
-- `post_landed_cost_run`, `app.pos_deplete_recipes` and
-- `app.pos_return_recipes`, and `app.move_document_bundles`. So an
-- item with a stock account of its own took its goods in on one
-- account and out on another.
--
-- Measured on 8 November 2026, locally, as the owner with the role
-- `authenticated`: an item given 1320 as its stock account; ten bought
-- at 25 (Dr 1320 250); all ten sold. The cost of sales came out of
-- 1310: 1310 at -250 and 1320 at 250, with nothing on hand.
--
-- The app never sets the column; a direct write or an import can.
-- Production on 8 November: every item's stock account 1310 or unset.
--
-- Answered "stock lives in 1310 only", for every writer: an item's
-- stock account, when it names one, is the company's 1310. Unset still
-- means 1310, as it always has. Asked when it is set or changed.
-- `0912` already refuses a heading, a bank, a till, a receivable or a
-- payable here; this narrows the rest. Per-item stock accounts would
-- be their own change, through the eight paths above.
-- =====================================================================

create or replace function app.stock_is_kept_in_1310()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_code text;
  v_name text;
begin
  -- SECURITY DEFINER because it reads the account, and a writer who may
  -- not read the chart must not be waved through by reading nothing.
  if new.inventory_account_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.inventory_account_id is not distinct from old.inventory_account_id then
    return new;
  end if;

  select a.code, a.name into v_code, v_name
    from public.accounts a
   where a.id = new.inventory_account_id
     and a.org_id = new.org_id;

  if v_code is distinct from '1310' then
    raise exception
      '% (%) keeps its stock in 1310, not in %: selling, transferring, '
      'making and landing costs take stock out of 1310 by its number, '
      'while receiving and adjusting post to the item''s own account, so '
      'an account of its own took goods in on one account and out on '
      'another.',
      new.name, new.code,
      coalesce(v_code || ' ' || v_name, 'an account of another company')
      using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function app.stock_is_kept_in_1310() from public, anon, authenticated;

comment on function app.stock_is_kept_in_1310() is
  'Refuses, for every writer, an item''s inventory_account_id that is '
  'not its company''s 1310: receiving and adjusting honour the item''s '
  'own account, and the eight other stock paths post to 1310 by number. '
  'Unset still means 1310. 0915.';

create trigger stock_is_kept_in_1310
  before insert or update of inventory_account_id on public.items
  for each row execute function app.stock_is_kept_in_1310();
