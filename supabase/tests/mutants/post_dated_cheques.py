# Mutants for public.record_pdc and public.bounce_pdc -- a cheque dated
# for later, parked in a holding account until it clears or returns.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/post_dated_cheques.sql \
#       supabase/tests/mutants/post_dated_cheques.py
#
# then again against `cash_forecast.sql` and `idempotency.sql`.
#
# RESULT, 5 October: 27 mutants, 23 killed on the first file and four
# survived. Across all three files 27 of 27 die; nothing is equivalent.
#
#   post_dated_cheques.sql  kills 23, then 25
#   cash_forecast.sql       kills 3
#   idempotency.sql         kills the last 2
#
# The two that only `idempotency.sql` kills are worth naming, because it
# kills them WITHOUT asserting anything about either:
#
#   * the status rule, which lets a cleared or bounced cheque be bounced
#     again; and
#   * `status = 'bounced'` not being set, which leaves the cheque HELD
#     while its journal and its allocations say otherwise.
#
# Both die on `pg_temp.refuses_a_repeat('bounce_pdc', ...)` -- a helper
# that calls the function twice and demands the second be refused. A
# cheque left `held` can be bounced twice, so the generic
# idempotency check catches a specific defect in the status write that
# nothing in this file looks at. A test asserting a GENERAL property
# can kill a mutation in a particular field, and that is the best
# argument there is for having both kinds.
#
# THE TWO GAPS closed here:
#
#   * the BOUNDARY's other side. `p_cheque_date <= v_on` is the entire
#     definition of post-dated. The file stood on TODAY (refused) and on
#     dates weeks out (accepted), so widening the rule to refuse
#     TOMORROW changed no assertion. Tomorrow is the first valid date.
#   * `bounce_pdc`'s own `can_write_module`, which nothing asserted.
#     A bounce writes a journal and deletes the allocations, so it is as
#     much a posting as taking the cheque in was.
#
# A post-dated cheque is the one instrument in this schema where the
# DIRECTION decides which control account moves and which side of the
# journal it lands on, so every rule exists twice -- once for a cheque
# taken in and once for one written out. A fixture that only ever takes
# cheques in cannot see half of it, and that is the third gap family in
# this sweep's list.
#
# The four families, each represented on purpose:
#
#   * PERMISSION. `can_write_module` is called with a module DERIVED
#     from the direction -- 'sales' for incoming, 'purchases' for
#     outgoing -- so mutating the derivation swaps which right is
#     needed. A company holding both cannot tell.
#   * BOUNDARY. `p_cheque_date <= v_on` is the whole definition of
#     "post-dated": a cheque dated today is a receipt. Tomorrow is the
#     first valid date, and today the last invalid one.
#   * COLLAPSE. The direction above, and `coalesce(c.receivable_account_id,
#     1210)` where no contact has its own.
#   * SHAPE THAT BALANCES. `v_alloc <> 0 and v_alloc <> v_amount` lets a
#     cheque settle less than its face value; both sides of the journal
#     still use `v_amount`, so the journal balances and only an
#     assertion on the allocations sees it.

# ------------------------------------------------------- record_pdc
m("a direction that is neither in nor out is accepted",
  "record_pdc",
  "  if p_direction not in ('incoming', 'outgoing') then",
  "  if false then  -- direction rule dropped",
  "-- direction rule dropped")

m("an incoming cheque needs the PURCHASES right, not sales",
  "record_pdc",
  "  v_module text := case when p_direction = 'incoming' then 'sales'"
  " else 'purchases' end;",
  "  v_module text := case when p_direction = 'incoming' then 'purchases'"
  " else 'sales' end;  -- module derivation swapped",
  "-- module derivation swapped")

m("anybody may record a cheque",
  "record_pdc",
  "  if not app.can_write_module(p_org, v_module) then",
  "  if not app.can_write_module(p_org, v_module) and false then"
  "  -- can_write dropped",
  "-- can_write dropped")

m("a cheque for nothing is recorded",
  "record_pdc",
  "  if v_amount <= 0 then\n    raise exception 'A cheque has to be for"
  " something.' using errcode = '23514';",
  "  if v_amount < 0 then  -- zero cheque allowed\n"
  "    raise exception 'A cheque has to be for something.'"
  " using errcode = '23514';",
  "-- zero cheque allowed")

m("a cheque with no number on it is recorded",
  "record_pdc",
  "  if coalesce(trim(p_cheque_no), '') = '' then",
  "  if false then  -- cheque-number rule dropped",
  "-- cheque-number rule dropped")

m("THE BOUNDARY: a cheque dated TODAY is treated as post-dated",
  "record_pdc",
  "  if p_cheque_date <= v_on then",
  "  if p_cheque_date < v_on then  -- today allowed as post-dated",
  "-- today allowed as post-dated")

m("a cheque dated TOMORROW is refused as not post-dated",
  "record_pdc",
  "  if p_cheque_date <= v_on then",
  "  if p_cheque_date <= v_on + 1 then  -- tomorrow refused",
  "-- tomorrow refused")

m("a contact of another company is accepted",
  "record_pdc",
  "                  where c.id = p_contact and c.org_id = p_org) then",
  "                  where c.id = p_contact) then  -- org check dropped",
  "-- org check dropped")

m("a settlement line for nothing is accepted",
  "record_pdc",
  "    if v_amt <= 0 then\n      raise exception 'A settlement has to be for"
  " something.'",
  "    if v_amt < 0 then  -- zero settlement allowed\n"
  "      raise exception 'A settlement has to be for something.'",
  "-- zero settlement allowed")

m("an incoming cheque settles BILLS instead of invoices",
  "record_pdc",
  "    if v_in then\n      select d.doc_no, d.balance_amount, d.status::text,"
  " d.contact_id, d.currency\n        into v_doc\n"
  "        from public.sales_documents d",
  "    if not v_in then  -- document side swapped\n"
  "      select d.doc_no, d.balance_amount, d.status::text,"
  " d.contact_id, d.currency\n        into v_doc\n"
  "        from public.sales_documents d",
  "-- document side swapped")

m("a DRAFT invoice can be settled by a cheque",
  "record_pdc",
  "    if v_doc.status not in ('posted', 'partial') then\n"
  "      raise exception '% is %, and a cheque settles an outstanding"
  " document.',",
  "    if v_doc.status not in ('posted', 'partial', 'draft') then"
  "  -- draft allowed\n"
  "      raise exception '% is %, and a cheque settles an outstanding"
  " document.',",
  "-- draft allowed")

m("another contact's invoice can be settled by this cheque",
  "record_pdc",
  "    if v_doc.contact_id <> p_contact then",
  "    if false then  -- contact match dropped",
  "-- contact match dropped")

m("a foreign-currency invoice can be settled by a cheque",
  "record_pdc",
  "    if v_doc.currency <> app.base_currency(p_org) then",
  "    if false then  -- currency rule dropped",
  "-- currency rule dropped")

m("more than is outstanding can be settled",
  "record_pdc",
  "    if v_amt > v_doc.balance_amount then\n"
  "      raise exception '% has % outstanding and the cheque would settle %.',",
  "    if false then  -- over-settlement allowed\n"
  "      raise exception '% has % outstanding and the cheque would settle %.',",
  "-- over-settlement allowed")

m("settling exactly what is outstanding is refused",
  "record_pdc",
  "    if v_amt > v_doc.balance_amount then\n"
  "      raise exception '% has % outstanding and the cheque would settle %.',",
  "    if v_amt >= v_doc.balance_amount then  -- exact settlement refused\n"
  "      raise exception '% has % outstanding and the cheque would settle %.',",
  "-- exact settlement refused")

m("A SHAPE THAT BALANCES: a cheque may settle less than its face value",
  "record_pdc",
  "  if v_alloc <> 0 and v_alloc <> v_amount then",
  "  if false then  -- part-settlement guard dropped",
  "-- part-settlement guard dropped")

m("an unallocated cheque is posted to the ledger anyway",
  "record_pdc",
  "  if v_alloc = 0 then\n    return v_id;",
  "  if false then  -- register-only early return dropped\n    return v_id;",
  "-- register-only early return dropped")

m("the contact's own receivable account is ignored for 1210",
  "record_pdc",
  "    select coalesce(c.receivable_account_id,\n"
  "                    (select a.id from public.accounts a\n"
  "                      where a.org_id = p_org and a.code = '1210'))\n"
  "      into v_ctrl from public.contacts c where c.id = p_contact;",
  "    select coalesce(null::uuid,  -- contact receivable ignored\n"
  "                    (select a.id from public.accounts a\n"
  "                      where a.org_id = p_org and a.code = '1210'))\n"
  "      into v_ctrl from public.contacts c where c.id = p_contact;",
  "-- contact receivable ignored")

m("an incoming cheque CREDITS the holding account and debits the customer",
  "record_pdc",
  "      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,\n"
  "        'description', 'Cheque ' || trim(p_cheque_no),\n"
  "        'debit', v_amount, 'credit', 0),\n"
  "      jsonb_build_object('account_id', v_ctrl, 'contact_id', p_contact,",
  "      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,\n"
  "        'description', 'Cheque ' || trim(p_cheque_no),\n"
  "        'debit', 0, 'credit', v_amount),  -- incoming sides swapped\n"
  "      jsonb_build_object('account_id', v_ctrl, 'contact_id', p_contact,",
  "-- incoming sides swapped")

m("the cheque does not remember its journal",
  "record_pdc",
  "  update public.post_dated_cheques set gl_entry_id = v_entry"
  " where id = v_id;",
  "  update public.post_dated_cheques set gl_entry_id = null"
  " where id = v_id;  -- entry not recorded",
  "-- entry not recorded")

# ------------------------------------------------------- bounce_pdc
m("anybody may bounce a cheque",
  "bounce_pdc",
  "  if not app.can_write_module(v_c.org_id,",
  "  if false and app.can_write_module(v_c.org_id,  -- can_write dropped",
  "-- can_write dropped")

m("a cheque already cleared or bounced can be bounced again",
  "bounce_pdc",
  "  if v_c.status not in ('held', 'deposited') then",
  "  if false then  -- status rule dropped",
  "-- status rule dropped")

m("a bounce with no reason is accepted",
  "bounce_pdc",
  "  if coalesce(trim(p_reason), '') = '' then",
  "  if false then  -- reason rule dropped",
  "-- reason rule dropped")

m("bouncing an incoming cheque CREDITS the receivable instead of debiting",
  "bounce_pdc",
  "        jsonb_build_object('account_id', v_ctrl, 'contact_id',"
  " v_c.contact_id,\n"
  "          'description', 'Cheque ' || v_c.cheque_no || ' returned',\n"
  "          'debit', v_c.amount, 'credit', 0),",
  "        jsonb_build_object('account_id', v_ctrl, 'contact_id',"
  " v_c.contact_id,\n"
  "          'description', 'Cheque ' || v_c.cheque_no || ' returned',\n"
  "          'debit', 0, 'credit', v_c.amount),  -- returned sides swapped",
  "-- returned sides swapped")

m("the allocations survive a bounce, so the invoice stays settled",
  "bounce_pdc",
  "  delete from public.payment_allocations where pdc_id = p_id;",
  "  -- allocations kept: delete from public.payment_allocations"
  " where pdc_id = p_id;",
  "-- allocations kept")

m("a bounced cheque is not marked bounced",
  "bounce_pdc",
  "     set status = 'bounced', bounced_on = v_on,",
  "     set status = 'held', bounced_on = v_on,  -- status not advanced",
  "-- status not advanced")

m("the reason is not recorded",
  "bounce_pdc",
  "         bounce_reason = trim(p_reason), bounce_entry_id = v_entry",
  "         bounce_reason = null, bounce_entry_id = v_entry"
  "  -- reason not recorded",
  "-- reason not recorded")

m("CONTROL -- a comment inside record_pdc",
  "record_pdc",
  "  v_no := app.next_document_number_internal(p_org, 'cheque');",
  "  v_no := app.next_document_number_internal(p_org, 'cheque');"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
