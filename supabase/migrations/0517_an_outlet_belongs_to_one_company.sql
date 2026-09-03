-- =====================================================================
-- 0517 :: an outlet belongs to one company
--
-- The eighth parent, after `employees` (0507-0509), `warehouses`
-- (0510), `contacts` (0512), `items` (0513), `accounts` (0514),
-- `gl_entries` (0515) and `sales_documents` (0516). `pos_outlets` has
-- only `unique (org_id, code)`, so it gets its own `(org_id, id)`
-- first, then seventeen columns.
--
-- This one has a different history from the others, and it is worth
-- being honest about it. The 0505 audit found that several POS
-- functions -- `merge_pos_sales`, `move_pos_sale`, `seat_table` --
-- were NOT exploitable, because each refuses when handed two different
-- outlets, and an outlet belongs to one company. That reasoning was
-- correct about the functions, and it rested entirely on a fact the
-- schema did not enforce: nothing stopped a register, a table or a
-- kitchen ticket in one company naming another company's outlet in the
-- first place. The guard held because the data happened to be right.
--
-- Every one of the seventeen is NOT NULL except `pos_drivers.
-- outlet_id`, so these keys bite on nearly every row rather than only
-- the ones that name somebody. `pos_sales.outlet_id` is the one that
-- decides which shop a sale is counted in -- the takings report, the
-- shift reconciliation and the consolidated e-Invoice all group by it.
--
-- Checked on the hosted project before writing: none of the seventeen
-- has a row whose outlet belongs to another company.
-- `scripts/check_embeds.py` is run against this migration.
-- =====================================================================

alter table public.pos_outlets
  add constraint pos_outlets_org_id_id_key unique (org_id, id);

alter table public.pos_bookings
  add constraint pos_bookings_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_deliveries
  add constraint pos_deliveries_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_delivery_zones
  add constraint pos_delivery_zones_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_drivers
  add constraint pos_drivers_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_floor_areas
  add constraint pos_floor_areas_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_item_stops
  add constraint pos_item_stops_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_kitchen_stations
  add constraint pos_kitchen_stations_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_kitchen_tickets
  add constraint pos_kitchen_tickets_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_menu_links
  add constraint pos_menu_links_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_outlet_channels
  add constraint pos_outlet_channels_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_queue_entries
  add constraint pos_queue_entries_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_receipt_settings
  add constraint pos_receipt_settings_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_registers
  add constraint pos_registers_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_sales
  add constraint pos_sales_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete restrict;
alter table public.pos_service_providers
  add constraint pos_service_providers_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_stalls
  add constraint pos_stalls_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
alter table public.pos_tables
  add constraint pos_tables_outlet_same_org
  foreign key (org_id, outlet_id)
  references public.pos_outlets (org_id, id)
  on delete cascade;
