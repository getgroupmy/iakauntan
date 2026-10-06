# Mutants for public.pos_day_sheet (0739) -- one outlet's day of
# bookings, one row per provider, with the providers who have none.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/pos_service.sql \
#       supabase/tests/mutants/pos_day_sheet.py
#
# RESULT: (pending)

m("the length is in seconds",
  "pos_day_sheet",
  "         (extract(epoch from (b.ends_at - b.starts_at)) / 60)::integer,",
  "         (extract(epoch from (b.ends_at - b.starts_at)))::integer,  -- seconds",
  "-- seconds")

m("a booking with no customer has no name",
  "pos_day_sheet",
  "         b.status, coalesce(c.name, 'Walk-in'), b.description, b.price, b.sale_id",
  "         b.status, c.name, b.description, b.price, b.sale_id  -- no walk-in",
  "-- no walk-in")

m("the day is the UTC day",
  "pos_day_sheet",
  "     and (b.starts_at at time zone 'Asia/Kuala_Lumpur')::date = p_date",
  "     and (b.starts_at at time zone 'UTC')::date = p_date  -- utc",
  "-- utc")

m("every day's bookings are on the sheet",
  "pos_day_sheet",
  "     and (b.starts_at at time zone 'Asia/Kuala_Lumpur')::date = p_date",
  "     and true  -- every day",
  "-- every day")

m("a provider with no booking is left off",
  "pos_day_sheet",
  "    left join public.pos_bookings b",
  "    join public.pos_bookings b  -- inner",
  "-- inner")

m("another outlet's providers are on the sheet",
  "pos_day_sheet",
  "   where p.outlet_id = p_outlet",
  "   where true  -- any outlet",
  "-- any outlet")

m("a retired provider is on the sheet",
  "pos_day_sheet",
  "     and p.is_active\n",
  "     and true  -- retired too\n",
  "-- retired too")

m("a stranger reads the day sheet",
  "pos_day_sheet",
  "     and app.can_read_module(p.org_id, 'pos')",
  "     and true  -- anybody",
  "-- anybody")

m("the bookings are not in time order",
  "pos_day_sheet",
  "   order by p.name, b.starts_at;",
  "   order by p.name, b.starts_at desc;  -- backwards",
  "-- backwards")

m("CONTROL: a comment inside the block",
  "pos_day_sheet",
  "    left join public.contacts c on c.id = b.contact_id",
  "    -- CONTROL\n    left join public.contacts c on c.id = b.contact_id",
  "-- CONTROL")
