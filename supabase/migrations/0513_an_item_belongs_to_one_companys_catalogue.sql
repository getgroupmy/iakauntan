-- =====================================================================
-- 0513 :: an item belongs to one company's catalogue
--
-- The fourth parent, after `employees` (0507-0509), `warehouses`
-- (0510) and `contacts` (0512). `items` has no `unique (org_id, id)`
-- of its own -- only `(org_id, code)` -- so it gets one first, the same
-- shape 0507 gave employees and 0510 gave warehouses.
--
-- Thirty-three columns. What a wrong id costs here is not a listing:
-- `stock_movements.item_id` and `stock_levels.item_id` are what the
-- stock report and the inventory figure on the balance sheet are
-- computed from, so a movement naming another company's item moves
-- their stock and values ours. `sales_document_lines.item_id` and
-- `purchase_document_lines.item_id` pull the item's own sales and
-- purchase account into the journal, which is how a wrong item becomes
-- a posting to an account that is not in this company's chart.
-- `stock_lots.item_id` is the moving-average cost the next issue is
-- priced at.
--
-- `items.parent_item_id` is the self-reference -- the variant to its
-- parent, the shirt in six sizes -- which is what stops a variant
-- hanging off another company's product.
--
-- Delete rules follow the plain key beside each column, with the
-- correction 0511 made necessary: `set null` on a composite key takes
-- the column list, or it nulls `org_id` too and the delete raises
-- 23502 instead of clearing the reference.
--
-- Checked on the hosted project before writing: none of the
-- thirty-three has a row whose item belongs to another company.
-- `scripts/check_embeds.py` is run against this migration -- adding a
-- foreign key is an API change, and both 0508 and 0512 made embeds in
-- repository.dart ambiguous exactly this way.
-- =====================================================================

alter table public.items
  add constraint items_org_id_id_key unique (org_id, id);

alter table public.bills_of_materials
  add constraint bills_of_materials_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.bom_lines
  add constraint bom_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.forecast_lines
  add constraint forecast_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.gl_lines
  add constraint gl_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete set null (item_id);
alter table public.item_barcodes
  add constraint item_barcodes_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.item_conversion_outputs
  add constraint item_conversion_outputs_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.item_conversions
  add constraint item_conversions_from_item_same_org
  foreign key (org_id, from_item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.item_forecast_params
  add constraint item_forecast_params_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.item_kitchen_stations
  add constraint item_kitchen_stations_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.item_modifier_groups
  add constraint item_modifier_groups_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.item_prices
  add constraint item_prices_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.item_uom_packs
  add constraint item_uom_packs_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.items
  add constraint items_parent_item_same_org
  foreign key (org_id, parent_item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.landed_cost_allocations
  add constraint landed_cost_allocations_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete no action;
alter table public.manufacturing_orders
  add constraint manufacturing_orders_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.membership_items
  add constraint membership_items_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.mo_components
  add constraint mo_components_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.pos_bookings
  add constraint pos_bookings_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete set null (item_id);
alter table public.pos_item_stops
  add constraint pos_item_stops_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.pos_memberships
  add constraint pos_memberships_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.pos_modifiers
  add constraint pos_modifiers_recipe_item_same_org
  foreign key (org_id, recipe_item_id)
  references public.items (org_id, id)
  on delete set null (recipe_item_id);
alter table public.pos_recipe_lines
  add constraint pos_recipe_lines_component_item_same_org
  foreign key (org_id, component_item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.pos_recipes
  add constraint pos_recipes_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.pos_sale_line_voids
  add constraint pos_sale_line_voids_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete set null (item_id);
alter table public.pos_sale_lines
  add constraint pos_sale_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.pos_services
  add constraint pos_services_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.purchase_document_lines
  add constraint purchase_document_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete set null (item_id);
alter table public.sales_document_lines
  add constraint sales_document_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete set null (item_id);
alter table public.stock_adjustment_lines
  add constraint stock_adjustment_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.stock_levels
  add constraint stock_levels_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.stock_lots
  add constraint stock_lots_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete cascade;
alter table public.stock_movements
  add constraint stock_movements_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
alter table public.stock_transfer_lines
  add constraint stock_transfer_lines_item_same_org
  foreign key (org_id, item_id)
  references public.items (org_id, id)
  on delete restrict;
