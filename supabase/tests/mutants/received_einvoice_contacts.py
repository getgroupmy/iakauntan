# Mutants for `create_supplier_from_received_einvoice` and
# `link_received_einvoice_contact` (0650) -- the supplier on an
# e-Invoice we received: one contact per TIN, never a second for a
# supplier already on file, with what the document said about them, and
# never another company's contact.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0650_the_invoice_a_supplier_sent_us.sql \
#       supabase/tests/received_einvoice.sql \
#       supabase/tests/mutants/received_einvoice_contacts.py
#
# RESULT: 14 mutants and a control, all killed by `received_einvoice.sql`.
# Eight only after its "supplier on a received e-Invoice, rule by rule"
# block -- whose first draft asserted nothing for half its cases:
# `record_received_einvoice` links a supplier by TIN or registration
# number before these functions run, and `pg_temp.parsed` gives every
# document the same registration number, so each new document was
# already linked to the last one's supplier. The block now gives each
# document its own number and uses customers on file for the TIN cases.

m("anybody creates the supplier",
  "create_supplier_from_received_einvoice",
  "    raise exception 'Not allowed to create contacts in this organization'",
  "    raise notice 'Not allowed to create contacts in this organization'  -- said only",
  "-- said only")

m("a document already linked makes a second supplier",
  "create_supplier_from_received_einvoice",
  "  if v_row.contact_id is not null then\n    return v_row.contact_id;",
  "  if false then  -- relinked\n    return v_row.contact_id;",
  "-- relinked")

m("a document naming nobody makes a nameless supplier",
  "create_supplier_from_received_einvoice",
  "  if v_row.supplier_name is null then",
  "  if false then  -- nameless",
  "-- nameless")

m("a supplier already on file by TIN is created again",
  "create_supplier_from_received_einvoice",
  "    if v_exists is not null then",
  "    if false then  -- duplicated",
  "-- duplicated")

m("a retired contact with the TIN is linked",
  "create_supplier_from_received_einvoice",
  "       and c.deleted_at is null\n       and upper(btrim(c.tin))",
  "       and true  -- retired too\n       and upper(btrim(c.tin))",
  "-- retired too")

m("another company's contact with the TIN is linked",
  "create_supplier_from_received_einvoice",
  "     where c.org_id = v_row.org_id\n       and c.deleted_at is null",
  "     where true  -- any company\n       and c.deleted_at is null",
  "-- any company")

m("the TIN is matched exactly, spaces and case and all",
  "create_supplier_from_received_einvoice",
  "       and upper(btrim(c.tin)) = upper(btrim(v_row.supplier_tin))",
  "       and c.tin = v_row.supplier_tin  -- exact",
  "-- exact")

m("the supplier is not created as a supplier",
  "create_supplier_from_received_einvoice",
  "    'supplier', v_row.supplier_name,",
  "    'customer', v_row.supplier_name,  -- customer",
  "-- customer")

m("the supplier's address city is lost",
  "create_supplier_from_received_einvoice",
  "    app.received_text(v_addr, 'city'),",
  "    null,  -- no city",
  "-- no city")

m("an unknown country is kept rather than defaulted",
  "create_supplier_from_received_einvoice",
  "    coalesce(v_country, 'MYS'),",
  "    v_country,  -- no default",
  "-- no default")

m("the document is not linked to the new supplier",
  "create_supplier_from_received_einvoice",
  "  update public.received_einvoices set contact_id = v_id where id = p_id;\n  return v_id;",
  "  return v_id;  -- unlinked",
  "-- unlinked")

m("anybody links a supplier",
  "link_received_einvoice_contact",
  "    raise exception 'Not allowed to change this received e-Invoice'",
  "    raise notice 'Not allowed to change this received e-Invoice'  -- said only",
  "-- said only")

m("the supplier on a billed document is changed",
  "link_received_einvoice_contact",
  "  if v_row.bill_id is not null then",
  "  if false then  -- billed",
  "-- billed")

m("another company's contact is linked, left to the key",
  "link_received_einvoice_contact",
  "  if p_contact_id is not null and not exists (",
  "  if false and not exists (  -- left to the key",
  "-- left to the key")

m("CONTROL: a comment inside the block",
  "link_received_einvoice_contact",
  "  if v_row.bill_id is not null then",
  "  if v_row.bill_id is not null then  -- (control)",
  "(control)")
