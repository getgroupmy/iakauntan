# Mutants for app.refuse_line_on_heading (0765) -- the trigger that
# keeps a ledger line off a heading account.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0765_a_heading_holds_no_line_of_its_own.sql \
#       supabase/tests/ledger.sql \
#       supabase/tests/mutants/refuse_line_on_heading.py
#
# RESULT: 4 mutants and a control, all killed by `ledger.sql`'s 0765
# block. The block was also run against the database before 0765 and
# failed at its first refusal; `demo_rebuild.sql`'s three new
# assertions each failed on their own with the old seeder put back.

m("a heading is taken like any account",
  "refuse_line_on_heading",
  "     and a.is_group;",
  "     and false;  -- any account",
  "-- any account")

m("every account is refused as a heading",
  "refuse_line_on_heading",
  "     and a.is_group;",
  "     ;  -- every account",
  "-- every account")

m("the refusal is never raised",
  "refuse_line_on_heading",
  "  if found then",
  "  if false then  -- never",
  "-- never")

m("the line is dropped instead of refused",
  "refuse_line_on_heading",
  "  return new;",
  "  return null;  -- dropped",
  "-- dropped")

m("CONTROL: a comment inside the block",
  "refuse_line_on_heading",
  "  if found then",
  "  if found then  -- (control)",
  "(control)")
