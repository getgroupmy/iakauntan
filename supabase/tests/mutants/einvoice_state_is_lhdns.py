# Mutants for 0803 -- app.einvoice_state_is_lhdns, on sales and
# purchase documents: a client's own statement does not write a
# document's e-Invoice status or e-Invoice, nor a bill's
# requires_self_billed, nor creates a document with any of them set;
# the functions pass. And public.void_sales_document, restated, refuses
# an invoice whose e-Invoice is valid whether the copy or the e-Invoice
# says so.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0803_lhdns_answer_is_not_typed_in.sql \
#       supabase/tests/einvoice_columns.sql \
#       supabase/tests/mutants/einvoice_state_is_lhdns.py
#
# RESULT: 22 mutants and a control, all 22 killed by
# `einvoice_columns.sql`, new in `0803`. Two of the void's -- dropping
# `org_id` and dropping `source_table` -- survived the first draft,
# which had no e-Invoice carrying the invoice's id that was not its own.
# Reachable then: `source_id` has no foreign key and
# `einvoice_documents` took a client's insert, which `0804` ended; a
# function can still write one wrong. The file makes two, another
# company's and one for a bill, both valid, and voids the invoice
# beside them.
#
# SECURITY DEFINER flipped by hand on the guard: the file fails on its
# first refusal ("an accepted invoice's status is not set back: it was
# not refused at all"); restored, it passes.

G = "einvoice_state_is_lhdns"
V = "void_sales_document"

# Who is asked.
m("the client role is not asked", G,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")
m("a client's own statement passes at depth one", G,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")
m("the functions are refused too", G,
  "     or pg_trigger_depth() > 1 then",
  "     and pg_trigger_depth() > 1 then  -- owner asked",
  "-- owner asked")

# On the way in.
m("a document is created with any e-Invoice status", G,
  "    if new.einvoice_status is distinct from 'not_applicable'\n       or new.einvoice_id is not null then",
  "    if new.einvoice_id is not null then  -- status free",
  "-- status free")
m("a document is created holding any e-Invoice", G,
  "    if new.einvoice_status is distinct from 'not_applicable'\n       or new.einvoice_id is not null then",
  "    if new.einvoice_status is distinct from 'not_applicable' then  -- id free",
  "-- id free")
m("a bill is created owing whatever it says", G,
  "    if coalesce((v_new ->> 'requires_self_billed')::boolean, false) then",
  "    if false then  -- owed free",
  "-- owed free")
m("a bill that says it owes none is refused too", G,
  "    if coalesce((v_new ->> 'requires_self_billed')::boolean, false) then",
  "    if v_new ? 'requires_self_billed' then  -- any bill",
  "-- any bill")
m("an insert goes on to the update's questions", G,
  "        using errcode = '42501';\n    end if;\n    return new;\n  end if;",
  "        using errcode = '42501';\n    end if;\n    -- falls through\n  end if;",
  "-- falls through")

# On the way through.
m("no copy is asked", G,
  "    if (v_new -> v_col) is distinct from (v_old -> v_col) then",
  "    if false then  -- copies free",
  "-- copies free")
m("a copy sent back unchanged is refused", G,
  "    if (v_new -> v_col) is distinct from (v_old -> v_col) then",
  "    if true then  -- any mention",
  "-- any mention")
m("the status is not the database's", G,
  "  foreach v_col in array array['einvoice_status', 'einvoice_id'] loop",
  "  foreach v_col in array array['no_einvoice_status', 'einvoice_id'] loop  -- status free",
  "-- status free")
m("the e-Invoice is not the database's", G,
  "  foreach v_col in array array['einvoice_status', 'einvoice_id'] loop",
  "  foreach v_col in array array['einvoice_status', 'no_einvoice_id'] loop  -- id free",
  "-- id free")
m("the obligation is not asked", G,
  "  if (v_new -> 'requires_self_billed')\n       is distinct from (v_old -> 'requires_self_billed') then",
  "  if false then  -- obligation free",
  "-- obligation free")
m("an obligation sent back unchanged is refused", G,
  "  if (v_new -> 'requires_self_billed')\n       is distinct from (v_old -> 'requires_self_billed') then",
  "  if v_new ? 'requires_self_billed' then  -- any bill",
  "-- any bill")
m("the two columns answer in each other's words", G,
  "        case v_col when 'einvoice_status' then 'status' else 'id' end,",
  "        case v_col when 'einvoice_status' then 'id' else 'status' end,  -- swapped",
  "-- swapped")

# The void.
m("the void reads only the copy", V,
  "  if v_doc.einvoice_status = 'valid'\n     or exists (select 1 from public.einvoice_documents e",
  "  if v_doc.einvoice_status = 'valid'\n     or false and exists (select 1 from public.einvoice_documents e  -- copy only",
  "-- copy only")
m("the void reads only the e-Invoices", V,
  "  if v_doc.einvoice_status = 'valid'\n     or exists (select 1 from public.einvoice_documents e",
  "  if false  -- e-Invoices only\n     or exists (select 1 from public.einvoice_documents e",
  "-- e-Invoices only")
m("any e-Invoice of the company's blocks the void", V,
  "                   and e.source_id = v_doc.id\n                   and e.status = 'valid') then",
  "                   and e.status = 'valid') then  -- anybody's",
  "-- anybody's")
m("an e-Invoice in any state blocks the void", V,
  "                   and e.source_id = v_doc.id\n                   and e.status = 'valid') then",
  "                   and e.source_id = v_doc.id) then  -- any state",
  "-- any state")
m("another company's e-Invoice blocks the void", V,
  "                 where e.org_id = v_doc.org_id\n                   and e.source_table = 'sales_documents'\n                   and e.source_id = v_doc.id\n                   and e.status = 'valid') then",
  "                 where e.source_table = 'sales_documents'\n                   and e.source_id = v_doc.id\n                   and e.status = 'valid') then  -- any company",
  "-- any company")
m("a bill's e-Invoice blocks the void", V,
  "                   and e.source_table = 'sales_documents'\n                   and e.source_id = v_doc.id\n                   and e.status = 'valid') then",
  "                   and e.source_id = v_doc.id\n                   and e.status = 'valid') then  -- any table",
  "-- any table")

m("CONTROL", G,
  "  v_new jsonb;\nbegin",
  "  v_new jsonb;  -- control\nbegin",
  "-- control")
