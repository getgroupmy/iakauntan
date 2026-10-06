# Mutants for public.fs_lodge (0739) -- recording that frozen,
# circulated accounts went to SSM, with the MBRS reference.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/mbrs.sql \
#       supabase/tests/mutants/fs_lodge.py
#
# then again against `fs_deadlines.sql`, `fs_statutory_order.sql` and
# `corp_filing_shapes.sql`.
#
# RESULT: 9 mutants and a control. 9 killed.
#
#   The first sweep killed 3 across the four files, which all lodge once,
#   as the owner, frozen, circulated and with a clean reference. "fs_lodge,
#   rule by rule" in mbrs.sql kills the six refusals and stored values;
#   "the filing is not marked lodged" and "the write switch is left on"
#   were already dead in mbrs.sql.

m("a reader lodges the accounts",
  "fs_lodge",
  "  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then",
  "  if not app.has_module(f.org_id, 'mbrs') then  -- reader",
  "-- reader")

m("a company without the module lodges",
  "fs_lodge",
  "  if not app.can_write(f.org_id) or not app.has_module(f.org_id, 'mbrs') then",
  "  if not app.can_write(f.org_id) then  -- no module",
  "-- no module")

m("unfrozen accounts are lodged",
  "fs_lodge",
  "  if f.status <> 'frozen' then",
  "  if false then  -- unfrozen",
  "-- unfrozen")

m("a lodgement needs no reference",
  "fs_lodge",
  "  if coalesce(trim(p_reference), '') = '' then",
  "  if p_reference is null then  -- blank fine",
  "-- blank fine")

m("accounts never circulated are lodged",
  "fs_lodge",
  "  if f.circulated_on is null then",
  "  if false then  -- uncirculated",
  "-- uncirculated")

m("the filing is not marked lodged",
  "fs_lodge",
  "     set status = 'lodged', lodged_on = p_lodged_on,",
  "     set lodged_on = p_lodged_on,  -- status kept",
  "-- status kept")

m("the lodgement date is today, not the date given",
  "fs_lodge",
  "     set status = 'lodged', lodged_on = p_lodged_on,",
  "     set status = 'lodged', lodged_on = app.today(),  -- today",
  "-- today")

m("the reference is kept with its spaces",
  "fs_lodge",
  "         mbrs_reference = trim(p_reference)",
  "         mbrs_reference = p_reference  -- untrimmed",
  "-- untrimmed")

m("the write switch is left on",
  "fs_lodge",
  "  perform set_config('app.fs_writing', 'off', true);",
  "  null;  -- left on",
  "-- left on")

m("CONTROL: a comment inside the block",
  "fs_lodge",
  "  perform set_config('app.fs_writing', 'on', true);",
  "  -- CONTROL\n  perform set_config('app.fs_writing', 'on', true);",
  "-- CONTROL")
