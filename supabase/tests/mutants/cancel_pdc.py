# Mutants for public.cancel_pdc (0421) -- a post-dated cheque handed
# back before it was banked: by somebody with write access to the side
# of the books it belongs to, only while it is still held, never without
# a reason, its journal reversed today and its allocations taken off the
# documents it was to settle.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/post_dated_cheques.sql \
#       supabase/tests/mutants/cancel_pdc.py
#
# RESULT: 12 of 13 killed by `post_dated_cheques.sql`, the control
# surviving. Only two before its rule-by-rule block -- the allocations
# and the status; the cheque that does not exist, both readings of the
# permission, a cheque already paid in, the reason required, kept and
# trimmed, the journal reversed and on which day, and the reversing
# entry recorded were all unasserted.
#
# EQUIVALENT: "dated by reverse_gl_entry's default" -- that default is
# `coalesce(p_date, app.today())`, the same day this passes.

m("a cheque that does not exist is not said so",
  "cancel_pdc",
  "  if v_c.id is null then\n    raise exception 'No such cheque.'",
  "  if false then  -- no such cheque\n    raise exception 'No such cheque.'",
  "-- no such cheque")

m("anybody hands a cheque back",
  "cancel_pdc",
  "  if not app.can_write_module(v_c.org_id,",
  "  if false and app.can_write_module(v_c.org_id,  -- anybody",
  "-- anybody")

m("a cheque received is handed back on the buying side's permission",
  "cancel_pdc",
  "        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then",
  "        case when v_c.direction = 'incoming' then 'purchases' else 'sales' end) then  -- sides swapped",
  "-- sides swapped")

m("a cheque already paid in, cleared or returned is cancelled",
  "cancel_pdc",
  "  if v_c.status <> 'held' then",
  "  if false then  -- any status",
  "-- any status")

m("a cheque is handed back without a reason",
  "cancel_pdc",
  "  if coalesce(trim(p_reason), '') = '' then",
  "  if false then  -- no reason",
  "-- no reason")

m("the journal is not reversed",
  "cancel_pdc",
  "    v_rev := public.reverse_gl_entry(v_c.gl_entry_id, app.today());",
  "    v_rev := null;  -- not reversed",
  "-- not reversed")

m("the reversal is dated by reverse_gl_entry's default, not today",
  "cancel_pdc",
  "    v_rev := public.reverse_gl_entry(v_c.gl_entry_id, app.today());",
  "    v_rev := public.reverse_gl_entry(v_c.gl_entry_id);  -- default date",
  "-- default date")

m("the reversal is dated the day the cheque was received",
  "cancel_pdc",
  "    v_rev := public.reverse_gl_entry(v_c.gl_entry_id, app.today());",
  "    v_rev := public.reverse_gl_entry(v_c.gl_entry_id, v_c.received_on);  -- received day",
  "-- received day")

m("the documents it was to settle keep the settlement",
  "cancel_pdc",
  "  delete from public.payment_allocations where pdc_id = p_id;",
  "  perform 1;  -- allocations kept",
  "-- allocations kept")

m("the cheque is not marked cancelled",
  "cancel_pdc",
  "     set status = 'cancelled', bounce_reason = trim(p_reason),",
  "     set bounce_reason = trim(p_reason),  -- still held",
  "-- still held")

m("the reason is not kept",
  "cancel_pdc",
  "     set status = 'cancelled', bounce_reason = trim(p_reason),",
  "     set status = 'cancelled', bounce_reason = null,  -- no reason kept",
  "-- no reason kept")

m("the reason is kept as typed, spaces and all",
  "cancel_pdc",
  "     set status = 'cancelled', bounce_reason = trim(p_reason),",
  "     set status = 'cancelled', bounce_reason = p_reason,  -- untrimmed",
  "-- untrimmed")

m("the reversing entry is not recorded on the cheque",
  "cancel_pdc",
  "         bounce_entry_id = v_rev\n",
  "         bounce_entry_id = null  -- no entry\n",
  "-- no entry")

m("CONTROL: a comment inside the block",
  "cancel_pdc",
  "  if v_c.status <> 'held' then",
  "  if v_c.status <> 'held' then  -- (control)",
  "(control)")
