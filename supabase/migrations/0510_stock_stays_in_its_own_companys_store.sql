-- =====================================================================
-- 0510 :: stock stays in its own company's store
--
-- 0507 to 0509 closed the same shape for `employees`. This is
-- `warehouses`, which is the one where a wrong id is inventory value
-- rather than a listing: `stock_movements` and `stock_levels` are what
-- the stock report and the balance sheet are computed from, and
-- `stock_transfers` names two warehouses, which is exactly the pairing
-- that goes wrong quietly.
--
-- `warehouses` had no `unique (org_id, id)`, so it gets one first, the
-- same shape 0502 added to `pay_periods` and 0507 to `employees`.
-- `contacts` already has its own; `items` and `pos_outlets` still need
-- theirs and are not in this migration.
--
-- Every column here is NOT NULL except `pos_outlets.warehouse_id` and
-- `manufacturing_orders.warehouse_id`; a composite key with MATCH
-- SIMPLE is not enforced when the column is null, so an outlet with no
-- warehouse behind it is unaffected.
--
-- Checked on the hosted project before writing: none of the fourteen
-- has a row that would violate. `scripts/check_embeds.py` is run
-- against this migration -- adding a foreign key is an API change, and
-- 0508 made three embeds ambiguous exactly this way.
-- =====================================================================

alter table public.warehouses
  add constraint warehouses_org_id_id_key unique (org_id, id);

alter table public.stock_movements
  add constraint stock_movements_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.stock_levels
  add constraint stock_levels_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete cascade;

-- Both ends of a transfer, which is the pairing that matters most:
-- a van cannot leave one company's store and arrive in another's.
alter table public.stock_transfers
  add constraint stock_transfers_from_warehouse_same_org
  foreign key (org_id, from_warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.stock_transfers
  add constraint stock_transfers_to_warehouse_same_org
  foreign key (org_id, to_warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.stock_adjustments
  add constraint stock_adjustments_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.sales_document_lines
  add constraint sales_document_lines_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.purchase_document_lines
  add constraint purchase_document_lines_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.pos_sale_lines
  add constraint pos_sale_lines_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.landed_cost_allocations
  add constraint landed_cost_allocations_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete cascade;

alter table public.manufacturing_orders
  add constraint manufacturing_orders_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete restrict;

alter table public.pos_outlets
  add constraint pos_outlets_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete set null;

alter table public.forecast_runs
  add constraint forecast_runs_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete cascade;

alter table public.forecast_lines
  add constraint forecast_lines_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete cascade;

alter table public.item_forecast_params
  add constraint item_forecast_params_warehouse_same_org
  foreign key (org_id, warehouse_id)
  references public.warehouses (org_id, id) on delete cascade;
