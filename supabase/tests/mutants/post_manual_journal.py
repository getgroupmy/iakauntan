# Mutants for public.post_manual_journal (0089) -- a journal typed by
# hand: a description, at least two lines, each with an account of THIS
# company that can be posted to, and no line negative or both sides.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0089_manual_journal.sql \
#       supabase/tests/manual_journal.sql \
#       supabase/tests/mutants/post_manual_journal.py
#
# RESULT: 14 mutants and a control, all killed by `manual_journal.sql`.
# Five only after message-checked refusals were added there. The file
# already "refused" a negative amount, a two-sided line and the rest,
# but by SQLSTATE alone -- and `create_gl_entry_internal` raises 23514
# for its own reasons, while the negative case put a negative on BOTH
# sides, so deleting either half of the guard left the other to trip.
# Every line-shape guard here could be removed with the file green.

m("anybody posts a journal",
  "post_manual_journal",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a journal with no description is posted",
  "post_manual_journal",
  "  if coalesce(btrim(p_description), '') = '' then",
  "  if p_description is null then  -- blank allowed",
  "-- blank allowed")

m("lines that are not a list are accepted",
  "post_manual_journal",
  "  if jsonb_typeof(p_lines) <> 'array' then",
  "  if false then  -- not a list",
  "-- not a list")

m("a journal of one line is accepted",
  "post_manual_journal",
  "  if jsonb_array_length(p_lines) < 2 then",
  "  if jsonb_array_length(p_lines) < 1 then  -- one line",
  "-- one line")

m("a line with no account is accepted",
  "post_manual_journal",
  "    if nullif(v_line ->> 'account_id', '') is null then",
  "    if false then  -- no account",
  "-- no account")

m("a negative debit is accepted",
  "post_manual_journal",
  "    if coalesce((v_line ->> 'debit')::numeric, 0) < 0\n       or coalesce((v_line ->> 'credit')::numeric, 0) < 0 then",
  "    if coalesce((v_line ->> 'credit')::numeric, 0) < 0 then  -- negative debit",
  "-- negative debit")

m("a negative credit is accepted",
  "post_manual_journal",
  "    if coalesce((v_line ->> 'debit')::numeric, 0) < 0\n       or coalesce((v_line ->> 'credit')::numeric, 0) < 0 then",
  "    if coalesce((v_line ->> 'debit')::numeric, 0) < 0 then  -- negative credit",
  "-- negative credit")

m("a line on both sides is accepted",
  "post_manual_journal",
  "    if coalesce((v_line ->> 'debit')::numeric, 0) > 0\n       and coalesce((v_line ->> 'credit')::numeric, 0) > 0 then",
  "    if false then  -- both sides",
  "-- both sides")

m("another company's account is accepted",
  "post_manual_journal",
  "      on a.id = (l ->> 'account_id')::uuid and a.org_id = p_org_id\n",
  "      on a.id = (l ->> 'account_id')::uuid  -- any company\n",
  "-- any company")

m("a heading is posted to",
  "post_manual_journal",
  "   where a.id is null or a.is_group or not a.is_active;",
  "   where a.id is null or not a.is_active;  -- heading",
  "-- heading")

m("an inactive account is posted to",
  "post_manual_journal",
  "   where a.id is null or a.is_group or not a.is_active;",
  "   where a.id is null or a.is_group;  -- inactive",
  "-- inactive")

m("the description is kept with its padding",
  "post_manual_journal",
  "    p_description => btrim(p_description),",
  "    p_description => p_description,  -- padded",
  "-- padded")

m("a blank reference is kept as blank",
  "post_manual_journal",
  "    p_reference   => nullif(btrim(p_reference), ''),",
  "    p_reference   => p_reference,  -- blank kept",
  "-- blank kept")

m("a journal is posted as some other source",
  "post_manual_journal",
  "    p_source      => 'manual'::app.journal_source,",
  "    p_source      => 'bank_transaction'::app.journal_source,  -- not manual",
  "-- not manual")

m("CONTROL: a comment inside the block",
  "post_manual_journal",
  "  if jsonb_typeof(p_lines) <> 'array' then",
  "  if jsonb_typeof(p_lines) <> 'array' then  -- (control)",
  "(control)")
