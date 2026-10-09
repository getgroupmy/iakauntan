# Mutants for public.record_received_einvoice (0650) -- an e-Invoice a
# supplier sent us, recorded from its file: by somebody who may write,
# once per file and per company, keeping what it says even where it is
# malformed, and linked to a supplier only by an identifier.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0650_the_invoice_a_supplier_sent_us.sql \
#       supabase/tests/received_einvoice.sql \
#       supabase/tests/mutants/record_received_einvoice.py
#
# RESULT: 13 mutants and a control, all killed by `received_einvoice.sql`.
# Eight only after its "`record_received_einvoice`, rule by rule" block,
# among them that the duplicate check is per company: with the
# `org_id` clause gone, a second company importing the same file was
# handed the FIRST company's record.

m("anybody records an e-Invoice",
  "record_received_einvoice",
  "  if not app.can_write(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a file that is not an object is taken",
  "record_received_einvoice",
  "  if p_raw is null or jsonb_typeof(p_raw) <> 'object' then",
  "  if p_raw is null then  -- any json",
  "-- any json")

m("a parse that is not an object is taken",
  "record_received_einvoice",
  "  if p_parsed is null or jsonb_typeof(p_parsed) <> 'object' then",
  "  if p_parsed is null then  -- any parse",
  "-- any parse")

m("the same file imported twice is recorded twice",
  "record_received_einvoice",
  "  if v_existing is not null then",
  "  if false then  -- twice",
  "-- twice")

m("another company's copy of the file is handed back",
  "record_received_einvoice",
  "   where org_id = p_org_id and payload_hash = v_hash;",
  "   where payload_hash = v_hash;  -- any company",
  "-- any company")

m("a currency code of the wrong length is kept",
  "record_received_einvoice",
  "  if v_currency is not null and length(v_currency) <> 3 then",
  "  if false then  -- any length",
  "-- any length")

m("a rate of nothing is kept",
  "record_received_einvoice",
  "  if v_rate <= 0 then",
  "  if false then  -- zero rate",
  "-- zero rate")

m("a supplier is not found by TIN",
  "record_received_einvoice",
  "  if v_tin is not null then\n    select c.id into v_contact",
  "  if false then  -- no tin match\n    select c.id into v_contact",
  "-- no tin match")

m("a customer is linked as the supplier",
  "record_received_einvoice",
  "       and c.contact_type in ('supplier', 'both')\n       and upper(btrim(c.tin))",
  "       and true  -- any type\n       and upper(btrim(c.tin))",
  "-- any type")

m("a supplier is not found by registration number",
  "record_received_einvoice",
  "  if v_contact is null and app.received_text(v_supplier, 'idValue') is not null then",
  "  if false then  -- no reg match",
  "-- no reg match")

m("a match is found and not linked",
  "record_received_einvoice",
  "    update public.received_einvoices set contact_id = v_contact where id = v_id;",
  "    perform 1;  -- unlinked",
  "-- unlinked")

m("the lines are numbered by the supplier, not in order",
  "record_received_einvoice",
  "        p_org_id, v_id, v_no,",
  "        p_org_id, v_id, 1,  -- one number",
  "-- one number")

m("what the parser found wrong is dropped",
  "record_received_einvoice",
  "    case when jsonb_typeof(p_parsed -> 'problems') = 'array'\n      then p_parsed -> 'problems' else '[]'::jsonb end,",
  "    '[]'::jsonb,  -- no problems",
  "-- no problems")

m("CONTROL: a comment inside the block",
  "record_received_einvoice",
  "  if v_rate <= 0 then",
  "  if v_rate <= 0 then  -- (control)",
  "(control)")
