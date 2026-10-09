# Mutants for public.pos_scan_serial (0546) -- a serial scanned onto a
# till line: the line must exist and be the caller's to sell on, its
# bill still parked, its item tracked by serial; the unit must be on
# THIS shelf (the line's warehouse, or the company's default), not on
# this line already and not in another open basket of this company;
# the count of serials is the quantity, and the line is repriced.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0546_scan_a_serial_number_at_the_till.sql \
#       supabase/tests/pos_serial_sale.sql \
#       supabase/tests/mutants/pos_scan_serial.py
#
# RESULT: 13 mutants and a control. 11 killed by `pos_serial_sale.sql`;
# before its assertions, 8. Nothing had asked about a missing line, a
# stranger, an outlet with no shelf of its own (the line then has no
# warehouse, and the scan looks on the company's default shelf), or a
# label that reads the same in ANOTHER company's open basket -- which
# is that company's business, labels being unique only within one
# shop's stock. That last one first survived its own assertion: the
# fixture wrote `where id = add_pos_sale_line(...)`, which runs the
# function once per row scanned and updates nothing. It is assigned
# first now, and the fixture asserts the label really is in the basket.
#
# Two are EQUIVALENT:
#   * an item not kept in stock taking a scan -- `items` refuses an item
#     tracked by serial that is not kept, so that half of the check is
#     never the half that decides;
#   * a sold unit counting as on the shelf (`> 0` to `>= 0`) --
#     `v_lot_balances` has `HAVING sum(quantity) <> 0`, so a sold unit
#     has no row at all. A sold machine is still asserted refused.

F = "pos_scan_serial"

m("a blank scan is taken", F,
  "  if v_ref is null then\n    raise exception 'Scan a serial number, or type one.'",
  "  if false then  -- blank taken\n    raise exception 'Scan a serial number, or type one.'",
  "-- blank taken")

m("a line that does not exist is not refused in words", F,
  "  if v_org is null then\n    raise exception 'No such line.'",
  "  if false then  -- no such line\n    raise exception 'No such line.'",
  "-- no such line")

m("anybody may scan onto a bill", F,
  "  if not app.can_write_module(v_org, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a settled bill takes a scan", F,
  "  if v_status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("an item kept but not by serial takes a scan", F,
  "  if not coalesce(v_kept, false) or coalesce(v_track, 'none') <> 'serial' then",
  "  if not coalesce(v_kept, false) then  -- any tracking",
  "-- any tracking")

m("an item not kept takes a scan", F,
  "  if not coalesce(v_kept, false) or coalesce(v_track, 'none') <> 'serial' then",
  "  if coalesce(v_track, 'none') <> 'serial' then  -- kept ignored",
  "-- kept ignored")

m("the default warehouse is not the fallback", F,
  "                  (select w.id from public.warehouses w\n                    where w.org_id = l.org_id and w.is_default limit 1)),",
  "                  null),  -- no default",
  "-- no default")

m("the shelf is any shelf", F,
  "       and b.warehouse_id = v_wh\n",
  "       and true  -- any shelf\n",
  "-- any shelf")

m("a unit already sold is on the shelf", F,
  "       and b.quantity > 0)",
  "       and b.quantity >= 0)  -- sold counts",
  "-- sold counts")

m("another company's open basket blocks the scan", F,
  "     where l.org_id = v_org\n       and l.id <> p_line",
  "     where true  -- any company\n       and l.id <> p_line",
  "-- any company")

m("another open basket does not block", F,
  "       and s.status = 'parked'\n       and v_ref = any (l.serial_refs))",
  "       and false  -- never blocks\n       and v_ref = any (l.serial_refs))",
  "-- never blocks")

m("the quantity is not the count", F,
  "         quantity = coalesce(array_length(array_append(serial_refs, v_ref), 1), 1)",
  "         quantity = quantity  -- count ignored",
  "-- count ignored")

m("the line is not repriced", F,
  "  perform app.reprice_pos_line(p_line);\n\n  return v_refs;",
  "  -- no reprice\n\n  return v_refs;",
  "-- no reprice")

m("CONTROL", F,
  "  select o.name into v_out",
  "  select o.name into v_out  -- control",
  "-- control")
