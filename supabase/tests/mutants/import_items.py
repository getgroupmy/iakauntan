# Mutants for public.import_items (0103) -- a list of item rows checked
# one by one (code, name, unique in the file and in the company, a known
# type, unit, classification and currency, numbers that are numbers, a
# yes or a no, no stock-tracked service), reported row by row; committed
# only when every row is clean, with the defaults the check assumed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0103_csv_import.sql \
#       supabase/tests/csv_import.sql \
#       supabase/tests/mutants/import_items.py
#
# RESULT: 25 mutants and a control, all killed by `csv_import.sql`;
# ten before its rule-by-rule block. The file asked one import of three
# rows and one preview with four bad rows of three kinds, so who may
# import, a file that is not a list or is empty, a missing code or name,
# a code twice (the second copy in a different case), already here,
# deleted, or another company's, and a classification, currency, cost,
# reorder level or yes-or-no that is not one were all unasked -- as was
# the order the rows come back in.
#
# Noted, not a defect: the comment above the service check says stock
# that is not tracked "posts to inventory and never moves". Measured, it
# does not -- an untracked stock item on a bill is expensed to 5100
# Purchases, as non_stock is, with no stock movement. The comment
# describes a rule the code does not have and a consequence that does
# not happen.

F = "import_items"

m("anybody imports", F,
  "  if not app.can_write(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an object is read as rows", F,
  "  if jsonb_typeof(p_rows) is distinct from 'array' then",
  "  if false then  -- not a list",
  "-- not a list")

m("an empty file is imported", F,
  "  if jsonb_array_length(p_rows) = 0 then",
  "  if false then  -- empty taken",
  "-- empty taken")

m("a row without a code passes", F,
  "    if v_code is null then\n      v_problem := 'No code.';",
  "    if false then  -- no code\n      v_problem := 'No code.';",
  "-- no code")

m("a row without a name passes", F,
  "    elsif v_name is null then",
  "    elsif false then  -- no name",
  "-- no name")

m("a code twice in the file passes", F,
  "    elsif lower(v_code) = any (v_seen) then",
  "    elsif false then  -- twice in file",
  "-- twice in file")

m("a code twice in the file differs by case", F,
  "    elsif lower(v_code) = any (v_seen) then",
  "    elsif v_code = any (v_seen) then  -- case matters",
  "-- case matters")

m("a code already here passes", F,
  "                   where it.org_id = p_org_id and lower(it.code) = lower(v_code)\n                     and it.deleted_at is null) then",
  "                   where false) then  -- already here",
  "-- already here")

m("a deleted item's code is taken", F,
  "                   where it.org_id = p_org_id and lower(it.code) = lower(v_code)\n                     and it.deleted_at is null) then",
  "                   where it.org_id = p_org_id and lower(it.code) = lower(v_code)) then  -- deleted counted",
  "-- deleted counted")

m("another company's code blocks this one", F,
  "                   where it.org_id = p_org_id and lower(it.code) = lower(v_code)\n                     and it.deleted_at is null) then",
  "                   where lower(it.code) = lower(v_code)\n                     and it.deleted_at is null) then  -- any company",
  "-- any company")

m("any item type passes", F,
  "    elsif v_kind not in ('stock', 'service', 'non_stock', 'bundle', 'fixed_asset') then",
  "    elsif false then  -- any type",
  "-- any type")

m("any unit passes", F,
  "    elsif not exists (select 1 from public.ref_uom_codes ru\n                       where ru.code = v_uom) then",
  "    elsif false then  -- any unit",
  "-- any unit")

m("any classification passes", F,
  "    elsif not exists (select 1 from public.ref_classification_codes rk\n                       where rk.code = v_class) then",
  "    elsif false then  -- any class",
  "-- any class")

m("any currency passes", F,
  "    elsif not exists (select 1 from public.ref_currencies rc\n                       where rc.code = v_currency) then",
  "    elsif false then  -- any currency",
  "-- any currency")

m("a price that is not a number passes", F,
  "    elsif v_price is null then",
  "    elsif false then  -- any price",
  "-- any price")

m("a cost that is not a number passes", F,
  "    elsif v_cost is null then",
  "    elsif false then  -- any cost",
  "-- any cost")

m("a reorder level that is not a number passes", F,
  "    elsif v_reorder is null then",
  "    elsif false then  -- any reorder",
  "-- any reorder")

m("a yes-or-no that is neither passes", F,
  "    elsif v_track is null then",
  "    elsif false then  -- any boolean",
  "-- any boolean")

m("a stock-tracked service passes", F,
  "    elsif v_kind = 'service' and v_track then",
  "    elsif false then  -- tracked service",
  "-- tracked service")

m("a service is tracked unless told", F,
  "    v_track := app.import_boolean(app.import_text(r, 'track_inventory'),\n                                  v_kind = 'stock');",
  "    v_track := app.import_boolean(app.import_text(r, 'track_inventory'),\n                                  true);  -- tracked by default",
  "-- tracked by default")

m("a file with problems is committed", F,
  "  if p_commit and v_bad > 0 then",
  "  if false then  -- committed anyway",
  "-- committed anyway")

m("a preview writes", F,
  "  if p_commit then\n    for r in select * from jsonb_array_elements(p_rows)",
  "  if true then  -- preview writes\n    for r in select * from jsonb_array_elements(p_rows)",
  "-- preview writes")

m("the default unit is a different one on commit", F,
  "        upper(coalesce(app.import_text(r, 'uom_code'), 'C62')),\n        coalesce(app.import_text(r, 'classification_code'), '022'),",
  "        upper(coalesce(app.import_text(r, 'uom_code'), 'H87')),  -- other unit\n        coalesce(app.import_text(r, 'classification_code'), '022'),",
  "-- other unit")

m("the reorder quantity is dropped", F,
  "        app.import_number(app.import_text(r, 'reorder_quantity')));",
  "        null);  -- no reorder qty",
  "-- no reorder qty")

m("the rows come back out of order", F,
  "     order by 1;",
  "     order by 1 desc;  -- reversed",
  "-- reversed")

m("CONTROL: a comment inside the block", F,
  "    elsif v_name is null then",
  "    elsif v_name is null then  -- (control)",
  "(control)")
